//
//  DeviceInjection.swift
//
//  Created by John Holdsworth on 17/03/2022.
//  Copyright © 2022 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/DeviceInjection.swift#13 $
//
//  Code specific to injecting on an actual device.
//

#if !targetEnvironment(simulator)
import SwiftTrace
#if SWIFT_PACKAGE
import SwiftTraceGuts
import HotReloadingGuts
#endif

extension SwiftInjection {

    /// Emulate remaining functions of the dynamic linker.
    /// - Parameter pseudoImage: last image read into memory
    public class func onDeviceSpecificProcessing(
        for pseudoImage: UnsafePointer<mach_header>, _ sweepClasses: [AnyClass]) {
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
        // Fixup references to Objective-C classes
        fixupObjcClassReferences(in: pseudoImage)
        // Attempt to fix up messages to super
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

    /// Fixup references to Objective-C classes on device
    public class func fixupObjcClassReferences(
        in pseudoImage: UnsafePointer<mach_header>) {
        var typeref_size: UInt64 = 0
        if let classNames = objcClassRefs as? [String], classNames.first != "",
           let classRefsSection: UnsafeMutablePointer<AnyClass?> = autoBitCast(
                getsectdatafromheader_64(autoBitCast(pseudoImage),
                    SEG_DATA, "__objc_classrefs", &typeref_size)) {
            let nClassRefs = Int(typeref_size)/MemoryLayout<AnyClass>.size
            let classes = classNames.compactMap {
                return dlsym(SwiftMeta.RTLD_DEFAULT, "OBJC_CLASS_$_"+$0)
            }
            if nClassRefs == classes.count {
                for i in 0 ..< nClassRefs {
                    classRefsSection[i] = autoBitCast(classes[i])
                }
            } else {
                log("⚠️ Number of class refs \(nClassRefs) does not equal \(classNames)")
            }
        }
    }

    /// Populate "l_got.*" external references to "descriptors"
    /// - Parameter pseudoImage: lastLoadedImage
    public class func bindDescriptorReferences(
        in pseudoImage: UnsafePointer<mach_header>) {
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
