//
//  SwiftInterpose.swift
//
//  Created by John Holdsworth on 25/04/2022.
//
//  Interpose processing (-Xlinker -interposable).
//
//  $Id: //depot/HotReloading/Sources/HotReloading/SwiftInterpose.swift#8 $
//

#if DEBUG || !SWIFT_PACKAGE
import Foundation
import SwiftTrace
#if SWIFT_PACKAGE
import SwiftTraceGuts
#endif

extension SwiftInjection {

    static var initialRebindings = [rebinding]()

    /// "Interpose" all function definitions in a dylib onto the main executable
    public class func interpose(functionsIn dylib: String) -> [UnsafePointer<Int8>] {
        var symbols = [UnsafePointer<Int8>]()

        #if false // DLKit based interposing
        // ... doesn't play well with tracing.
        var replacements = [UnsafeMutableRawPointer]()

        // Find all definitions of Swift functions and ...
        // SwiftUI body properties defined in the new dylib.

        for (symbol, value, _) in DLKit.lastImage
            .swiftSymbols(withSuffixes: injectableSuffixes) {
            guard var replacement = value else {
                continue
            }
            let method = symbol.demangled ?? String(cString: symbol)
            if detail {
                log("Replacing \(method)")
            }

            if traceInjection || SwiftTrace.isTracing, let tracer = SwiftTrace
                .trace(name: injectedPrefix+method, original: replacement) {
                replacement = autoBitCast(tracer)
            }

            symbols.append(symbol)
            replacements.append(replacement)
        }

        // Rebind all references in all images in the app bundle
        // to function symbols defined in the last loaded dylib
        // to the new implementations in the newly loaded dylib.
        DLKit.appImages[symbols] = replacements

        #else // Current SwiftTrace based code...
        let main = dlopen(nil, RTLD_NOW)
        var interposes = [dyld_interpose_tuple]()

        #if false
        let suffixesToInterpose = SwiftTrace.traceableFunctionSuffixes
            // Oh alright, interpose all property getters..
            .map { $0 == "Qrvg" ? "g" : $0 }
            // and class/static members
            .flatMap { [$0, $0+"Z"] }
        for suffix in suffixesToInterpose {
            findSwiftSymbols(dylib, suffix) { (loadedFunc, symbol, _, _) in
                // interposing was here ...
            }
        }
        #endif
        filterImageSymbols(ST_LAST_IMAGE, .any, SwiftTrace.injectableSymbol) {
            (loadedFunc, symbol, _, _) in
            guard let existing = dlsym(main, symbol) ??
                    findSwiftSymbol(searchBundleImages(), symbol, .any),
                  existing != loadedFunc/*,
                let current = SwiftTrace.interposed(replacee: existing)*/ else {
                return
            }
            let current = existing
            traceAndReplace(current, replacement: loadedFunc, symname: symbol) {
                (replacement: UnsafeMutableRawPointer) -> String? in
                interposes.append(dyld_interpose_tuple(replacement: replacement,
                                                       replacee: current))
                symbols.append(symbol)
                return nil //"Interposing"
            }
            #if ORIGINAL_2_2_0_CODE
            SwiftTrace.interposed[existing] = loadedFunc
            SwiftTrace.interposed[current] = loadedFunc
            #endif
        }

