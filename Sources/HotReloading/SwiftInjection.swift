//
//  SwiftInjection.swift
//  InjectionBundle
//
//  Created by John Holdsworth on 05/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/SwiftInjection.swift#172 $
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
//  A more recent change is to better supprt injection of generic classes
//  and classes that inherit from generics which causes problems (crashes) in
//  the Objective-C runtime. As one can't anticipate the specialisation of
//  a generic in use from the object file (.dylib) alone, the patching of the
//  vtable has been moved to the being a part of the sweep which means you need
//  to have a live object of that specialisation for class injection to work.
//
//  Support was also added to use injection with projects using "The Composable
//  Architecture" (TCA) though you need to use a modified version of the repo:
//  https://github.com/thebrowsercompany/swift-composable-architecture/tree/develop
//
//  InjectionIII.app now supports injection of class methods, getters and setters
//  and will maintain the values of top level and static variables when they are
//  injected instead of their being reinitialised as the object file is reloaded.
//
//  Which Swift symbols can be patched or interposed is now centralised and
//  configurable using the closure SwiftTrace.injectableSymbol which has been
//  extended to include async functions which, while they can be injected, can
//  never be traced due to changes in the stack layout when using co-routines.
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
        injectSelf()
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
#endif

extension NSObject {

    public func injectSelf() {
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

    // Constants for environment variables
    static let INJECTION_DETAIL = "INJECTION_DETAIL"
    static let INJECTION_PROJECT_ROOT = "INJECTION_PROJECT_ROOT"
    static let INJECTION_DYNAMIC_CAST = "INJECTION_DYNAMIC_CAST"
    static let INJECTION_PRESERVE_STATICS = "INJECTION_PRESERVE_STATICS"
    static let INJECTION_SWEEP_DETAIL = "INJECTION_SWEEP_DETAIL"
    static let INJECTION_SWEEP_EXCLUDE = "INJECTION_SWEEP_EXCLUDE"
    static let INJECTION_OF_GENERICS = "INJECTION_OF_GENERICS"
    static let INJECTION_UNHIDE = "INJECTION_UNHIDE"

    static let testQueue = DispatchQueue(label: "INTestQueue")
    static let injectedSEL = #selector(SwiftInjected.injected)
    #if os(iOS) || os(tvOS)
    static let viewDidLoadSEL = #selector(UIViewController.viewDidLoad)
    #endif
    static let notification = Notification.Name("INJECTION_BUNDLE_NOTIFICATION")

    static var injectionDetail = getenv(INJECTION_DETAIL) != nil
    static var objcClassRefs = NSMutableArray()
    static var descriptorRefs = NSMutableArray()
    static var injectedPrefix: String {
        return "Injection#\(SwiftEval.instance.injectionNumber)/"
    }

    open class func log(_ what: Any...) {
        print(APP_PREFIX+what.map {"\($0)"}.joined(separator: " "))
    }
    open class func detail(_ msg: @autoclosure () -> String) {
        if injectionDetail {
            log(msg())
        }
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
                if class_getSuperclass(classes[i]) != nil && classes[i] != aClass,
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
        try inject(tmpfile: tmpfile, newClasses:
            SwiftEval.instance.loadAndInject(tmpfile: tmpfile))
    }

    @objc
    open class func inject(tmpfile: String, newClasses: [AnyClass]) throws {
        var totalPatched = 0, totalSwizzled = 0
        var injectedGenerics = Set<String>()
        var injectedClasses = [AnyClass]()
        var sweepClasses = [AnyClass]()
        var testClasses = [AnyClass]()

        injectionDetail = getenv(INJECTION_DETAIL) != nil
        SwiftTrace.preserveStatics = getenv(INJECTION_PRESERVE_STATICS) != nil

        // Determine any generic classes being injected.
        findSwiftSymbols(searchLastLoaded(), "CMa") {
            accessor, symname, _, _ in
            if let demangled = SwiftMeta.demangle(symbol: symname),
               let genericClassName = demangled[safe: (.last(of: " ")+1)...],
               !genericClassName.hasPrefix("__C.") {
                injectedGenerics.insert(genericClassName)
            }
        }

        // First, the old way for non-generics
        for var newClass: AnyClass in newClasses {
            let oldClasses = versions(of: newClass)
            injectedGenerics.remove(_typeName(newClass))
            sweepClasses += oldClasses

            for var oldClass: AnyClass in oldClasses {
                let oldClassName = _typeName(oldClass) +
                    String(format: " %p", unsafeBitCast(oldClass, to: uintptr_t.self))
                #if true
                let patched = patchSwiftVtable(oldClass: oldClass, newClass: newClass)
                #else
                let patched = newPatchSwiftVtable(oldClass: oldClass, tmpfile: tmpfile)
                #endif

                if patched != 0 {
                    totalPatched += patched

                    let existingClass = unsafeBitCast(oldClass, to:
                        UnsafeMutablePointer<SwiftMeta.TargetClassMetadata>.self)
                    let classMetadata = unsafeBitCast(newClass, to:
                        UnsafeMutablePointer<SwiftMeta.TargetClassMetadata>.self)

                    // Old mechanism for Swift equivalent of "Swizzling".
                    if classMetadata.pointee.ClassSize != existingClass.pointee.ClassSize {
                        log("""
                            ⚠️ Adding or [re]moving methods of non-final classes is not supported. \
                            Your application will likely crash. Paradoxically, you can avoid this by \
                            making the class you are trying to inject (and add methods to) "final". ⚠️
                            """)
                    }
                }

                // Is there a generic superclass?
                if inheritedGeneric(anyType: oldClass) {
                    // fallback to limited processing avoiding objc runtime.
                    // (object_getClass() and class_copyMethodList() crash)
                    let swizzled = swizzleBasics(oldClass: oldClass, tmpfile: tmpfile)
                    totalSwizzled += swizzled
                    detail("Injected class '\(oldClassName)' (\(patched),\(swizzled)).")
                    continue
                }

                if oldClass == newClass {
                    if oldClasses.count > 1 {
                        oldClass = oldClasses.first!
                        newClass = oldClasses.last!
                    } else {
                        log("⚠️ Could not find versions of class \(_typeName(newClass)). ⚠️")
                    }
                }

                var swizzled: Int
                if lastPseudoImage() == nil {
                // old-school swizzle Objective-C class & instance methods
                    swizzled = injection(swizzle: object_getClass(newClass),
                                         onto: object_getClass(oldClass)) +
                               injection(swizzle: newClass, onto: oldClass)
                } else {
                    swizzled = injection(swizzle: object_getClass(oldClass)!,
                                         tmpfile: tmpfile) +
                               injection(swizzle: oldClass, tmpfile: tmpfile)
                }
                totalSwizzled += swizzled

                detail("Patched class '\(oldClassName)' (\(patched),\(swizzled))")
            }

            if let XCTestCase = objc_getClass("XCTestCase") as? AnyClass,
                newClass.isSubclass(of: XCTestCase) {
                testClasses.append(newClass)
            }

            injectedClasses.append(newClass)
        }

        // (Reverse) interposing, reducers, operation on a device etc.
        let totalInterposed = newerProcessing(tmpfile: tmpfile)
        if totalPatched + totalSwizzled + totalInterposed + testClasses.count == 0 {
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
        } else { // implemented class and instance injected() method
            typealias ClassIMP = @convention(c) (AnyClass, Selector) -> ()
            for cls in injectedClasses {
                if let classMethod = class_getClassMethod(cls, injectedSEL) {
                    let classIMP = method_getImplementation(classMethod)
                    unsafeBitCast(classIMP, to: ClassIMP.self)(cls, injectedSEL)
                }
            }
            performSweep(oldClasses: sweepClasses, tmpfile,
                getenv(INJECTION_OF_GENERICS) != nil ? injectedGenerics : [])

            NotificationCenter.default.post(name: notification, object: sweepClasses)
        }
    }

    open class func inheritedGeneric(anyType: Any.Type) -> Bool {
        var inheritedGeneric: Any.Type? = anyType
        while let parent = inheritedGeneric {
            if _typeName(parent).hasSuffix(">") {
                return true
            }
            inheritedGeneric = (parent as? AnyClass)?.superclass()
        }
        return false
    }

    open class func newerProcessing(tmpfile: String) -> Int {
        // new mechanism for injection of Swift functions,
        // using "interpose" API from dynamic loader along
        // with -Xlinker -interposable "Other Linker Flags".
        let interposed = Set(interpose(functionsIn: "\(tmpfile).dylib"))
        if interposed.count != 0 {
            for symname in interposed {
                detail("Interposed "+describeImageSymbol(symname))
            }
            log("Interposed \(interposed.count) function references.")
        }

        #if !targetEnvironment(simulator) && SWIFT_PACKAGE
        if let pseudoImage = lastPseudoImage() {
            onDeviceSpecificProcessing(for: pseudoImage)
        }
        #endif

        // Can prevent statics from re-initializing on injection
        reverseInterposeStaticsAddressors(tmpfile)

        // log any types being injected
        var ntypes = 0, npreviews = 0
        findSwiftSymbols(searchLastLoaded(), "N") {
            (typePtr, symbol, _, _) in
            if let existing: Any.Type =
                autoBitCast(dlsym(SwiftMeta.RTLD_DEFAULT, symbol)) {
                let name = _typeName(existing)
                if name.hasSuffix("_Previews") {
                    npreviews += 1
                }
                ntypes += 1
                log("Injected type #\(ntypes) '\(name)'")
                if lastPseudoImage() != nil {
                    SwiftMeta.cloneValueWitness(from: existing, onto: autoBitCast(typePtr))
                }
                let newSize = SwiftMeta.sizeof(anyType: autoBitCast(typePtr))
                if newSize != 0 && newSize != SwiftMeta.sizeof(anyType: existing) {
                    log("⚠️ Size of value type \(_typeName(existing)) has changed (\(newSize) != \(SwiftMeta.sizeof(anyType: existing))). You cannot inject changes to memory layout. This will likely just crash. ⚠️")
                }
            }
        }

        if false && npreviews > 0 && ntypes > 2 && lastPseudoImage() != nil {
            log("⚠️ Device injection may fail if you have more than one type from the injected file referred to in a SwiftUI View.")
        }

        if getenv(INJECTION_DYNAMIC_CAST) != nil {
            // Cater for dynamic cast (i.e. as?) to types that have been injected.
            DynamicCast.hook_lastInjected()
        }

        var reducers = [SymbolName]()
        if !injectableReducerSymbols.isEmpty {
            reinitializeInjectedReducers(tmpfile, reinitialized: &reducers)
            let s = reducers.count == 1 ? "" : "s"
            log("Overrode \(reducers.count) reducer"+s)
        }

        return interposed.count + reducers.count
    }

    #if true // Original version of vtable patch, headed for retirement..
    /// Patch entries in vtable of existing class to be that in newly loaded version of class for non-final methods
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
        var patched = 0

        #if true // supplimented by "interpose" code
        // vtable still needs to be patched though for non-final methods
        func byteAddr<T>(_ location: UnsafeMutablePointer<T>) -> UnsafeMutablePointer<UInt8> {
            return location.withMemoryRebound(to: UInt8.self, capacity: 1) { $0 }
        }

        let vtableOffset = byteAddr(&existingClass.pointee.IVarDestroyer) - byteAddr(existingClass)

        #if false
        // Old mechanism for Swift equivalent of "Swizzling".
        if classMetadata.pointee.ClassSize != existingClass.pointee.ClassSize {
            log("⚠️ Adding or [re]moving methods on non-final classes is not supported. Your application will likely crash. ⚠️")
        }

        // original injection implementaion for Swift.
        let vtableLength = Int(existingClass.pointee.ClassSize -
            existingClass.pointee.ClassAddressPoint) - vtableOffset

        memcpy(byteAddr(existingClass) + vtableOffset,
               byteAddr(classMetadata) + vtableOffset, vtableLength)
        #else
        // new version only copying only symbols that are functions.
        let newTable = (byteAddr(classMetadata) + vtableOffset)
            .withMemoryRebound(to: SwiftTrace.SIMP?.self, capacity: 1) { $0 }

        SwiftTrace.iterateMethods(ofClass: oldClass) {
            (name, slotIndex, vtableSlot, stop) in
            if let replacement = SwiftTrace.interposed(replacee:
                autoBitCast(newTable[slotIndex] ?? vtableSlot.pointee)),
                autoBitCast(vtableSlot.pointee) != replacement {
                traceAndReplace(vtableSlot.pointee,
                    replacement: replacement, name: name) {
                    (replacement: UnsafeMutableRawPointer) -> String? in
                    vtableSlot.pointee = autoBitCast(replacement)
                    if autoBitCast(vtableSlot.pointee) == replacement { ////
                        patched += 1
                        return newTable[slotIndex] != nil ? "Patched" : "Populated"
                    }
                    return nil
                }
            }
        }
        #endif
        #endif
        return patched
    }
    #endif

