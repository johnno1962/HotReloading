//
//  SwiftInjection.swift
//  InjectionBundle
//
//  Created by John Holdsworth on 05/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/SwiftInjection.swift#32 $
//
//  Cut-down version of code injection in Swift. Uses code
//  from SwiftEval.swift to recompile and reload class.
//

#if arch(x86_64) || arch(i386) || arch(arm64) // simulator/macOS only
import Foundation
import SwiftTrace
#if SWIFT_PACKAGE
import HotReloadingGuts
import SwiftTraceGuts
#endif

/** pointer to a function implementing a Swift method */
public typealias SIMP = SwiftMeta.SIMP
public typealias ClassMetadataSwift = SwiftMeta.TargetClassMetadata

#if os(iOS) || os(tvOS)
import UIKit

extension UIViewController {

    /// inject a UIView controller and redraw
    public func injectVC() {
        inject()
        for subview in self.view.subviews {
            subview.removeFromSuperview()
        }
        if let sublayers = self.view.layer.sublayers {
            for sublayer in sublayers {
                sublayer.removeFromSuperlayer()
            }
        }
        viewDidLoad()
    }
}
#else
import Cocoa
#endif

extension NSObject {

    public func inject() {
        if let oldClass: AnyClass = object_getClass(self) {
            SwiftInjection.inject(oldClass: oldClass, classNameOrFile: "\(oldClass)")
        }
    }

    @objc
    public class func inject(file: String) {
        SwiftInjection.inject(oldClass: nil, classNameOrFile: file)
    }
}

@objc(SwiftInjection)
public class SwiftInjection: NSObject {

    static let testQueue = DispatchQueue(label: "INTestQueue")
    static let injectableSuffixes = ["fC", "yF", "lF", "tF", "Qrvg"]

    @objc
    public class func inject(oldClass: AnyClass?, classNameOrFile: String) {
        do {
            let tmpfile = try SwiftEval.instance.rebuildClass(oldClass: oldClass,
                                    classNameOrFile: classNameOrFile, extra: nil)
            try inject(tmpfile: tmpfile)
        }
        catch {
        }
    }

    @objc
    public class func replayInjections() -> Int {
        var injectionNumber = 0
        do {
            func mtime(_ path: String) -> time_t {
                return SwiftEval.instance.mtime(URL(fileURLWithPath: path))
            }
            let execBuild = mtime(Bundle.main.executablePath!)

            while true {
                let tmpfile = "/tmp/eval\(injectionNumber+1)"
                if mtime("\(tmpfile).dylib") < execBuild {
                    break
                }
                try inject(tmpfile: tmpfile)
                injectionNumber += 1
            }
        }
        catch {
        }
        return injectionNumber
    }

    @objc static var traceInjection = false
    static var injectedPrefix: String {
        return "Injection#\(SwiftEval.instance.injectionNumber)/"
    }

    @objc
    public class func inject(tmpfile: String) throws {
        let newClasses = try SwiftEval.instance.loadAndInject(tmpfile: tmpfile)
        let oldClasses = //oldClass != nil ? [oldClass!] :
            newClasses.map { objc_getClass(class_getName($0)) as! AnyClass }
        var testClasses = [AnyClass]()

        for i in 0..<oldClasses.count {
            let oldClass: AnyClass = oldClasses[i], newClass: AnyClass = newClasses[i]

            // old-school swizzle Objective-C class & instance methods
            injection(swizzle: object_getClass(newClass), onto: object_getClass(oldClass))
            injection(swizzle: newClass, onto: oldClass)

            // overwrite Swift vtable of existing class with implementations from new class
            let existingClass = unsafeBitCast(oldClass, to:
                UnsafeMutablePointer<ClassMetadataSwift>.self)
            let classMetadata = unsafeBitCast(newClass, to:
                UnsafeMutablePointer<ClassMetadataSwift>.self)

            // Is this a Swift class?
            // Reference: https://github.com/apple/swift/blob/master/include/swift/ABI/Metadata.h#L1195
            let oldSwiftCondition = classMetadata.pointee.Data & 0x1 == 1
            let newSwiftCondition = classMetadata.pointee.Data & 0x3 != 0
            let isSwiftClass = newSwiftCondition || oldSwiftCondition
            if isSwiftClass {
                // Old mechanism for Swift equivalent of "Swizzling".
                if classMetadata.pointee.ClassSize != existingClass.pointee.ClassSize {
                    print("\(APP_PREFIX)⚠️ Adding or removing methods on Swift classes is not supported. Your application will likely crash. ⚠️")
                }

                #if true // replaced by "interpose" code below
                func byteAddr<T>(_ location: UnsafeMutablePointer<T>) -> UnsafeMutablePointer<UInt8> {
                    return location.withMemoryRebound(to: UInt8.self, capacity: 1) { $0 }
                }

                let vtableOffset = byteAddr(&existingClass.pointee.IVarDestroyer) - byteAddr(existingClass)

                #if false
                // original injection implementaion for Swift.
                let vtableLength = Int(existingClass.pointee.ClassSize -
                    existingClass.pointee.ClassAddressPoint) - vtableOffset

                memcpy(byteAddr(existingClass) + vtableOffset,
                       byteAddr(classMetadata) + vtableOffset, vtableLength)
                #else
                // untried version only copying function pointers.
                let newTable = (byteAddr(classMetadata) + vtableOffset)
                    .withMemoryRebound(to: SwiftTrace.SIMP.self, capacity: 1) { $0 }

                SwiftTrace.iterateMethods(ofClass: oldClass) {
                    (name, slotIndex, vtableSlot, stop) in
                    vtableSlot.pointee = newTable[slotIndex]
                }
                #endif
                #endif
            }

            print("\(APP_PREFIX)Injected class '\(_typeName(oldClass))'")

            if let XCTestCase = objc_getClass("XCTestCase") as? AnyClass,
                newClass.isSubclass(of: XCTestCase) {
                testClasses.append(newClass)
//                if ( [newClass isSubclassOfClass:objc_getClass("QuickSpec")] )
//                [[objc_getClass("_TtC5Quick5World") sharedWorld]
//                setCurrentExampleMetadata:nil];
            }
        }

