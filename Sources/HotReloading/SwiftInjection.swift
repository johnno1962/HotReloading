//
//  SwiftInjection.swift
//  InjectionBundle
//
//  Created by John Holdsworth on 05/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/SwiftInjection.swift#71 $
//
//  Cut-down version of code injection in Swift. Uses code
//  from SwiftEval.swift to recompile and reload class.
//
//  There is a lot of history in this file. Originaly injection for Swift
//  worked by patching the vtable of non final classes which worked fairly
//  well but then we discovered "interposing" which is a mechanisim used by
//  the dynamic linker to resolve references to system frameworks that can
//  be used to rebind symbols at run time. This meant we were able to support
//  injecting final methods of classes and methods of struct, enums at last.
//
//  The most recent change is to better supprt injection of generic classes
//  and classes that inherit from generics which cause problems (crashes) in
//  the Objective-C runtime. As you can't anticipate the specialisation of
//  a generic in use from the object file (dylib) alone the patching of the
//  vtable has been moved to the sweep which means you have to have a live
//  object of that type for injection to work.
//

#if arch(x86_64) || arch(i386) || arch(arm64) // simulator/macOS only
import Foundation
import SwiftTrace
#if SWIFT_PACKAGE
import HotReloadingGuts
import SwiftTraceGuts
import DLKit
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
    static let injectedSEL = #selector(SwiftInjected.injected)
    #if os(iOS) || os(tvOS)
    static let viewDidLoadSEL = #selector(UIViewController.viewDidLoad)
    #endif
    static let notification = Notification.Name("INJECTION_BUNDLE_NOTIFICATION")

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

    class func versions(of aClass: AnyClass) -> [AnyClass] {
        let named = class_getName(aClass)
        var out = [AnyClass]()
        var nc: UInt32 = 0
        if let classes = UnsafePointer(objc_copyClassList(&nc)) {
            for i in 0 ..< Int(nc) {
                if class_getSuperclass(classes[i]) != nil &&
                    strcmp(named, class_getName(classes[i])) == 0 {
                    out.append(classes[i])
                }
            }
            free(UnsafeMutableRawPointer(mutating: classes))
        }
        return out
    }

    @objc
    public class func inject(tmpfile: String) throws {
        let newClasses = try SwiftEval.instance.loadAndInject(tmpfile: tmpfile)
        let oldClasses = //oldClass != nil ? [oldClass!] :
            newClasses.map { objc_getClass(class_getName($0)) as? AnyClass ?? $0 }
        var genericPrefixes = Set<String>()
        var testClasses = [AnyClass]()
        var swizzled = 0

        // Determine any generic classes being injected.
        findSwiftSymbols("\(tmpfile).dylib", "CMa") {
            accessor, symname, _, _ in
            if let demangled = SwiftMeta.demangle(symbol: symname),
               let genericClassName = demangled[safe: (.last(of: " ")+1)...] {
                genericPrefixes.insert(genericClassName)
            }
        }

        // The old way for non-generics
        for i in 0..<oldClasses.count {
            var oldClass: AnyClass = oldClasses[i], newClass: AnyClass = newClasses[i]

            swizzled += patchSwiftVtable(oldClass: oldClass, newClass: newClass)

            print("\(APP_PREFIX)Injecting class '\(_typeName(oldClass))' (\(swizzled))")

           // Is there a generic superclass?
            var inheritedGeneric: AnyClass? = oldClass
            while let parent = inheritedGeneric {
                if _typeName(parent).contains("<") {
                    break
                }
                inheritedGeneric = parent.superclass()
            }

            // ... if so, skip processing using objc runtime.
            guard inheritedGeneric == nil else {
                swizzleBasics(oldClass: oldClass, tmpfile: tmpfile)
                continue
            }
            genericPrefixes.remove(_typeName(oldClass))

            if oldClass === newClass {
                let versions = Self.versions(of: newClass)
                if versions.count > 1 {
                    oldClass = versions.first!
                    newClass = versions.last!
                } else {
                    print("\(APP_PREFIX)⚠️ Could not find versions of class \(_typeName(newClass)). ⚠️")
                }
            }

            // old-school swizzle Objective-C class & instance methods
            swizzled += injection(swizzle: object_getClass(newClass),
                                  onto: object_getClass(oldClass))
            swizzled += injection(swizzle: newClass, onto: oldClass)

            if let XCTestCase = objc_getClass("XCTestCase") as? AnyClass,
                newClass.isSubclass(of: XCTestCase) {
                testClasses.append(newClass)
//                if ( [newClass isSubclassOfClass:objc_getClass("QuickSpec")] )
//                [[objc_getClass("_TtC5Quick5World") sharedWorld]
//                setCurrentExampleMetadata:nil];
            }
        }

        // log any value types being injected
        findSwiftSymbols("\(tmpfile).dylib", "VN") {
            (typePtr, symbol, _, _) in
            if let existing: Any.Type =
                autoBitCast(dlsym(SwiftMeta.RTLD_DEFAULT, symbol)) {
                print("\(APP_PREFIX)Injecting value type '\(_typeName(existing))'")
                if SwiftMeta.sizeof(anyType: autoBitCast(typePtr)) !=
                   SwiftMeta.sizeof(anyType: existing) {
                    print("\(APP_PREFIX)⚠️ Size of value type \(_typeName(existing)) has changed. You cannot inject changes to memory layout. This will likely just crash. ⚠️")
                }
            }
        }

        // new mechanism for injection of Swift functions,
        // using "interpose" API from dynamic loader along
        // with -Xlinker -interposable "Other Linker Flags".
        interpose(functionsIn: "\(tmpfile).dylib", swizzled)

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
            performSweep(oldClasses: oldClasses, tmpfile, genericPrefixes)

            NotificationCenter.default.post(name: notification, object: oldClasses)
        }
    }

    /// Patch entries in vtable of existing class to be that in newly loaded versio of class for non-final methods
    class func patchSwiftVtable(oldClass: AnyClass, newClass: AnyClass) -> Int {
        // overwrite Swift vtable of existing class with implementations from new class
        let existingClass = unsafeBitCast(oldClass, to:
            UnsafeMutablePointer<ClassMetadataSwift>.self)
        let classMetadata = unsafeBitCast(newClass, to:
            UnsafeMutablePointer<ClassMetadataSwift>.self)

        // Is this a Swift class?
        // Reference: https://github.com/apple/swift/blob/master/include/swift/ABI/Metadata.h#L1195
        let oldSwiftCondition = classMetadata.pointee.Data & 0x1 == 1
        let newSwiftCondition = classMetadata.pointee.Data & 0x3 != 0

        guard newSwiftCondition || oldSwiftCondition else { return 0 }
        var swizzled = 0

        // Old mechanism for Swift equivalent of "Swizzling".
        if classMetadata.pointee.ClassSize != existingClass.pointee.ClassSize {
            print("\(APP_PREFIX)⚠️ Adding or removing methods on Swift classes is not supported. Your application will likely crash. ⚠️")
        }

        #if true // supplimented by "interpose" code
        // vtable still needs to be patched though for non-final methods
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
        // new version only copying only symbols that are functions.
        let newTable = (byteAddr(classMetadata) + vtableOffset)
            .withMemoryRebound(to: SwiftTrace.SIMP.self, capacity: 1) { $0 }

        SwiftTrace.iterateMethods(ofClass: oldClass) {
            (name, slotIndex, vtableSlot, stop) in
            if unsafeBitCast(vtableSlot.pointee, to: UnsafeRawPointer.self) !=
                autoBitCast(newTable[slotIndex]) {
                vtableSlot.pointee = newTable[slotIndex]
                swizzled += 1
            }
        }
        #endif
        #endif
        return swizzled
    }

    /// New way to patch Vtable looking up existing entries in newly loaded dylib.
    open class func patchSwiftVtable(oldClass: AnyClass, tmpfile: String) -> Int {
        var swizzled = 0, lastImage = DLKit.lastImage

        SwiftTrace.iterateMethods(ofClass: oldClass) {
            (name, slotIndex, vtableSlot, stop) in
            let existing = unsafeBitCast(vtableSlot.pointee,
                                         to: UnsafeMutableRawPointer.self)
            if let symfo = DLKit.appImages[existing],
               let replacement = lastImage[symfo.name], replacement != existing {
//                print("Patching", DLKit.lastImage.imageNumber.imagePath,
//                      existing, "->", replacement, String(cString: symfo.name))
                vtableSlot.pointee = autoBitCast(replacement)
                swizzled += 1
            }
        }

        return swizzled
    }

    // Make sure at least the @objc func injected() method is swizzled
    open class func swizzleBasics(oldClass: AnyClass, tmpfile: String) {
        swizzle(oldClass: oldClass, selector: injectedSEL, tmpfile)
        #if os(iOS) || os(tvOS)
        swizzle(oldClass: oldClass, selector: viewDidLoadSEL, tmpfile)
        #endif
    }

    open class func swizzle(oldClass: AnyClass, selector: Selector, _ tmpfile: String) {
        if let method = class_getInstanceMethod(oldClass, selector),
            let existing = unsafeBitCast(method_getImplementation(method),
                                         to: UnsafeMutableRawPointer?.self),
            let symfo = DLKit.allImages[existing] {
            findHiddenSwiftSymbols("\(tmpfile).dylib", symfo.name, ST_LOCAL_VISIBILITY) {
                (replacement, symbol, _, _) in
//                print("Swizzling", oldClass, existing, "->", replacement)
                class_replaceMethod(oldClass, selector,
                                    unsafeBitCast(replacement, to: IMP.self),
                                    method_getTypeEncoding(method))
            }
        }
    }

    open class func patchGenerics(oldClass: AnyClass, tmpfile: String,
                                  genericPrefixes: Set<String>) -> Bool {
        if let genericClassName = _typeName(oldClass)[safe: ..<(.first(of: "<"))],
           genericPrefixes.contains(genericClassName) {
            let swizzled = patchSwiftVtable(oldClass: oldClass, tmpfile: tmpfile)
            swizzleBasics(oldClass: oldClass, tmpfile: tmpfile)
            print("\(APP_PREFIX)Injecting generic '\(oldClass)' (\(swizzled))")
            return true
        }
        return false
    }

    static var installDLKitLogger: Void = {
        DLKit.logger = { (msg: String) in
            print("\(APP_PREFIX)\(msg)")
        }
    }()

    public class func interpose(functionsIn dylib: String,
                                _ swizzled: Int) {
        let detail = getenv("INJECTION_DETAIL") != nil
        var symbols = [UnsafePointer<Int8>]()
        _ = installDLKitLogger

        #if false // DLKit based interposing
        // ... doesn't play well with tracing.
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

        #else // Original SwiftTrace based code...
        let main = dlopen(nil, RTLD_NOW)
        var interposes = [dyld_interpose_tuple]()

        for suffix in SwiftTrace.swiftFunctionSuffixes {
            findSwiftSymbols(dylib, suffix) { (loadedFunc, symbol, _, _) in
                guard let existing = dlsym(main, symbol), existing != loadedFunc/*,
                    let current = SwiftTrace.interposed(replacee: existing)*/ else {
                    return
                }
                let current = existing
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
            SwiftTrace.apply(interposes: interposes, symbols: symbols, onInjection: { (header, slide) in
            let interposed = NSObject.swiftTraceInterposed.bindMemory(to:
                [UnsafeRawPointer : UnsafeRawPointer].self, capacity: 1)
            var info = Dl_info()
            // Need to apply previous interposes
            // to the newly loaded dylib as well.
            var previous = Array<rebinding>()
            var already = Set<UnsafeRawPointer>()
            for (replacee, _) in interposed.pointee {
                if let replacement = SwiftTrace.interposed(replacee: replacee),
                   !already.contains(replacement),
                   dladdr(replacee, &info) != 0, let symname = info.dli_sname {
                    previous.append(rebinding(name: symname, replacement:
                        UnsafeMutableRawPointer(mutating: replacement),
                                              replaced: nil))
                    already.insert(replacement)
                }
            }
            rebind_symbols_image(UnsafeMutableRawPointer(mutating: header),
                                 slide, &previous, previous.count)
        }) + swizzled == 0 {
            print("\(APP_PREFIX)⚠️ Injection may have failed. Have you added -Xlinker -interposable to the \"Other Linker Flags\" of the executable/framework? ⚠️")
//            if #available(iOS 15.0, tvOS 15.0, macOS 12.0, *) {
//                print("""
//                    \(APP_PREFIX)⚠️ Unfortunately, interposing Swift symbols is not availble when targetting iOS 15+ ⚠️
//                    \(APP_PREFIX)You can work around this by using a pre-Xcode 13 linker by adding another linker flag:
//                    \(APP_PREFIX)-fuse-ld=/Applications/Xcode12.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/ld
//                    """)
//            }
        }
        #else // ORIGINAL_2_2_0_CODE replaced by fishhook
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

    open class func performSweep(oldClasses: [AnyClass], _ tmpfile: String,
                                   _ genericPrefixes: Set<String>) {
        var injectedClasses = [AnyClass]()
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
                        \(APP_PREFIX)(note: notification may not arrive on the main thread)
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
        if !injectedClasses.isEmpty || !genericPrefixes.isEmpty {
            #if os(iOS) || os(tvOS)
            let app = UIApplication.shared
            #else
            let app = NSApplication.shared
            #endif
            let seeds: [Any] =  [app.delegate as Any] + app.windows
            var patched = Set<UnsafeRawPointer>()
            SwiftSweeper(instanceTask: {
                (instance: AnyObject) in
                if let instanceClass = object_getClass(instance),
                   injectedClasses.contains(where: { $0 == instanceClass }) ||
                    !genericPrefixes.isEmpty &&
                    patched.insert(autoBitCast(instanceClass)).inserted &&
                    patchGenerics(oldClass: instanceClass, tmpfile: tmpfile,
                                  genericPrefixes: genericPrefixes) {
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

    static func injection(swizzle newClass: AnyClass?, onto oldClass: AnyClass?) -> Int {
        var methodCount: UInt32 = 0, swizzled = 0
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
                swizzled += 1
            }
            free(methods)
        }
        return swizzled
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
        #if false // Just too dubious
        // Determine any generic classes being injected.
        // (Done as part of sweep in the end.)
        findSwiftSymbols("\(tmpfile).dylib", "CMa") {
            accessor, _, _, _ in
            struct Something {}
            typealias AF = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UnsafeRawPointer
            let tmd: Any.Type = Void.self
            let tmd0 = unsafeBitCast(tmd, to: UnsafeRawPointer.self)
            let tmd1 = unsafeBitCast(accessor, to: AF.self)(tmd0, tmd0)
            let tmd2 = unsafeBitCast(tmd1, to: Any.Type.self)
            if let genericClass = tmd2 as? AnyClass {
                classes.append(genericClass)
            }
        }
        #endif
        return classes
    }
}
#endif
