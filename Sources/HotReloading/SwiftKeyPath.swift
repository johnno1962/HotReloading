//
//  SwiftKeyPath.swift
//
//  Created by John Holdsworth on 20/03/2024.
//  Copyright © 2024 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/SwiftKeyPath.swift#34 $
//
//  Key paths weren't made to be injected as their underlying types can change.
//  This is particularly evident in code that uses "The Composable Architecture".
//  This code maintains a cache of previously allocated key paths using a unique
//  identifier of the calling site so they remain invariant over an injection.
//

#if DEBUG || !SWIFT_PACKAGE
import Foundation

private struct ViewBodyKeyPaths {
    typealias KeyPathFunc = @convention(c) (UnsafeMutableRawPointer,
                                            UnsafeRawPointer) -> UnsafeRawPointer

    static let keyPathFuncName = "swift_getKeyPath"
    static var save_getKeyPath: KeyPathFunc!

    static var cache = [String: ViewBodyKeyPaths]()
    static var lastInjectionNumber = SwiftEval().injectionNumber
    static var hasInjected = false

    var lastOffset = 0
    var keyPathNumber = 0
    var recycled = false
    var keyPaths = [UnsafeRawPointer]()
}

@_cdecl("hookKeyPaths")
public func hookKeyPaths(original: UnsafeMutableRawPointer,
                         replacer: UnsafeMutableRawPointer) {
    print(APP_PREFIX+"ℹ️ Intercepting keypaths for when their types are injected." +
        " Set an env var INJECTION_NOKEYPATHS in your scheme to prevent this.")
    ViewBodyKeyPaths.save_getKeyPath = autoBitCast(original)
    var keyPathRebinding = [rebinding(name: strdup(ViewBodyKeyPaths.keyPathFuncName),
                                      replacement: replacer, replaced: nil)]
    SwiftTrace.initialRebindings += keyPathRebinding
    _ = SwiftTrace.apply(rebindings: &keyPathRebinding)
}

@_cdecl("injection_getKeyPath")
public func injection_getKeyPath(pattern: UnsafeMutableRawPointer,
                                 arguments: UnsafeRawPointer) -> UnsafeRawPointer {
    if ViewBodyKeyPaths.lastInjectionNumber != SwiftEval.instance.injectionNumber {
        ViewBodyKeyPaths.lastInjectionNumber = SwiftEval.instance.injectionNumber
        for key in ViewBodyKeyPaths.cache.keys {
            ViewBodyKeyPaths.cache[key]?.keyPathNumber = 0
            ViewBodyKeyPaths.cache[key]?.recycled = false
        }
        ViewBodyKeyPaths.hasInjected = true
    }
    var info = Dl_info()
    for caller in Thread.callStackReturnAddresses.dropFirst() {
        guard let caller = caller.pointerValue,
              dladdr(caller, &info) != 0, let symbol = info.dli_sname,
              let callerDecl = SwiftMeta.demangle(symbol: symbol) else {
            continue
        }
        if !callerDecl.hasSuffix(".body.getter : some") {
            break
        }
        // identify caller site
        var relevant: [String] = callerDecl[#"(closure #\d+ |in \S+ : some)"#]
        if relevant.isEmpty {
            relevant = [callerDecl]
        }
        let callerKey = relevant.joined() + ".keyPath#"
//        print(callerSym, ins)
        var body = ViewBodyKeyPaths.cache[callerKey] ?? ViewBodyKeyPaths()
        // reset keyPath counter ?
        let offset = caller-info.dli_saddr
        if offset <= body.lastOffset {
            body.keyPathNumber = 0
            body.recycled = false
        }
        body.lastOffset = offset
//        print(">>", offset, body.keyPathNumber)
        // extract cached keyPath or create
        let keyPath: UnsafeRawPointer
        if body.keyPathNumber < body.keyPaths.count && ViewBodyKeyPaths.hasInjected {
            SwiftInjection.detail("Recycling \(callerKey)\(body.keyPathNumber)")
            keyPath = body.keyPaths[body.keyPathNumber]
            body.recycled = true
        } else {
            keyPath = ViewBodyKeyPaths.save_getKeyPath(pattern, arguments)
            if body.keyPaths.count == body.keyPathNumber {
                body.keyPaths.append(keyPath)
            }
            if body.recycled {
                SwiftInjection.log("""
                    ⚠️ New key path expression introduced over injection. \
                    This will likely fail and you'll have to restart your \
                    application.
                    """)
            }
        }
        body.keyPathNumber += 1
        ViewBodyKeyPaths.cache[callerKey] = body
        _ = Unmanaged<AnyKeyPath>.fromOpaque(keyPath).retain()
        return keyPath
    }
    return ViewBodyKeyPaths.save_getKeyPath(pattern, arguments)
}
#endif