        #if !ORIGINAL_2_2_0_CODE
        //// if interposes.count == 0 { return [] }
        var rebindings = SwiftTrace.record(interposes: interposes, symbols: symbols)
        return SwiftTrace.apply(rebindings: &rebindings,
            onInjection: { (header, slide) in
            var info = Dl_info()
            // Need to apply previous interposes
            // to the newly loaded dylib as well.
            var previous = initialRebindings
            var already = Set<UnsafeRawPointer>()
            let interposed = NSObject.swiftTraceInterposed.bindMemory(to:
                [UnsafeRawPointer : UnsafeRawPointer].self, capacity: 1)
            for (replacee, _) in interposed.pointee {
                if let replacement = SwiftTrace.interposed(replacee: replacee),
                   already.insert(replacement).inserted,
                   dladdr(replacee, &info) != 0, let symname = info.dli_sname {
                    previous.append(rebinding(name: symname, replacement:
                        UnsafeMutableRawPointer(mutating: replacement),
                                              replaced: nil))
                }
            }
            rebind_symbols_image(UnsafeMutableRawPointer(mutating: header),
                                 slide, &previous, previous.count)
        })
        #else // ORIGINAL_2_2_0_CODE replaced by fishhook now
        // Using array of new interpose structs
        interposes.withUnsafeBufferPointer { interps in
            var mostRecentlyLoaded = true

            // Apply interposes to all images in the app bundle
            // as well as the most recently loaded "new" dylib.
            appBundleImages { image, header in
                if mostRecentlyLoaded {
                    // Need to apply all previous interposes
                    // to the newly loaded dylib as well.
                    var previous = Array<dyld_interpose_tuple>()
                    for (replacee, replacement) in SwiftTrace.interposed {
                        previous.append(dyld_interpose_tuple(
                                replacement: replacement, replacee: replacee))
                    }
                    previous.withUnsafeBufferPointer {
                        interps in
                        dyld_dynamic_interpose(header,
                                           interps.baseAddress!, interps.count)
                    }
                    mostRecentlyLoaded = false
                }
                // patch out symbols defined by new dylib.
                dyld_dynamic_interpose(header,
                                       interps.baseAddress!, interps.count)
//                print("Patched \(String(cString: image))")
            }
        }
        #endif
        #endif
    }

    /// Interpose references to witness tables, meta data and perhps static variables
    /// to those in main bundle to have them not re-initialise again on each injection.
    static func reverseInterposeStaticsAddressors(_ tmpfile: String) {
        var staticsAccessors = [rebinding]()
        var already = Set<UnsafeRawPointer>()
        var symbolSuffixes = ["Wl"] // Witness table accessors
        if false && SwiftTrace.deviceInjection {
            symbolSuffixes.append("Ma") // meta data accessors
        }
        if SwiftTrace.preserveStatics {
            symbolSuffixes.append("vau") // static variable "mutable addressors"
        }
        for suffix in symbolSuffixes {
            findHiddenSwiftSymbols(searchLastLoaded(), suffix, .any) {
                accessor, symname, _, _ in
                var original = dlsym(SwiftMeta.RTLD_MAIN_ONLY, symname)
                if original == nil {
                    original = findSwiftSymbol(searchBundleImages(), symname, .any)
                    if original != nil && !already.contains(original!) {
                        detail("Recovered top level variable with private scope " +
                               describeImagePointer(original!))
                    }
                }
                guard original != nil, already.insert(original!).inserted else {
                    return
                }
                detail("Reverse interposing \(original!) <- \(accessor) " +
                       describeImagePointer(original!))
                staticsAccessors.append(rebinding(name: symname,
                           replacement: original!, replaced: nil))
            }
        }
        let injectedImage = _dyld_image_count()-1 // last injected
        let interposed = SwiftTrace.apply(
            rebindings: &staticsAccessors, count: staticsAccessors.count,
            header: lastPseudoImage() ?? _dyld_get_image_header(injectedImage),
            slide: lastPseudoImage() != nil ? 0 :
                _dyld_get_image_vmaddr_slide(injectedImage))
        for symname in interposed {
            detail("Reverse interposed "+describeImageSymbol(symname))
        }
        if interposed.count != staticsAccessors.count && injectionDetail {
            let succeeded = Set(interposed)
            for attemped in staticsAccessors.map({ $0.name }) {
                if !succeeded.contains(attemped) {
                    log("Reverse interposing \(interposed.count)/\(staticsAccessors.count) failed for \(describeImageSymbol(attemped))")
                }
            }
        }
    }
}
#endif
