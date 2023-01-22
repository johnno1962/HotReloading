//
//  ObjcInjection.swift
//
//  Created by John Holdsworth on 17/03/2022.
//  Copyright © 2022 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/ObjcInjection.swift#19 $
//
//  Code specific to "classic" Objective-C method swizzling.
//

import Foundation
import SwiftTrace
#if SWIFT_PACKAGE
import SwiftTraceGuts
#endif

extension SwiftInjection {

    /// New method of swizzling based on symbol names
    /// - Parameters:
    ///   - oldClass: original class to be swizzled
    ///   - tmpfile: no longer used
    /// - Returns: # methods swizzled
    public class func injection(swizzle oldClass: AnyClass, tmpfile: String) -> Int {
        var methodCount: UInt32 = 0, swizzled = 0
        if let methods = class_copyMethodList(oldClass, &methodCount) {
            for i in 0 ..< Int(methodCount) {
                swizzled += swizzle(oldClass: oldClass,
                    selector: method_getName(methods[i]), tmpfile)
            }
            free(methods)
        }
        return swizzled
    }

    /// Swizzle the newly loaded implementation of a selector onto oldClass
    /// - Parameters:
    ///   - oldClass: orignal class to be swizzled
    ///   - selector: method selector to be swizzled
    ///   - tmpfile: no longer used
    /// - Returns: # methods swizzled
    public class func swizzle(oldClass: AnyClass, selector: Selector,
                              _ tmpfile: String) -> Int {
        var swizzled = 0
        if let method = class_getInstanceMethod(oldClass, selector),
            let existing = unsafeBitCast(method_getImplementation(method),
                                         to: UnsafeMutableRawPointer?.self),
            let selsym = originalSym(for: existing) {
            if let replacement = fast_dlsym(lastLoadedImage(), selsym) {
                traceAndReplace(existing, replacement: replacement,
                                objcMethod: method, objcClass: oldClass) {
                    (replacement: IMP) -> String? in
                    if class_replaceMethod(oldClass, selector, replacement,
                                           method_getTypeEncoding(method)) != nil {
                        swizzled += 1
                        return "Swizzled"
                    }
                    return nil
                }
            } else {
                detail("⚠️ Swizzle failed "+describeImageSymbol(selsym))
            }
        }
        return swizzled
    }

    /// Fallback to make sure at least the @objc func injected() and viewDidLoad() methods are swizzled
    public class func swizzleBasics(oldClass: AnyClass, tmpfile: String) -> Int {
        var swizzled = swizzle(oldClass: oldClass, selector: injectedSEL, tmpfile)
        #if os(iOS) || os(tvOS)
        swizzled += swizzle(oldClass: oldClass, selector: viewDidLoadSEL, tmpfile)
        #endif
        return swizzled
    }

    /// Original Objective-C swizzling
    /// - Parameters:
    ///   - oldClass: Original class to be swizzle
    ///   - newClass: Newly loaded class
    /// - Returns: # of methods swizzled
    public class func injection(swizzle oldClass: AnyClass?,
                                from newClass: AnyClass?) -> Int {
        var methodCount: UInt32 = 0, swizzled = 0
        if let methods = class_copyMethodList(newClass, &methodCount) {
            for i in 0 ..< Int(methodCount) {
                let selector = method_getName(methods[i])
                let replacement = method_getImplementation(methods[i])
                guard let method = class_getInstanceMethod(oldClass, selector) ??
                                    class_getInstanceMethod(newClass, selector),
                      let existing = i < 0 ? nil : method_getImplementation(method) else {
                    continue
                }
                traceAndReplace(existing, replacement: autoBitCast(replacement),
                                objcMethod: methods[i], objcClass: newClass) {
                    (replacement: IMP) -> String? in
                    if class_replaceMethod(oldClass, selector, replacement,
                        method_getTypeEncoding(methods[i])) != replacement {
                        swizzled += 1
                        return "Swizzled"
                    }
                    return nil
                }
            }
            free(methods)
        }
        return swizzled
    }
}
