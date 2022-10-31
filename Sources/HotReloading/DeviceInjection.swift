//
//  DeviceInjection.swift
//
//  Created by John Holdsworth on 17/03/2022.
//  Copyright © 2022 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/DeviceInjection.swift#9 $
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
        for pseudoImage: UnsafePointer<mach_header>) {
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
        // Populate "l_got.*" descriptor references
        bindDescriptorReferences(in: pseudoImage)
    }

    /// Fixup references to Objective-C classes on device
    public class func fixupObjcClassReferences(
        in pseudoImage: UnsafePointer<mach_header>) {
        var typeref_size: UInt64 = 0
        if var refs = objcClassRefs as? [String], refs.first != "",
           let typeref_start = getsectdatafromheader_64(autoBitCast(pseudoImage),
                                    SEG_DATA, "__objc_classrefs", &typeref_size) {
            let classRefPtr:
                UnsafeMutablePointer<AnyClass?> = autoBitCast(typeref_start)
            let nClassRefs = Int(typeref_size)/MemoryLayout<AnyClass>.size
            if nClassRefs == refs.count {
                for i in 0 ..< nClassRefs {
                    let classSymbol = "OBJC_CLASS_$_"+refs.removeFirst()
                    if let classRef = dlsym(SwiftMeta.RTLD_DEFAULT, classSymbol) {
                        classRefPtr[i] = autoBitCast(classRef)
                    } else {
                        log("⚠️ Could not lookup class reference \(classSymbol)")
                    }
                }
            } else {
                log("⚠️ Number of class refs \(nClassRefs) does not equal \(refs)")
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