        findSwiftSymbols("\(tmpfile).dylib", "VN") {
            (typePtr, symbol, _, _) in
            if let existing: Any.Type =
                autoBitCast(dlsym(SwiftMeta.RTLD_DEFAULT, symbol)) {
                print("\(APP_PREFIX)Injected value type '\(_typeName(existing))'")
                if SwiftMeta.sizeof(anyType: autoBitCast(typePtr)) !=
                   SwiftMeta.sizeof(anyType: existing) {
                    print("\(APP_PREFIX)⚠️ Size of value type \(_typeName(existing)) has changed. You cannot inject changes to memory layout. This will likely just crash. ⚠️")
                }
            }
        }

        // new mechanism for injection of Swift functions,
        // using "interpose" API from dynamic loader along
        // with -Xlinker -interposable other linker flags.
        interpose(functionsIn: "\(tmpfile).dylib")

        // Thanks https://github.com/johnno1962/injectionforxcode/pull/234
        if !testClasses.isEmpty {
            testQueue.async {
                testQueue.suspend()
                let timer = Timer(timeInterval: 0, repeats:false, block: { _ in
                    for newClass in testClasses {
                        NSObject.runXCTestCase(newClass)
                    }
                    testQueue.resume()
                })
                RunLoop.main.add(timer, forMode: RunLoop.Mode.common)
            }
        } else {
            performSweep(oldClasses: oldClasses)

            let notification = Notification.Name("INJECTION_BUNDLE_NOTIFICATION")
            NotificationCenter.default.post(name: notification, object: oldClasses)
        }
    }

    #if false
    static var installDLKitLogger: Void = {
        DLKit.logger = { (msg: String) in
            print("\(APP_PREFIX)\(msg)")
        }
    }()
    #endif

    public class func interpose(functionsIn dylib: String) {
        let detail = getenv("INJECTION_DETAIL") != nil
        var symbols = [UnsafePointer<Int8>]()
        #if false // New DLKit based interposing
        // ... doesn't play well with tracing.
        _ = installDLKitLogger
        var replacements = [UnsafeMutableRawPointer]()

        // Find all definitions of Swift functions and ...
        // SwiftUI body properties defined in the new dylib.

        for (symbol, value, _) in DLKit.lastImage
            .swiftSymbols(withSuffixes: injectableSuffixes) {
            guard var replacement = value else {
                continue
            }
            let method = symbol.demangled ?? String(cString: symbol)
            if detail {
                print("\(APP_PREFIX)Replacing \(method)")
            }

            if traceInjection || SwiftTrace.isTracing, let tracer = SwiftTrace
                .trace(name: injectedPrefix+method, original: replacement) {
                replacement = autoBitCast(tracer)
            }

            symbols.append(symbol)
            replacements.append(replacement)
        }

        // Rebind all references in all images in the app bundle
        // to function symbols defined in the last loaded dylib
        // to the new implementations in the newly loaded dylib.
        DLKit.appImages[symbols] = replacements
        #else // SwiftTrace based code...
        let main = dlopen(nil, RTLD_NOW)
        var interposes = [dyld_interpose_tuple]()

