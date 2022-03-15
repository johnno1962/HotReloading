//
//  DynamicCast.swift
//  InjectionIII
//
//  Created by John Holdsworth on 02/24/2021.
//  Copyright © 2021 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/DynamicCast.swift#9 $
//
//  Dynamic casting in an "as?" expression to a type that has been injected.
//

import Foundation
import SwiftTrace
#if SWIFT_PACKAGE
import SwiftTraceGuts
#endif

public func injection_dynamicCast(inp: UnsafeRawPointer,
    out: UnsafeMutablePointer<UnsafeRawPointer>,
    from: Any.Type, to: Any.Type, size: size_t) -> Bool {
    let toName = _typeName(to)
//    print("HERE \(inp) \(out) \(_typeName(from)) \(toName) \(size)")
    let to = toName.hasPrefix("__C.") ? to :
        SwiftMeta.lookupType(named: toName, protocols: true) ?? to
    return DynamicCast.original_dynamicCast?(inp, out,
        autoBitCast(from), autoBitCast(to), size) ?? false
}

class DynamicCast {

    typealias injection_dynamicCast_t = @convention(c)
    (_ inp: UnsafeRawPointer,
     _ out: UnsafeMutablePointer<UnsafeRawPointer>,
     _ from: UnsafeRawPointer, _ to: UnsafeRawPointer,
     _ size: size_t) -> Bool

    static let swift_dynamicCast = strdup("swift_dynamicCast")!
    static let original_dynamicCast: injection_dynamicCast_t? =
        autoBitCast(dlsym(SwiftMeta.RTLD_DEFAULT, swift_dynamicCast))
    static var hooked_dynamicCast: UnsafeMutableRawPointer? = {
        let module = _typeName(DynamicCast.self)
            .components(separatedBy: ".")[0]
        return dlsym(SwiftMeta.RTLD_DEFAULT,
                     "$s\(module.count)\(module)" +
                     "21injection_dynamicCast" +
                     "3inp3out4from2to4sizeSbSV_" +
                     "SpySVGypXpypXpSitF")
    }()

    static var rebinds = original_dynamicCast != nil &&
                           hooked_dynamicCast != nil ? [
        rebinding(name: swift_dynamicCast,
                  replacement: hooked_dynamicCast!,
                  replaced: nil)] : []

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
            UnsafeMutableRawPointer(mutating: lastPseudoImage() ??
                _dyld_get_image_header(lastLoaded)),
            lastPseudoImage() != nil ? 0 :
                _dyld_get_image_vmaddr_slide(lastLoaded),
            &rebinds, rebinds.count)
    }
}
