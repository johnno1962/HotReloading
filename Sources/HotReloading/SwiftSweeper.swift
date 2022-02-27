//
//  SwiftSweeper.swift
//
//  Created by John Holdsworth on 15/04/2021.
//
//  The implementation of the memeory sweep to search for
//  instance of classes that have been injected in order
//  to be able to send them the @objc injected message.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/SwiftSweeper.swift#7 $
//

import Foundation
#if SWIFT_PACKAGE
import HotReloadingGuts
#endif

private let debugSweep = getenv("INJECTION_SWEEP_DETAIL") != nil
private let sweepExclusions = { () -> NSRegularExpression? in
    if let exclusions = getenv("INJECTION_SWEEP_EXCLUDE") {
        let pattern = String(cString: exclusions)
        do {
            let filter = try NSRegularExpression(pattern: pattern, options: [])
            print(APP_PREFIX+"⚠️ Excluding types matching '\(pattern)' from sweep")
            return filter
        } catch {
            print(APP_PREFIX+"⚠️ Invalid sweep filter pattern \(error): \(pattern)")
        }
    }
    return nil
}()

@objc public protocol SwiftInjected {
    @objc optional func injected()
}

class SwiftSweeper: NSObject {

    static var current: SwiftSweeper?

    let instanceTask: (AnyObject) -> Void
    var seen = [UnsafeRawPointer: Bool]()

    init(instanceTask: @escaping (AnyObject) -> Void) {
        self.instanceTask = instanceTask
        super.init()
        SwiftSweeper.current = self
    }

    func sweepValue(_ value: Any, _ containsType: Bool = false) {
        /// Skip values that cannot be cast into `AnyObject` because they end up being `nil`
        /// Fixes a potential crash that the value is not accessible during injection.
//        print(value)
        guard !containsType && value as? AnyObject != nil else { return }

        let mirror = Mirror(reflecting: value)
        if var style = mirror.displayStyle {
            if _typeName(mirror.subjectType).hasPrefix("Swift.ImplicitlyUnwrappedOptional<") {
                style = .optional
            }
            switch style {
            case .set, .collection:
                let containsType = _typeName(type(of: value)).contains(".Type")
                if debugSweep {
                    print("Sweeping collection:", _typeName(type(of: value)))
                }
                for (_, child) in mirror.children {
                    sweepValue(child, containsType)
                }
                return
            case .dictionary:
                for (_, child) in mirror.children {
                    for (_, element) in Mirror(reflecting: child).children {
                        sweepValue(element)
                    }
                }
                return
            case .class:
                sweepInstance(value as AnyObject)
                return
            case .optional, .enum:
                if let evals = mirror.children.first?.value {
                    sweepValue(evals)
                }
            case .tuple, .struct:
                sweepMembers(value)
            @unknown default:
                break
            }
        }
    }

    func sweepInstance(_ instance: AnyObject) {
        let reference = unsafeBitCast(instance, to: UnsafeRawPointer.self)
        if seen[reference] == nil {
            seen[reference] = true
            if let filter = sweepExclusions {
                let typeName = _typeName(type(of: instance))
                if filter.firstMatch(in: typeName,
                    range: NSMakeRange(0, typeName.utf16.count)) != nil {
                    return
                }
            }

            if debugSweep {
                print("Sweeping instance \(reference) of class \(type(of: instance))")
            }

            instanceTask(instance)

            sweepMembers(instance)
            instance.legacySwiftSweep?()
        }
    }

    func sweepMembers(_ instance: Any) {
        var mirror: Mirror? = Mirror(reflecting: instance)
        while mirror != nil {
            for (name, value) in mirror!.children
                where name?.hasSuffix("Type") != true {
                sweepValue(value)
            }
            mirror = mirror!.superclassMirror
        }
    }
}

extension NSObject {
    @objc func legacySwiftSweep() {
        var icnt: UInt32 = 0, cls: AnyClass? = object_getClass(self)
        while cls != nil && cls != NSObject.self && cls != NSURL.self {
            let className = NSStringFromClass(cls!)
            if className.hasPrefix("_") || className.hasPrefix("WK") ||
                className.hasPrefix("NS") && className != "NSWindow" {
                return
            }
            if let ivars = class_copyIvarList(cls, &icnt) {
                let object = UInt8(ascii: "@")
                for i in 0 ..< Int(icnt) {
                    if /*let name = ivar_getName(ivars[i])
                        .flatMap({ String(cString: $0)}),
                       sweepExclusions?.firstMatch(in: name,
                           range: NSMakeRange(0, name.utf16.count)) == nil,*/
                       let type = ivar_getTypeEncoding(ivars[i]), type[0] == object {
                        (unsafeBitCast(self, to: UnsafePointer<Int8>.self) + ivar_getOffset(ivars[i]))
                            .withMemoryRebound(to: AnyObject?.self, capacity: 1) {
//                                print("\($0.pointee) \(self) \(name):  \(String(cString: type))")
                                if let obj = $0.pointee {
                                    SwiftSweeper.current?.sweepInstance(obj)
                                }
                        }
                    }
                }
                free(ivars)
            }
            cls = class_getSuperclass(cls)
        }
    }
}

extension NSSet {
    @objc override func legacySwiftSweep() {
        self.forEach { SwiftSweeper.current?.sweepInstance($0 as AnyObject) }
    }
}

extension NSArray {
    @objc override func legacySwiftSweep() {
        self.forEach { SwiftSweeper.current?.sweepInstance($0 as AnyObject) }
    }
}

extension NSDictionary {
    @objc override func legacySwiftSweep() {
        self.allValues.forEach { SwiftSweeper.current?.sweepInstance($0 as AnyObject) }
    }
}
