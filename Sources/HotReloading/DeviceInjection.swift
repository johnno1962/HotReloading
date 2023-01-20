//
//  DeviceInjection.swift
//
//  Created by John Holdsworth on 17/03/2022.
//  Copyright © 2022 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/DeviceInjection.swift#33 $
//
//  Code specific to injecting on an actual device.
//

#if !targetEnvironment(simulator) && SWIFT_PACKAGE
import SwiftTrace
#if SWIFT_PACKAGE
import SwiftRegex
import SwiftTraceGuts
import HotReloadingGuts
#endif

extension SwiftInjection.MachImage {
    func symbols(withPrefix: UnsafePointer<CChar>,
                 apply: @escaping (UnsafeRawPointer, UnsafePointer<CChar>,
                                   UnsafePointer<CChar>) -> Void) {
        let prefixLen = strlen(withPrefix)
        fast_dlscan(self, .any, {
            return strncmp($0, withPrefix, prefixLen) == 0}) {
            (address, symname, _, _) in
            apply(address, symname, symname + prefixLen - 1)
        }
    }
}

extension SwiftInjection {

    public typealias MachImage = UnsafePointer<mach_header>

    /// Emulate remaining functions of the dynamic linker.
    /// - Parameter pseudoImage: last image read into memory
    public class func onDeviceSpecificProcessing(
        for pseudoImage: MachImage, _ sweepClasses: [AnyClass]) {
        // register types, protocols, conformances...
        var section_size: UInt64 = 0
        for (section, regsiter) in [
            ("types",  "swift_registerTypeMetadataRecords"),
            ("protos", "swift_registerProtocols"),
            ("proto",  "swift_registerProtocolConformances")] {
            if let section_start =
                getsectdatafromheader_64(autoBitCast(pseudoImage),
                     SEG_TEXT, "__swift5_"+section, &section_size),
               section_size != 0, let call: @convention(c)
                (UnsafeRawPointer, UnsafeRawPointer) -> Void =
                autoBitCast(dlsym(SwiftMeta.RTLD_DEFAULT, regsiter)) {
                call(section_start, section_start+Int(section_size))
            }
        }
        // Redirect symbolic type references to main bundle
        reverse_symbolics(pseudoImage)
        // Initialise offsets to ivars
        adjustIvarOffsets(in: pseudoImage)
        // Fixup references to Objective-C classes
        fixupObjcClassReferences(in: pseudoImage)
        // Fix Objective-C messages to super
        var supersSize: UInt64 = 0
        if let injectedClass = sweepClasses.first,
            let supersSection: UnsafeMutablePointer<AnyClass?> = autoBitCast(
                getsectdatafromheader_64(autoBitCast(pseudoImage), SEG_DATA,
                    "__objc_superrefs", &supersSize)), supersSize != 0 {
            supersSection[0] = injectedClass
        }
        // Populate "l_got.*" descriptor references
        bindDescriptorReferences(in: pseudoImage)
    }

    struct ObjcClassMetaData {
        var metaClass: AnyClass?
        var superClass: AnyClass?
        var methodCache: UnsafeMutableRawPointer
        var unknown: UnsafeRawPointer?
        var data: UnsafePointer<ObjcReadOnlyMetaData>?
    }

    public class func fillinObjcClassMetadata(in pseudoImage: MachImage) {
        let emptyCache = dlsym(SwiftMeta.RTLD_DEFAULT, "_objc_empty_cache")!

        pseudoImage.symbols(withPrefix: "_OBJC_METACLASS_$_") {
            (address, symname, suffix) in
            let metaData: UnsafeMutablePointer<ObjcClassMetaData> = autoBitCast(address)
            metaData.pointee.methodCache = emptyCache
            metaData.pointee.metaClass = object_getClass(NSObject.self)
            if let oldClass = objc_getClass(suffix) as? AnyClass,
                let superClass = class_getSuperclass(oldClass) {
                metaData.pointee.superClass = object_getClass(superClass)
            }
            detail("\(metaData.pointee)")
        }

        pseudoImage.symbols(withPrefix: "_OBJC_CLASS_$_") {
            (address, symname, suffix) in
            let metaData: UnsafeMutablePointer<ObjcClassMetaData> = autoBitCast(address)
            metaData.pointee.methodCache = emptyCache
            if let oldClass = objc_getClass(suffix) as? AnyClass {
                metaData.pointee.superClass = class_getSuperclass(oldClass)
//                if #available(iOS 12.2, *) {
//                    detail("\(metaData.pointee)")
//                    _objc_realizeClassFromSwift(autoBitCast(address), nil)//autoBitCast(cls))
//                    detail("\(metaData.pointee)")
//                } else {
//                    // Fallback on earlier versions
//                }
            }
            detail("\(metaData.pointee)")
        }
    }

    // Used to enumerate methods
    // on an "unrealised" class.
    struct ObjcMethodMetaData {
        let name: UnsafePointer<CChar>
        let type: UnsafePointer<CChar>
        let impl: IMP
    }

    struct ObjcMethodListMetaData {
        let flags: Int32, methodCount: Int32
        var firstMethod: ObjcMethodMetaData
    }

    struct ObjcReadOnlyMetaData {
        let skip: (Int32, Int32, Int32, Int32) = (0, 0, 0, 0)
        let names: (UnsafeRawPointer?, UnsafePointer<CChar>?)
        let methods: UnsafeMutablePointer<ObjcMethodListMetaData>?
    }