        for suffix in SwiftTrace.swiftFunctionSuffixes {
            findSwiftSymbols(dylib, suffix) { (loadedFunc, symbol, _, _) in
                guard let existing = dlsym(main, symbol), existing != loadedFunc,
                    let current = SwiftTrace.interposed(replacee: existing) else {
                    return
                }
                let method = SwiftMeta.demangle(symbol: symbol) ?? String(cString: symbol)
                if detail {
                    print("\(APP_PREFIX)Replacing \(method)")
                }

                var replacement = loadedFunc
                if traceInjection || SwiftTrace.isTracing, let tracer = SwiftTrace
                    .trace(name: injectedPrefix+method, original: replacement) {
                    replacement = autoBitCast(tracer)
                }
                interposes.append(dyld_interpose_tuple(
                    replacement: replacement, replacee: current))
                symbols.append(symbol)
                #if ORIGINAL_2_2_0_CODE
                SwiftTrace.interposed[existing] = loadedFunc
                SwiftTrace.interposed[current] = loadedFunc
                #endif
            }
        }
        
        #if !ORIGINAL_2_2_0_CODE
        if interposes.count != 0 &&
            SwiftTrace.apply(interposes: interposes, symbols: symbols, onInjection: { header in
            #if !arch(arm64)
            let interposed = NSObject.swiftTraceInterposed.bindMemory(to:
                [UnsafeRawPointer : UnsafeRawPointer].self, capacity: 1)
            // Need to apply all previous interposes
            // to the newly loaded dylib as well.
            var previous = Array<dyld_interpose_tuple>()
            for (replacee, replacement) in interposed.pointee {
                previous.append(dyld_interpose_tuple(
                    replacement: SwiftTrace.interposed(replacee: replacement)!,
                    replacee: replacee))
            }
            _ = SwiftTrace.apply(interposes: previous, symbols: symbols)
            #endif
        }) == 0 {
            print("\(APP_PREFIX)⚠️ Injection has failed. Have you added -Xlinker -interposable to your project's \"Other Linker Flags\"? ⚠️")
        }
        #else
        // Using array of new interpose structs
        interposes.withUnsafeBufferPointer { interps in

            var mostRecentlyLoaded = true
            // Apply interposes to all images in the app bundle
            // as well as the most recently loaded "new" dylib.
            appBundleImages { image, header in
                if mostRecentlyLoaded {
                    // Need to apply all previous interposes
                    // to the newly loaded dylib as well.
                    var previous = Array<dyld_interpose_tuple>()
                    for (replacee, replacement) in SwiftTrace.interposed {
                        previous.append(dyld_interpose_tuple(
                                replacement: replacement, replacee: replacee))
                    }
                    previous.withUnsafeBufferPointer {
                        interps in
                        dyld_dynamic_interpose(header,
                                           interps.baseAddress!, interps.count)
                    }
                    mostRecentlyLoaded = false
                }
                // patch out symbols defined by new dylib.
                dyld_dynamic_interpose(header,
                                       interps.baseAddress!, interps.count)
//                print("Patched \(String(cString: image))")
            }
        }
        #endif
        #endif
    }

    static var sweepWarned = false

    public class func performSweep(oldClasses: [AnyClass]) {
        var injectedClasses = [AnyClass]()
        let injectedSEL = #selector(SwiftInjected.injected)
        typealias ClassIMP = @convention(c) (AnyClass, Selector) -> ()
        for cls in oldClasses {
            if let classMethod = class_getClassMethod(cls, injectedSEL) {
                let classIMP = method_getImplementation(classMethod)
                unsafeBitCast(classIMP, to: ClassIMP.self)(cls, injectedSEL)
            }
            if class_getInstanceMethod(cls, injectedSEL) != nil {
                injectedClasses.append(cls)
                if !sweepWarned {
                    print("""
                        \(APP_PREFIX)As class \(cls) has an @objc injected() \
                        method, \(APP_NAME) will perform a "sweep" of live \
                        instances to determine which objects to message. \
                        If this fails, subscribe to the notification \
                        "INJECTION_BUNDLE_NOTIFICATION" instead.
                        """)
                    sweepWarned = true
                }
                let kvoName = "NSKVONotifying_" + NSStringFromClass(cls)
                if let kvoCls = NSClassFromString(kvoName) {
                    injectedClasses.append(kvoCls)
                }
            }
        }

        // implement -injected() method using sweep of objects in application
        if !injectedClasses.isEmpty {
            #if os(iOS) || os(tvOS)
            let app = UIApplication.shared
            #else
            let app = NSApplication.shared
            #endif
            let seeds: [Any] =  [app.delegate as Any] + app.windows
            SwiftSweeper(instanceTask: {
                (instance: AnyObject) in
                if injectedClasses.contains(where: { $0 == object_getClass(instance) }) {
                    let proto = unsafeBitCast(instance, to: SwiftInjected.self)
                    if SwiftEval.sharedInstance().vaccineEnabled {
                        performVaccineInjection(instance)
                        proto.injected?()
                        return
                    }

                    proto.injected?()

                    #if os(iOS) || os(tvOS)
                    if let vc = instance as? UIViewController {
                        flash(vc: vc)
                    }
                    #endif
                }
            }).sweepValue(seeds)
        }
    }

