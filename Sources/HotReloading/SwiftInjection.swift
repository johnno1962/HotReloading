//
//  SwiftInjection.swift
//  InjectionBundle
//
//  Created by John Holdsworth on 05/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/SwiftInjection.swift#85 $
//
//  Cut-down version of code injection in Swift. Uses code
//  from SwiftEval.swift to recompile and reload class.
//
//  There is a lot of history in this file. Originaly injection for Swift
//  worked by patching the vtable of non final classes which worked fairly
//  well but then we discovered "interposing" which is a mechanisim used by
//  the dynamic linker to resolve references to system frameworks that can
//  be used to rebind symbols at run time if you use the -interposable linker
//  flag. This meant we were able to support injecting final methods of classes
//  and methods of structs and enums. The code still updates the vtable though.
//
//  The most recent change is to better supprt injection of generic classes
//  and classes that inherit from generics which causes problems (crashes) in
//  the Objective-C runtime. As one can't anticipate the specialisation of
//  a generic in use from the object file (.dylib) alone, the patching of the
//  vtable has been moved to the being a part of the sweep which means you need
//  to have a live object of that specialisation for injection to work.
//

#if arch(x86_64) || arch(i386) || arch(arm64) // simulator/macOS only
import Foundation
import SwiftTrace
#if SWIFT_PACKAGE
import HotReloadingGuts
import SwiftTraceGuts
import DLKit
#endif

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

    @objc static var traceInjection = false
    static let testQueue = DispatchQueue(label: "INTestQueue")
    static let injectedSEL = #selector(SwiftInjected.injected)
    #if os(iOS) || os(tvOS)
    static let viewDidLoadSEL = #selector(UIViewController.viewDidLoad)
    #endif
    static let notification = Notification.Name("INJECTION_BUNDLE_NOTIFICATION")
    static var injectedPrefix: String {
        return "Injection#\(SwiftEval.instance.injectionNumber)/"
    }
    static var installDLKitLogger: Void = {
        DLKit.logger = log
    }()

    open class func log(_ msg: String) {
        print(APP_PREFIX+msg)
    }

    @objc
    open class func inject(oldClass: AnyClass?, classNameOrFile: String) {
        do {
            let tmpfile = try SwiftEval.instance.rebuildClass(oldClass: oldClass,
                                    classNameOrFile: classNameOrFile, extra: nil)
            try inject(tmpfile: tmpfile)
        }
        catch {
        }
    }

    @objc
    open class func replayInjections() -> Int {
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

    open class func versions(of aClass: AnyClass) -> [AnyClass] {
        let named = class_getName(aClass)
        var out = [AnyClass](), nc: UInt32 = 0
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
    open class func inject(tmpfile: String) throws {
        let newClasses = try SwiftEval.instance.loadAndInject(tmpfile: tmpfile)
        let oldClasses = //oldClass != nil ? [oldClass!] :
            newClasses.map { objc_getClass(class_getName($0)) as? AnyClass ?? $0 }
        var totalPatched = 0, totalSwizzled = 0
        var injectedGenerics = Set<String>()
        var testClasses = [AnyClass]()
        _ = installDLKitLogger

        // Determine any generic classes being injected.
        findSwiftSymbols("\(tmpfile).dylib", "CMa") {
            accessor, symname, _, _ in
            if let demangled = SwiftMeta.demangle(symbol: symname),
               let genericClassName = demangled[safe: (.last(of: " ")+1)...] {
                injectedGenerics.insert(genericClassName)
            }
        }

        // The old way for non-generics
        for i in 0..<oldClasses.count {
            var oldClass: AnyClass = oldClasses[i], newClass: AnyClass = newClasses[i]
            injectedGenerics.remove(_typeName(oldClass))

            let patched = patchSwiftVtable(oldClass: oldClass, newClass: newClass)
            totalPatched += patched

            // Is there a generic superclass?
            var inheritedGeneric: AnyClass? = oldClass
            while let parent = inheritedGeneric {
                if _typeName(parent).contains("<") {
                    break
                }
                inheritedGeneric = parent.superclass()
            }

            if inheritedGeneric != nil {
                // fallback to limited processing avoiding objc runtime.
                // (object_getClass() and class_copyMethodList() crash)
                let swizzled = swizzleBasics(oldClass: oldClass, tmpfile: tmpfile)
                totalSwizzled += swizzled
                log("Injected class '\(_typeName(oldClass))' (\(patched),\(swizzled)).")
                continue
            }

            if oldClass == newClass {
                let versions = self.versions(of: newClass)
                if versions.count > 1 {
                    oldClass = versions.first!
                    newClass = versions.last!
                } else {
                    log("⚠️ Could not find versions of class \(_typeName(newClass)). ⚠️")
                }
            }

            // old-school swizzle Objective-C class & instance methods
            let swizzled = injection(swizzle: object_getClass(newClass),
                                     onto: object_getClass(oldClass)) +
                           injection(swizzle: newClass, onto: oldClass)
            totalSwizzled += swizzled

            log("Injected class '\(_typeName(oldClass))' (\(patched),\(swizzled))")

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
                log("Injected value type '\(_typeName(existing))'")
                if SwiftMeta.sizeof(anyType: autoBitCast(typePtr)) !=
                   SwiftMeta.sizeof(anyType: existing) {
                    log("⚠️ Size of value type \(_typeName(existing)) has changed. You cannot inject changes to memory layout. This will likely just crash. ⚠️")
                }
            }
        }

        // new mechanism for injection of Swift functions,
        // using "interpose" API from dynamic loader along
        // with -Xlinker -interposable "Other Linker Flags".
        let totalInterposed = interpose(functionsIn: "\(tmpfile).dylib")
        if totalInterposed != 0 {
            log("Interposed \(totalInterposed) functions")
        }

        if totalPatched + totalSwizzled + totalInterposed == 0 {
            log("⚠️ Injection may have failed. Have you added -Xlinker -interposable to the \"Other Linker Flags\" of the executable/framework? ⚠️")
        }

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
            performSweep(oldClasses: oldClasses, tmpfile, injectedGenerics)

            NotificationCenter.default.post(name: notification, object: oldClasses)
        }
    }

    #if true
    /// Patch entries in vtable of existing class to be that in newly loaded versio of class for non-final methods
    class func patchSwiftVtable(oldClass: AnyClass, newClass: AnyClass) -> Int {
        // overwrite Swift vtable of existing class with implementations from new class
        let existingClass = unsafeBitCast(oldClass, to:
            UnsafeMutablePointer<SwiftMeta.TargetClassMetadata>.self)
        let classMetadata = unsafeBitCast(newClass, to:
            UnsafeMutablePointer<SwiftMeta.TargetClassMetadata>.self)

        // Is this a Swift class?
        // Reference: https://github.com/apple/swift/blob/master/include/swift/ABI/Metadata.h#L1195
        let oldSwiftCondition = classMetadata.pointee.Data & 0x1 == 1
        let newSwiftCondition = classMetadata.pointee.Data & 0x3 != 0

        guard newSwiftCondition || oldSwiftCondition else { return 0 }
        var swizzled = 0

        // Old mechanism for Swift equivalent of "Swizzling".
        if classMetadata.pointee.ClassSize != existingClass.pointee.ClassSize {
            log("⚠️ Adding or [re]moving methods on non-final classes is not supported. Your application will likely crash. ⚠️")
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
    #endif

    /// Newer way to patch Vtable looking up existing entries individually in newly loaded dylib.
    open class func patchSwiftVtable(oldClass: AnyClass, newClass: AnyClass?,
                                     tmpfile: String) -> Int {
        var patched = 0, lastImage = DLKit.lastImage // DLKit.imageMap[tmpfile]

        let classMetadata = unsafeBitCast(newClass, to:
            UnsafeMutablePointer<SwiftMeta.TargetClassMetadata>?.self)

        func vtableAddr<T>(_ location: UnsafePointer<T>) -> UnsafePointer<T> {
            return location
        }

        let newTable = classMetadata.flatMap { vtableAddr(&$0.pointee.IVarDestroyer) }

        SwiftTrace.iterateMethods(ofClass: oldClass) {
            (name, slotIndex, vtableSlot, stop) in
            let existing: UnsafeMutableRawPointer = autoBitCast(vtableSlot.pointee)
            if let symfo = DLKit.appImages[existing],
               var replacement = lastImage[symfo.name] ?? // may have been traced..
                autoBitCast(newTable?[slotIndex]), replacement != existing {
//                print("Patching", DLKit.lastImage.imageNumber.imagePath,
//                      existing, "->", replacement, String(cString: symfo.name))
                if traceInjection || SwiftTrace.isTracing,
                   let demangled = SwiftMeta.demangle(symbol: symfo.name),
                   let tracer = SwiftTrace.trace(name: injectedPrefix+demangled,
                                                 original: replacement) {
                    replacement = autoBitCast(tracer)
                }

                vtableSlot.pointee = autoBitCast(replacement)
                patched += 1
            }
        }

        return patched
    }

    /// Make sure at least the @objc func injected() and viewDidLoad() methods are swizzled
    open class func swizzleBasics(oldClass: AnyClass, tmpfile: String) -> Int {
        var swizzled = swizzle(oldClass: oldClass, selector: injectedSEL, tmpfile)
        #if os(iOS) || os(tvOS)
        swizzled += swizzle(oldClass: oldClass, selector: viewDidLoadSEL, tmpfile)
        #endif
        return swizzled
    }

    /// Swizzle the newly loaded implementation of a selector onto oldClass
    open class func swizzle(oldClass: AnyClass, selector: Selector,
                            _ tmpfile: String) -> Int {
        var swizzled = 0
        if let method = class_getInstanceMethod(oldClass, selector),
            let existing = unsafeBitCast(method_getImplementation(method),
                                         to: UnsafeMutableRawPointer?.self),
            let symfo = DLKit.appImages[existing] {
            findHiddenSwiftSymbols("\(tmpfile).dylib", symfo.name, ST_LOCAL_VISIBILITY) {
                (replacement, symbol, _, _) in
//                print("Swizzling", oldClass, existing, "->", replacement)
                if replacement == existing { return }
                class_replaceMethod(oldClass, selector,
                                    unsafeBitCast(replacement, to: IMP.self),
                                    method_getTypeEncoding(method))
                swizzled += 1
            }
        }
        return swizzled
    }

    /// If class is a generic, patch its specialised vtable and basic selectors
    open class func patchGenerics(oldClass: AnyClass, tmpfile: String,
                                  injectedGenerics: Set<String>,
                                  patched: inout Set<UnsafeRawPointer>) -> Bool {
        if let genericClassName = _typeName(oldClass)[safe: ..<(.first(of: "<"))],
           injectedGenerics.contains(genericClassName) {
            if patched.insert(autoBitCast(oldClass)).inserted {
                let patched = patchSwiftVtable(oldClass: oldClass, newClass: nil,
                                               tmpfile: tmpfile)
                let swizzled = swizzleBasics(oldClass: oldClass, tmpfile: tmpfile)
                log("Injected generic '\(oldClass)' (\(patched),\(swizzled))")
            }
            return oldClass.instancesRespond(to: injectedSEL)
        }
        return false
    }

    /// "Interpose" all function definitions in a dylib onto the main executable
    open class func interpose(functionsIn dylib: String) -> Int {
        let detail = getenv("INJECTION_DETAIL") != nil
        var symbols = [UnsafePointer<Int8>]()

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
                log("Replacing \(method)")
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

        #else // Current SwiftTrace based code...
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
                    log("Replacing \(method)")
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
        if interposes.count == 0 {
            return 0
        }
        return SwiftTrace.apply(interposes: interposes, symbols: symbols,
            onInjection: { (header, slide) in
            var info = Dl_info()
            // Need to apply previous interposes
            // to the newly loaded dylib as well.
            var previous = Array<rebinding>()
            var already = Set<UnsafeRawPointer>()
            let interposed = NSObject.swiftTraceInterposed.bindMemory(to:
                [UnsafeRawPointer : UnsafeRawPointer].self, capacity: 1)
            for (replacee, _) in interposed.pointee {
                if let replacement = SwiftTrace.interposed(replacee: replacee),
                   already.insert(replacement).inserted,
                   dladdr(replacee, &info) != 0, let symname = info.dli_sname {
                    previous.append(rebinding(name: symname, replacement:
                        UnsafeMutableRawPointer(mutating: replacement),
                                              replaced: nil))
                }
            }
            rebind_symbols_image(UnsafeMutableRawPointer(mutating: header),
                                 slide, &previous, previous.count)
        })
        #else // ORIGINAL_2_2_0_CODE replaced by fishhook now
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
                                 _ injectedGenerics: Set<String>) {
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
                    log("""
                        As class \(cls) has an @objc injected() \
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
        if !injectedClasses.isEmpty || !injectedGenerics.isEmpty {
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
                    !injectedGenerics.isEmpty &&
                    patchGenerics(oldClass: instanceClass, tmpfile: tmpfile,
                        injectedGenerics: injectedGenerics, patched: &patched) {
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
    open class func performVaccineInjection(_ object: AnyObject) {
        let vaccine = Vaccine()
        vaccine.performInjection(on: object)
    }

    #if os(iOS) || os(tvOS)
    @objc(flash:)
    open class func flash(vc: UIViewController) {
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
                if let existing = class_getInstanceMethod(oldClass, method),
                   replacement == method_getImplementation(existing) {
                    continue
                }
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

    @objc open class func dumpStats(top: Int) {
        let invocationCounts =  SwiftTrace.invocationCounts()
        for (method, elapsed) in SwiftTrace.sortedElapsedTimes(onlyFirst: top) {
            print("\(String(format: "%.1f", elapsed*1000.0))ms/\(invocationCounts[method] ?? 0)\t\(method)")
        }
    }

    @objc open class func callOrder() -> [String] {
        return SwiftTrace.callOrder().map { $0.signature }
    }

    @objc open class func fileOrder() {
        let builder = SwiftEval.sharedInstance()
        let signatures = callOrder()

        guard let projectRoot = builder.projectFile.flatMap({
                URL(fileURLWithPath: $0).deletingLastPathComponent().path+"/"
            }),
            let (_, logsDir) =
                try? builder.determineEnvironment(classNameOrFile: "") else {
            log("File ordering not available.")
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
            log("Do you have the right project selected?")
        }
    }

    @objc open class func packageNames() -> [String] {
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

    @objc open class func objectCounts() {
        for (className, count) in SwiftTrace.liveObjects
            .map({(_typeName(autoBitCast($0.key)), $0.value.count)})
            .sorted(by: {$0.0 < $1.0}) {
            print("\(count)\t\(className)")
        }
    }
}

@objc
public class SwiftInjectionEval: UnhidingEval {

    @objc override open class func sharedInstance() -> SwiftEval {
        SwiftEval.instance = SwiftInjectionEval()
        return SwiftEval.instance
    }

    @objc override open func extractClasses(dl: UnsafeMutableRawPointer,
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