    public class func onDevice(swizzle oldClass: AnyClass,
                               from newClass: AnyClass) -> Int {
        var swizzled = 0
        let metaData: UnsafePointer<ObjcClassMetaData> = autoBitCast(newClass)
        if !class_isMetaClass(oldClass), // class methods...
           let metaClass = metaData.pointee.metaClass,
           let metaOldClass = object_getClass(oldClass) {
            swizzled += onDevice(swizzle: metaOldClass, from: metaClass)
        }

        let pointerMask: uintptr_t = ~3
        guard let roData: UnsafePointer<ObjcReadOnlyMetaData> =
                autoBitCast(autoBitCast(metaData.pointee.data) & pointerMask),
              let methodInfo = roData.pointee.methods else { return swizzled }

        withUnsafePointer(to: &methodInfo.pointee.firstMethod) {
            methods in
            for i in 0 ..< Int(methodInfo.pointee.methodCount) {
                let selector = sel_registerName(methods[i].name)
                let method = class_getInstanceMethod(oldClass, selector)
                let existing = method.flatMap { method_getImplementation($0) }
                traceAndReplace(existing, replacement: autoBitCast(methods[i].impl),
                                objcMethod: method, objcClass: newClass) {
                    (replacement: IMP) -> String? in
                    if class_replaceMethod(oldClass, selector, replacement,
                                           methods[i].type) != replacement {
                        swizzled += 1
                        return "Swizzled"
                    }
                    return nil
                }
            }
        }

        return swizzled
    }

    public class func adjustIvarOffsets(in pseudoImage: MachImage) {
        var ivarOffsetPtr: UnsafeMutablePointer<ptrdiff_t>!

        // Objective-C source version
        pseudoImage.symbols(withPrefix: "_OBJC_IVAR_$_") {
            (address, symname, suffix) in
            if let classname = strdup(suffix),
               var ivarname = strchr(classname, Int32(UInt8(ascii: "."))) {
               ivarname[0] = 0
               ivarname += 1

               if let oldClass = objc_getClass(classname) as? AnyClass,
                  let ivar = class_getInstanceVariable(oldClass, ivarname) {
                   ivarOffsetPtr = autoBitCast(address)
                   ivarOffsetPtr.pointee = ivar_getOffset(ivar)
               }

               free(classname)
            } else {
                log("⚠️ Could not parse ivar: \(String(cString: symname))")
            }
        }

        // Swift source version
        findHiddenSwiftSymbols(searchLastLoaded(), "Wvd", .any) {
            (address, symname, _, _) -> Void in
            if let fieldInfo = SwiftMeta.demangle(symbol: symname),
               let (classname, ivarname): (String, String) =
                fieldInfo[#"direct field offset for (\S+)\.\(?(\w+) "#],
               let oldClass = objc_getClass(classname) as? AnyClass,
               let ivar = class_getInstanceVariable(oldClass, ivarname),
               get_protection(autoBitCast(address)) & PROT_WRITE != 0 {
                ivarOffsetPtr = autoBitCast(address)
                ivarOffsetPtr.pointee = ivar_getOffset(ivar);
            } else {
                log("⚠️ Could not parse ivar: \(String(cString: symname))")
            }
        }
    }

    /// Fixup references to Objective-C classes on device
    public class func fixupObjcClassReferences(in pseudoImage: MachImage) {
        var sectionSize: UInt64 = 0
        if let classNames = objcClassRefs as? [String], classNames.first != "",
           let classRefsSection: UnsafeMutablePointer<AnyClass?> = autoBitCast(
                getsectdatafromheader_64(autoBitCast(pseudoImage),
                    SEG_DATA, "__objc_classrefs", &sectionSize)) {
            let nClassRefs = Int(sectionSize)/MemoryLayout<AnyClass>.size
            let objcClasses = classNames.compactMap {
                return dlsym(SwiftMeta.RTLD_DEFAULT, "OBJC_CLASS_$_"+$0)
            }
            if nClassRefs == objcClasses.count {
                for i in 0 ..< nClassRefs {
                    classRefsSection[i] = autoBitCast(objcClasses[i])
                }
            } else {
                log("⚠️ Number of class refs \(nClassRefs) does not equal \(classNames)")
            }
        }
    }

    /// Populate "l_got.*" external references to "descriptors"
    /// - Parameter pseudoImage: lastLoadedImage
    public class func bindDescriptorReferences(in pseudoImage: MachImage) {
        if let descriptorSyms = descriptorRefs as? [String],
            descriptorSyms.first != "" {
            var forces: UnsafeRawPointer?
            let forcePrefix = "__swift_FORCE_LOAD_$_"
            let forcePrefixLen = strlen(forcePrefix)
            fast_dlscan(pseudoImage, .any, { symname in
                return strncmp(symname, forcePrefix, forcePrefixLen) == 0
            }) { value, symname, _, _ in
                forces = value
            }

            if var descriptorRefs:
                UnsafeMutablePointer<UnsafeMutableRawPointer?> = autoBitCast(forces) {
                for descriptorSym in descriptorSyms {
                    descriptorRefs = descriptorRefs.advanced(by: 1)
                    if let value = dlsym(SwiftMeta.RTLD_DEFAULT, descriptorSym),
                       descriptorRefs.pointee == nil {
                        descriptorRefs.pointee = value
                    } else {
                        log("⚠️ Could not bind " + describeImageSymbol(descriptorSym))
                    }
                }
            } else {
                log("⚠️ Could not locate descriptors section")
            }
        }
    }
}
#endif