    /// Newer way to patch vtable looking up existing entries individually in newly loaded dylib.
    open class func newPatchSwiftVtable(oldClass: AnyClass,// newClass: AnyClass?,
                                        tmpfile: String) -> Int {
        var patched = 0

        SwiftTrace.forEachVTableEntry(ofClass: oldClass) {
            (symname, slotIndex, vtableSlot, stop) in
            let existing: UnsafeMutableRawPointer = autoBitCast(vtableSlot.pointee)
            guard let replacement = fast_dlsym(lastLoadedImage(), symname) ??
                    (dlsym(SwiftMeta.RTLD_DEFAULT, symname) ??
                     findSwiftSymbol(searchBundleImages(), symname, .any)).flatMap({
                    autoBitCast(SwiftTrace.interposed(replacee: $0)) }) else {
                log("⚠️ Class patching failed to lookup " +
                    describeImageSymbol(symname))
                return
            }
            if replacement != existing {
                traceAndReplace(existing, replacement: replacement, symname: symname) {
                    (replacement: UnsafeMutableRawPointer) -> String? in
                    vtableSlot.pointee = autoBitCast(replacement)
                    if autoBitCast(vtableSlot.pointee) == replacement {
                        patched += 1
                        return "Patched"
                    }
                    return nil
                }
            }
        }

        return patched
    }