    @objc(vaccine:)
    public class func performVaccineInjection(_ object: AnyObject) {
        let vaccine = Vaccine()
        vaccine.performInjection(on: object)
    }

    #if os(iOS) || os(tvOS)
    @objc(flash:)
    public class func flash(vc: UIViewController) {
        DispatchQueue.main.async {
            let v = UIView(frame: vc.view.frame)
            v.backgroundColor = .white
            v.alpha = 0.3
            vc.view.addSubview(v)
            UIView.animate(withDuration: 0.2,
                           delay: 0.0,
                           options: UIView.AnimationOptions.curveEaseIn,
                           animations: {
                            v.alpha = 0.0
            }, completion: { _ in v.removeFromSuperview() })
        }
    }
    #endif

    static func injection(swizzle newClass: AnyClass?, onto oldClass: AnyClass?) {
        var methodCount: UInt32 = 0
        if let methods = class_copyMethodList(newClass, &methodCount) {
            for i in 0 ..< Int(methodCount) {
                let method = method_getName(methods[i])
                var replacement = method_getImplementation(methods[i])
                if traceInjection, let tracer = SwiftTrace
                    .trace(name: injectedPrefix+NSStringFromSelector(method),
                    objcMethod: methods[i], objcClass: newClass,
                    original: autoBitCast(replacement)) {
                    replacement = autoBitCast(tracer)
                }
                class_replaceMethod(oldClass, method, replacement,
                                    method_getTypeEncoding(methods[i]))
            }
            free(methods)
        }
    }

    @objc class func dumpStats(top: Int) {
        let invocationCounts =  SwiftTrace.invocationCounts()
        for (method, elapsed) in SwiftTrace.sortedElapsedTimes(onlyFirst: top) {
            print("\(String(format: "%.1f", elapsed*1000.0))ms/\(invocationCounts[method] ?? 0)\t\(method)")
        }
    }

    @objc class func callOrder() -> [String] {
        return SwiftTrace.callOrder().map { $0.signature }
    }

    @objc class func fileOrder() {
        let builder = SwiftEval.sharedInstance()
        let signatures = callOrder()

        guard let projectRoot = builder.projectFile.flatMap({
                URL(fileURLWithPath: $0).deletingLastPathComponent().path+"/"
            }),
            let (_, logsDir) =
                try? builder.determineEnvironment(classNameOrFile: "") else {
            print("\(APP_PREFIX)File ordering not available.")
            return
        }

        let tmpfile = builder.tmpDir+"/eval101"
        var found = false

        SwiftEval.uniqueTypeNames(signatures: signatures) { typeName in
            if !typeName.contains("("), let (_, foundSourceFile) =
                try? builder.findCompileCommand(logsDir: logsDir,
                    classNameOrFile: typeName, tmpfile: tmpfile) {
                print(foundSourceFile
                        .replacingOccurrences(of: projectRoot, with: ""))
                found = true
            }
        }
        
        if !found {
            print("\(APP_PREFIX)Do you have the right project selected?")
        }
    }

    @objc class func packageNames() -> [String] {
        var packages = Set<String>()
        for suffix in SwiftTrace.swiftFunctionSuffixes {
            findSwiftSymbols(Bundle.main.executablePath!, suffix) {
                (_, symname: UnsafePointer<Int8>, _, _) in
                if let sym = SwiftMeta.demangle(symbol: String(cString: symname)),
                    !sym.hasPrefix("(extension in "),
                    let endPackage = sym.firstIndex(of: ".") {
                    packages.insert(sym[..<(endPackage+0)])
                }
            }
        }
        return Array(packages)
    }

    @objc class func objectCounts() {
        for (className, count) in SwiftTrace.liveObjects
            .map({(_typeName(autoBitCast($0.key)), $0.value.count)})
            .sorted(by: {$0.0 < $1.0}) {
            print("\(count)\t\(className)")
        }
    }
}

@objc
public class SwiftInjectionEval: UnhidingEval {

    @objc public override class func sharedInstance() -> SwiftEval {
        SwiftEval.instance = SwiftInjectionEval()
        return SwiftEval.instance
    }

    @objc override func extractClasses(dl: UnsafeMutableRawPointer,
                                       tmpfile: String) throws -> [AnyClass] {
        var classes = [AnyClass]()
        SwiftTrace.forAllClasses(bundlePath: "\(tmpfile).dylib") {
            aClass, stop in
            classes.append(aClass)
        }
        return classes
    }
}
#endif
