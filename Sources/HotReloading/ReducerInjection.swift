//
//  ReducerInjection.swift
//
//  Created by John Holdsworth on 09/06/2022.
//  Copyright © 2022 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/ReducerInjection.swift#9 $
//
//  Support for injecting "The Composble Architecture" Reducers using TCA fork:
//  https://github.com/thebrowsercompany/swift-composable-architecture/tree/develop
//  Top level Reducer var initialisations are wrapped in ARCInjectable() call.
//  Reducers are now deprecated in favour of using the new "ReducerProtocol".
//

import Foundation
import SwiftTrace
#if SWIFT_PACKAGE
import SwiftTraceGuts
#endif

extension NSObject {

    @objc
    public func registerInjectableTCAReducer(_ symbol: String) {
        SwiftInjection.injectableReducerSymbols.insert(symbol)
    }
}

extension SwiftInjection {

    static var injectableReducerSymbols = Set<String>()
    
    static var checkReducerInitializers: Void = {
            var expectedInjectableReducerSymbols = Set<String>()

            findHiddenSwiftSymbols(searchBundleImages(), "Reducer_WZ", .any) {
                _, symname, _, _ in
                expectedInjectableReducerSymbols.insert(String(cString: symname))
            }

            for symname in expectedInjectableReducerSymbols
                .subtracting(injectableReducerSymbols) {
                let sym = SwiftMeta.demangle(symbol: symname) ?? symname
                let variable = sym.components(separatedBy: " ").last ?? sym
                log("⚠️ \(variable) is not injectable (or unused), wrap it with ARCInjectable")
            }
    }()

    /// Support for re-initialising "The Composable Architecture", "Reducer"
    /// variables declared at the top level. Requires custom version of TCA:
    /// https://github.com/thebrowsercompany/swift-composable-architecture/tree/develop
    public class func reinitializeInjectedReducers(_ tmpfile: String,
        reinitialized: UnsafeMutablePointer<[SymbolName]>) {
        _ = checkReducerInitializers
        findHiddenSwiftSymbols(searchLastLoaded(), "_WZ", .local) {
            accessor, symname, _, _ in
            if injectableReducerSymbols.contains(String(cString: symname)) {
                typealias OneTimeInitialiser = @convention(c) () -> Void
                let reinitialise: OneTimeInitialiser = autoBitCast(accessor)
                reinitialise()
                reinitialized.pointee.append(symname)
            }
        }
    }
}