    /// Pop a trace on a newly injected method and convert the pointer type while you're at it
    open class func traceInjected<IN>(replacement: IN, name: String? = nil,
                                     symname: UnsafePointer<Int8>? = nil,
                     objcMethod: Method? = nil, objcClass: AnyClass? = nil)
        -> UnsafeRawPointer {
        if traceInjection || SwiftTrace.isTracing,
           let name = name ??
                symname.flatMap({ SwiftMeta.demangle(symbol: $0) }) ??
                objcMethod.flatMap({ NSStringFromSelector(method_getName($0)) }),
           !name.contains(".unsafeMutableAddressor :"),
           let tracer = SwiftTrace.trace(name: injectedPrefix + name,
                   objcMethod: objcMethod, objcClass: objcClass,
                   original: autoBitCast(replacement)) {
            return autoBitCast(tracer)
        }
        return autoBitCast(replacement)
    }

    /// All implementation replacements go through this function which can also apply a trace
    /// - Parameters:
    ///   - existing: implementation being replaced
    ///   - replacement: new implementation
    ///   - name: demangled symbol for trace
    ///   - symname: raw symbol nme
    ///   - objcMethod: used for trace
    ///   - objcClass: used for trace
    ///   - apply: closure to apply replacement
    open class func traceAndReplace<E,O>(_ existing: E,
                                         replacement: UnsafeRawPointer,
            name: String? = nil, symname: UnsafePointer<Int8>? = nil,
            objcMethod: Method? = nil, objcClass: AnyClass? = nil,
            apply: (O) -> String?) {
        let traced = traceInjected(replacement: replacement, name: name,
           symname: symname, objcMethod: objcMethod, objcClass: objcClass)

        // injecting getters returning generics best avoided for some reason.
        if let getted = name?[safe: .last(of: ".getter : ", end: true)...] {
            if getted.hasSuffix(">") { return }
            if let type = SwiftMeta.lookupType(named: getted),
               inheritedGeneric(anyType: type) {
                return
            }
        }
        if let success = apply(autoBitCast(traced)) {
            detail("\(success) \(autoBitCast(existing) as UnsafeRawPointer) -> \(replacement) " +    describeImagePointer(replacement))
        }
    }

