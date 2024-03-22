//
//  SwiftKeyPath.swift
//
//  Created by John Holdsworth on 20/03/2024.
//  Copyright © 2024 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/SwiftKeyPath.swift#18 $
//

import Foundation
import SwiftTrace
#if SWIFT_PACKAGE
import SwiftTraceGuts
import HotReloadingGuts
#endif

var keyPaths = [String: UnsafeRawPointer]()
var callIndexes = [String: Int]()
var lastInjectionNumber = 0

typealias KeyPathFunc = @convention(c) (UnsafeMutableRawPointer,
                                        UnsafeRawPointer) -> UnsafeRawPointer

let keyPathFuncName = "swift_getKeyPath"
var save_getKeyPath: KeyPathFunc!

@_cdecl("hookKeyPaths")
public func hookKeyPaths() {
    guard let original = dlsym(SwiftMeta.RTLD_DEFAULT, keyPathFuncName) else {
        print("⚠️ Could not find original symbol: \(keyPathFuncName)")
        return
    }
    guard let replacer = dlsym(SwiftMeta.RTLD_DEFAULT, "injection_getKeyPath") else {
        print("⚠️ Could not find replacement symbol: injection_getKeyPath")
        return
    }
    save_getKeyPath = autoBitCast(original)
    var keyPathRebinding = [rebinding(name: strdup(keyPathFuncName),
                                      replacement: replacer, replaced: nil)]
    SwiftInjection.initialRebindings += keyPathRebinding
    _ = SwiftTrace.apply(rebindings: &keyPathRebinding)
}

@_cdecl("injection_getKeyPath")
public func injection_getKeyPath(pattern: UnsafeMutableRawPointer,
                                 arguments: UnsafeRawPointer) -> UnsafeRawPointer {
    if lastInjectionNumber != SwiftEval.instance.injectionNumber {
        lastInjectionNumber = SwiftEval.instance.injectionNumber
        callIndexes.removeAll()
    }
    var info = Dl_info()
    for caller in Thread.callStackReturnAddresses {
        guard dladdr(caller.pointerValue, &info) != 0,
            let callsym = SwiftMeta.demangle(symbol: info.dli_sname),
            callsym.contains("body.getter") else {
            continue
        }
        let callIndex = callIndexes[callsym, default: 0]
        callIndexes[callsym] = callIndex+1
        let callkey = callsym.replacingOccurrences(of: "<.*?>",
            with: "", options: .regularExpression)+".keyPath#\(callIndex)"
        let keyPath: UnsafeRawPointer
        if let prev = keyPaths[callkey] {
            SwiftInjection.log("Recycling", callkey)
            keyPath = prev
        } else {
            keyPath = save_getKeyPath(pattern, arguments)
            keyPaths[callkey] = keyPath
        }
        _ = Unmanaged<AnyKeyPath>.fromOpaque(keyPath).retain()
        return keyPath
    }
    return save_getKeyPath(pattern, arguments)
}
