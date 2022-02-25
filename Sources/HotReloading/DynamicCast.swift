//
//  DynamicCast.swift
//  InjectionIII
//
//  Created by John Holdsworth on 02/24/2021.
//  Copyright © 2021 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/DynamicCast.swift#7 $
//
//  Dynamic casting in an "as?" expression to a type that has been injected.
//

import Foundation
import SwiftTrace
#if SWIFT_PACKAGE
import SwiftTraceGuts
import DLKit
#endif

public func injection_dynamicCast(inp: UnsafeRawPointer,
    out: UnsafeMutablePointer<UnsafeRawPointer>,
    from: Any.Type, to: Any.Type, size: size_t) -> Bool {
    let toName = _typeName(to)
//    print("HERE \(inp) \(out) \(_typeName(from)) \(toName) \(size)")
    let to = toName.hasPrefix("__C.") ? to :
        SwiftMeta.lookupType(named: toName, protocols: true) ?? to
    return DynamicCast.dynamicCast.original?(inp, out,
        autoBitCast(from), autoBitCast(to), size) ?? false
}

class DynamicCast {

    struct Hooking<SIGNATURE> {
        let export: String
        let symbol: UnsafeMutablePointer<CChar>
        let original: SIGNATURE?
        init(runtime: String) {
            export = runtime
            symbol = strdup("swift_"+export)!
            original = autoBitCast(dlsym(SwiftMeta.RTLD_DEFAULT, symbol))
        }
        var rebinder: rebinding {
            return rebinding(name: symbol,
                             replacement: hookingFunc(named: export),
                             replaced: nil)
        }
    }

    static let module = "_$s"+SwiftMeta.mangle(
        _typeName(DynamicCast.self).components(separatedBy: ".")[0])

    open class func hookingFunc(named: String) -> UnsafeMutableRawPointer {
        let prefix = module+SwiftMeta.mangle("injection_"+named)
        return findSwiftSymbol(searchBundleImages(), prefix, .any)!
    }

    public static func retype<OUT>(ptr: UnsafeRawPointer,
                                   out: UnsafeMutablePointer<OUT>) {
        out.pointee = ptr.assumingMemoryBound(to: OUT.self).pointee
    }

    static let dynamicCast = Hooking<@convention(c)
        (_ inp: UnsafeRawPointer,
         _ out: UnsafeMutablePointer<UnsafeRawPointer>,
         _ from: UnsafeRawPointer, _ to: UnsafeRawPointer,
         _ size: size_t) -> Bool>(runtime: "dynamicCast")

    static var rebinds =  [dynamicCast.rebinder,
//                           getTypeByMangledNameInContext.rebinder,
//                           getAssociatedTypeWitness.rebinder
                           ]

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
//        if let swiftUI = DLKit.imageMap["SwiftUI"] {
//            rebind_symbols_image(
//                UnsafeMutableRawPointer(mutating: swiftUI.imageNumber.imageHeader),
//                swiftUI.imageNumber.imageSlide,
//                &rebinds, rebinds.count)
//
//        }
    }
}

#if false // Used during debugging on-device injection.
public func injection_getTypeByMangledNameInContext(name: UnsafePointer<CChar>,
    len: size_t, ctx: UnsafeRawPointer, args: UnsafeRawPointer) -> UnsafeRawPointer? {
    var info = Dl_info()
    fast_dladdr(name, &info)
    let data = NSMutableData(bytes: name, length: len)
    data.append(Data(repeating: 0, count: 1))
    var type = DynamicCast.getTypeByMangledNameInContext
        .original?(name, len, ctx, args)
    var anyt: Any.Type?
    DynamicCast.retype(ptr: &type, out: &anyt)
    print("injection_getTypeByMangledNameInContext", len,
          String(cString: info.dli_sname), _typeName(anyt!),
          String(cString: data.bytes.assumingMemoryBound(to: CChar.self)),
          data.debugDescription)
    return type
}

public func injection_getAssociatedTypeWitness(req: UnsafeRawPointer,
    witness: UnsafeRawPointer, conforming: UnsafeRawPointer,
    reqBase: UnsafeRawPointer, assoc: UnsafeRawPointer) -> UnsafeRawPointer? {
    print("injection_getAssociatedTypeWitness",
          req, witness, conforming, reqBase, assoc)
    return DynamicCast.getAssociatedTypeWitness
        .original?(req, witness, conforming, reqBase, assoc)
}

extension DynamicCast {

    static let getTypeByMangledNameInContext = Hooking<@convention(c)
        (_ name: UnsafePointer<CChar>, _ len: size_t,
         _ ctx: UnsafeRawPointer, _ args: UnsafeRawPointer) -> UnsafeRawPointer?
    >(runtime: "getTypeByMangledNameInContext")
    static let getAssociatedTypeWitness = Hooking<@convention(c)
        (_ req: UnsafeRawPointer, _ witness: UnsafeRawPointer,
         _ conforming: UnsafeRawPointer, _ reqBase: UnsafeRawPointer,
         _ assoc: UnsafeRawPointer) -> UnsafeRawPointer?
    >(runtime: "getAssociatedTypeWitness")
}
#endif