    /// Resolve a perhaps traced function back to name of original symbol
    open class func originalSym(for existing: UnsafeMutableRawPointer) -> SymbolName? {
        var info = Dl_info()
        if fast_dladdr(existing, &info) != 0 {
            return info.dli_sname
        } else if let swizzle = SwiftTrace.originalSwizzle(for: autoBitCast(existing)),
                  fast_dladdr(autoBitCast(swizzle.implementation), &info) != 0 {
            return info.dli_sname
        }
        return nil
    }

    /// If class is a generic, patch its specialised vtable and basic selectors
    open class func patchGenerics(oldClass: AnyClass, tmpfile: String,
                                  injectedGenerics: Set<String>,
                                  patched: inout Set<UnsafeRawPointer>) -> Bool {
        if let genericClassName = _typeName(oldClass)[safe: ..<(.first(of: "<"))],
           injectedGenerics.contains(genericClassName) {
            if patched.insert(autoBitCast(oldClass)).inserted {
                let patched = newPatchSwiftVtable(oldClass: oldClass, tmpfile: tmpfile)
                let swizzled = swizzleBasics(oldClass: oldClass, tmpfile: tmpfile)
                log("Injected generic '\(oldClass)' (\(patched),\(swizzled))")
            }
            return oldClass.instancesRespond(to: injectedSEL)
        }
        return false
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
        for suffix in SwiftTrace.traceableFunctionSuffixes {
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
        SwiftTrace.forAllClasses(bundlePath: searchLastLoaded()) {
            aClass, stop in
            classes.append(aClass)
        }
        if classes.count > 0 {
            print("\(APP_PREFIX)Loaded .dylib - Ignore any duplicate class warning ⬆️")
        }
        #if false // Just too dubious
        // Determine any generic classes being injected.
        // (Done as part of sweep in the end.)
        findSwiftSymbols(searchLastLoaded(), "CMa") {
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
