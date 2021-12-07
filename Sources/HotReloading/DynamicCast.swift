//
//  DynamicCast.swift
//  InjectionIII
//
//  Created by John Holdsworth on 02/24/2021.
//  Copyright © 2021 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/DynamicCast.swift#2 $
//
//  Code relating to injecting types in an "as?" expression.
//

import Foundation
import SwiftTrace
#if SWIFT_PACKAGE
import SwiftTraceGuts
#endif

public func injection_dynamicCast(inp: UnsafeRawPointer,
    out: UnsafeMutablePointer<UnsafeRawPointer>,
    from: Any.Type, to: Any.Type, size: size_t) -> Bool {
//    print("HERE \(inp) \(out) \(_typeName(from)) \(_typeName(to)) \(size)")
    let to = SwiftMeta.lookupType(named: _typeName(to)) ?? to
    return DynamicCast.original_dynamicCast?(inp, out,
        autoBitCast(from), autoBitCast(to), size) ?? false
}

class DynamicCast {

    typealias injection_dynamicCast_t = @convention(c)
    (_ inp: UnsafeRawPointer,
     _ out: UnsafeMutablePointer<UnsafeRawPointer>,
     _ from: UnsafeRawPointer, _ to: UnsafeRawPointer,
     _ size: size_t) -> Bool

    static var original_dynamicCast: injection_dynamicCast_t?
    static var hooked_dynamicCast: UnsafeMutableRawPointer? = {
        let module =
            _typeName(InjectionClient.self)
            .components(separatedBy: ".")[0]
        return dlsym(SwiftMeta.RTLD_DEFAULT,
                     "$s\(module.count)\(module)" +
                     "21injection_dynamicCast" +
                     "3inp3out4from2to4sizeSbSV_" +
                     "SpySVGypXpypXpSitF")
    }()

    static var rebinds = hooked_dynamicCast != nil ? [
        rebinding(name: strdup("swift_dynamicCast"),
                  replacement: hooked_dynamicCast!,
                  replaced: UnsafeMutablePointer<
                    UnsafeMutableRawPointer>(mutating:
                    &original_dynamicCast))] : []

    static var hook_appDynamicCast: Void = {
        appBundleImages { imageName, header, slide in
            rebind_symbols_image(autoBitCast(header), slide,
                                 &rebinds, rebinds.count)
        }
    }()

    static func hook_lastInjected() {
        _ = DynamicCast.hook_appDynamicCast
        let lastLoaded = _dyld_image_count()-1
        rebind_symbols_image(
            autoBitCast(_dyld_get_image_header(lastLoaded)),
            _dyld_get_image_vmaddr_slide(lastLoaded),
            &rebinds, rebinds.count)
    }
}

