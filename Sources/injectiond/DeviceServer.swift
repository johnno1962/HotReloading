//
//  DeviceServer.swift
//  InjectionIII
//  
//  Created by John Holdsworth on 13/01/2022.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/injectiond/DeviceServer.swift#15 $
//

import Foundation
#if SWIFT_PACKAGE
import HotReloadingGuts
#endif

class DeviceServer: InjectionServer {

    var scratchPointer: UnsafeMutableRawPointer?

    #if !SWIFT_PACKAGE
    override func validateConnection() -> Bool {
        return readInt() == HOTRELOADING_SALT &&
            readString()?.hasPrefix(NSHomeDirectory()) == true
    }
    #endif

    override func process(response: InjectionResponse, executable: String) {
        switch response {
        case .scratchPointer:
            scratchPointer = readPointer()
            builder.tmpDir = NSTemporaryDirectory()
            appDelegate.setMenuIcon(scratchPointer != nil ? .ok : .error)
        #if DEBUG
        case .testInjection:
            if let file = readString(), let source = readString() {
                do {
                    if file.hasPrefix("/Users/johnholdsworth/Developer/") {
                        try source.write(toFile: file, atomically: true, encoding: .utf8)
                    }
                } catch {
                    log("Error writing test source file: \(error)")
                }
            }
        #endif
        default:
            super.process(response: response, executable: executable)
        }
    }

    override func recompileAndInject(source: String) {
        appDelegate.setMenuIcon(.busy)
        if let slide = self.scratchPointer {
            if let unlock = UserDefaults.standard
                .string(forKey: UserDefaultsUnlock) {
                writeCommand(InjectionCommand.pseudoUnlock.rawValue, with: unlock)
            }
            compileQueue.async {
                self.builder.linkerOptions =
                    " -Xlinker -image_base -Xlinker 0x" +
                    String(Int(bitPattern: slide), radix: 16)
                do {
                    let dylib = try self.builder.rebuildClass(oldClass: nil,
                                          classNameOrFile: source, extra: nil)
                    if source[#"\.mm?$"#], // class references in Objective-C
                       var sourceText = try? String(contentsOfFile: source) {
                        sourceText[#"//.*|/\*[^*]+\*/"#] = "" // zap comments
                        self.objcClassRefs.removeAllObjects()
                        var seen = Set<String>()
                        for messagedClass: String
                                in sourceText[#"\[([A-Z]\w+) "#] {
                            if seen.insert(messagedClass).inserted {
                                self.objcClassRefs.add(messagedClass)
                            }
                        }
                    }
                    if let objcClasses = self.objcClassRefs as? [String],
                       let descriptors = self.descriptorRefs as? [String],
                       let data = NSData(contentsOfFile: "\(dylib).dylib") {
                        commandQueue.async {
                            self.writeCommand(InjectionCommand.objcClassRefs.rawValue,
                                              with: objcClasses.joined(separator: ","))
                            self.writeCommand(InjectionCommand.descriptorRefs.rawValue,
                                              with: descriptors.joined(separator: ","))
                            self.writeCommand(InjectionCommand.pseudoInject.rawValue,
                                              with: source)
                            self.writePointer(slide)
                            self.write(data as Data)
                        }
                        return
                    }
                } catch {
                    NSLog("\(error)")
                }
            }
        } else { // You can load a dylib on device after all...
            if !FileManager.default.fileExists(atPath: builder.tmpDir) {
                builder.tmpDir = NSTemporaryDirectory()
            }
            compileQueue.async {
                do {
                    let dylib = try self.builder.rebuildClass(oldClass: nil,
                                        classNameOrFile: source, extra: nil)
                    self.sendCommand(.setXcodeDev, with: self.builder.xcodeDev)
                    if let data = NSData(contentsOfFile: "\(dylib).dylib") {
                        commandQueue.sync {
                            self.write(InjectionCommand.copy.rawValue)
                            self.write(data as Data)
                            appDelegate.setMenuIcon(.ok)
                        }
                        return
                    } else {
                        self.sendCommand(.log, with: "\(APP_PREFIX)Error reading \(dylib).dylib")
                    }
                } catch {
                    self.sendCommand(.log, with: "\(APP_PREFIX)Build error: \(error)")
                }
                appDelegate.setMenuIcon(.error)
            }
        }
    }
}
