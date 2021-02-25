//
//  SwiftSwizzler.swift
//  SwiftSwizzler
//
//  Created by John Holdsworth on 06/12/2016.
//  Copyright © 2016 John Holdsworth. All rights reserved.
//

import Foundation

public struct Swizzler {

    @discardableResult
    static func scanSlots<T>(of aClass: AnyObject, block: (_ slotNumber: Int, _ slot: UnsafeMutablePointer<SIMP?>, _ demangled: String) -> T?) -> T? {

        let swiftClass = unsafeBitCast(aClass, to: UnsafeMutablePointer<ClassMetadataSwift>.self)

        if (swiftClass.pointee.Data & 0x3) == 0 {
            print("Object is not instance of Swift class")
            return nil
        }

        return withUnsafeMutablePointer(to: &swiftClass.pointee.IVarDestroyer) {
            (sym_start) -> T? in
            swiftClass.withMemoryRebound(to: Int8.self, capacity: 1) {
                let ptr = ($0 + -Int(swiftClass.pointee.ClassAddressPoint) + Int(swiftClass.pointee.ClassSize))
                return ptr.withMemoryRebound(to: Optional<SIMP>.self, capacity: 1) {
                    (sym_end) -> T? in

                    var info = Dl_info()
                    for i in 0..<(sym_end - sym_start) {
                        if let fptr = sym_start[i] {
                            let vptr = unsafeBitCast(fptr, to: UnsafeRawPointer.self)
                            if dladdr(vptr, &info) != 0 && info.dli_sname != nil {
                                let demangled = _stdlib_demangleName(String(cString: info.dli_sname))
                                if let result = block(i, sym_start+i, demangled) {
                                    return result
                                }
                            }
                        }
                    }
                    
                    return nil
                }
            }
        }
    }

    public static func dumpMethods(of aClass: AnyObject) {
        scanSlots(of: aClass) {
            (number, slot, demangled) -> Int? in
            print("\(number) \(demangled)")
            return nil
        }
    }

    static private func findMethod(aClass: AnyObject, signature: String) -> (SIMP, Int)? {
        return scanSlots(of: aClass) {
            (number, slot, demangled) -> (SIMP, Int)? in
            return demangled == signature ? (slot.pointee!, number) : nil
        }
    }

    static private func replaceMethod(aClass: AnyObject, signature: String, replacement: @escaping SIMP, target: Int) -> Swizzler? {
        return scanSlots(of: aClass) {
            (number, slot, demangled) -> Swizzler? in
            if demangled == signature {
                if number != target {
                    print("Slot mismatch \(number) != \(target)")
                }
                else if let original = slot.pointee {
                    slot.pointee = replacement
                    return Swizzler(replacement: replacement, original: original, slot: slot)
                }
            }
            return nil
        }
    }

    public static func patch(replace: String, in target: AnyClass, with: String, from donor: AnyClass) -> Swizzler? {
        if let (replacement, number) = findMethod(aClass: donor, signature: with) {
            return replaceMethod(aClass: target, signature: replace, replacement: replacement, target: number)
        }
        else {
            return nil
        }
    }

    private let replacement: SIMP
    private let original: SIMP
    private let slot: UnsafeMutablePointer<SIMP?>

    func withOriginal<T>(block: () -> T) -> T {
        slot.pointee = original
        let ret = block()
        slot.pointee = replacement
        return ret
    }

}
