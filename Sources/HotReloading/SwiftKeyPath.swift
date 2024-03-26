//
//  SwiftKeyPath.swift
//
//  Created by John Holdsworth on 20/03/2024.
//  Copyright © 2024 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/SwiftKeyPath.swift#24 $
//

import Foundation
import SwiftTrace
#if SWIFT_PACKAGE
import SwiftTraceGuts
import HotReloadingGuts
#endif

private struct ViewBodyKeyPaths {
    typealias KeyPathFunc = @convention(c) (UnsafeMutableRawPointer,
                                            UnsafeRawPointer) -> UnsafeRawPointer

    static let keyPathFuncName = "swift_getKeyPath"
    static var save_getKeyPath: KeyPathFunc!

    static var cache = [String: ViewBodyKeyPaths]()
    var lastOffset = 0
    var keyPathNumber = 0
    var recycled = false
    var keyPaths = [UnsafeRawPointer]()
}

@_cdecl("hookKeyPaths")
public func hookKeyPaths() {
    guard let original = dlsym(SwiftMeta.RTLD_DEFAULT, ViewBodyKeyPaths.keyPathFuncName) else {
        print("⚠️ Could not find original symbol: \(ViewBodyKeyPaths.keyPathFuncName)")
        return
    }
    guard let replacer = dlsym(SwiftMeta.RTLD_DEFAULT, "injection_getKeyPath") else {
        print("⚠️ Could not find replacement symbol: injection_getKeyPath")
        return
    }
    ViewBodyKeyPaths.save_getKeyPath = autoBitCast(original)
    var keyPathRebinding = [rebinding(name: strdup(ViewBodyKeyPaths.keyPathFuncName),
                                      replacement: replacer, replaced: nil)]
    SwiftInjection.initialRebindings += keyPathRebinding
    _ = SwiftTrace.apply(rebindings: &keyPathRebinding)
}

@_cdecl("injection_getKeyPath")
public func injection_getKeyPath(pattern: UnsafeMutableRawPointer,
                                 arguments: UnsafeRawPointer) -> UnsafeRawPointer {
    var info = Dl_info()
    for caller in Thread.callStackReturnAddresses.dropFirst() {
        guard let caller = caller.pointerValue,
              dladdr(caller, &info) != 0, let symbol = info.dli_sname,
              let callsym = SwiftMeta.demangle(symbol: symbol) else {
            continue
        }
//        print(callsym)
        if !callsym.hasSuffix(".body.getter : some") {
            break
        }
        let callBase = callsym.replacingOccurrences(of: "<.*?>",
            with: "<>", options: .regularExpression) + ".keyPath#"
        var body = ViewBodyKeyPaths.cache[callBase] ?? ViewBodyKeyPaths()
        let offset = caller-info.dli_saddr
        if offset <= body.lastOffset {
            body.keyPathNumber = 0
            body.recycled = false
        }
        body.lastOffset = offset
//        print(offset, callIndex)
        if body.keyPathNumber < body.keyPaths.count {
            SwiftInjection.detail("Recycling \(callBase)\(body.keyPathNumber)")
            body.recycled = true
        } else {
            body.keyPaths.append(ViewBodyKeyPaths.save_getKeyPath(pattern, arguments))
            if body.recycled {
                SwiftInjection.log("""
                    ⚠️ New key path expression introduced over injection. \
                    This will likely fail and you'll have to restart your \
                    application.
                    """)
            }
        }
        let keyPath = body.keyPaths[body.keyPathNumber]
        body.keyPathNumber += 1
        ViewBodyKeyPaths.cache[callBase] = body
        _ = Unmanaged<AnyKeyPath>.fromOpaque(keyPath).retain()
        return keyPath
    }
    return ViewBodyKeyPaths.save_getKeyPath(pattern, arguments)
}
