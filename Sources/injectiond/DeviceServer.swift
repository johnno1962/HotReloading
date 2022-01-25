//
//  DeviceServer.swift
//  InjectionIII
//  
//  Created by John Holdsworth on 13/01/2022.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/injectiond/DeviceServer.swift#2 $
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
            if scratchPointer == nil {
                let appBundle = URL(fileURLWithPath: builder.frameworks)
                    .deletingLastPathComponent()
                let appModule = appBundle.deletingPathExtension()
                    .lastPathComponent.replacingOccurrences(of: " ", with: "_")
                let appPrefix = "$s\(appModule.count)\(appModule)"
                builder.unhider = { object_file in
                    let logfile = "/tmp/unhide_object.log"
                    if let log = fopen(logfile, "w") {
                        setbuf(log, nil)
                        self.log("Unhiding: \(object_file) -- \(appPrefix)")
                        unhide_object(object_file, appPrefix, log)
                    } else {
                        self.log("Could not log to \(logfile)")
                    }
                }
                builder.tmpDir = NSTemporaryDirectory()
            }
            scratchPointer = readPointer()
            appDelegate.setMenuIcon(scratchPointer != nil ? .ok : .error)
        #if DEBUG
        case .testInjection:
            if let file = readString(), let source = readString() {
                do {
                    try source.write(toFile: file, atomically: true, encoding: .utf8)
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
        if let unlock = UserDefaults.standard
            .string(forKey: UserDefaultsUnlock) {
            writeCommand(InjectionCommand.pseudoUnlock.rawValue, with: unlock)
        }
        if let slide = self.scratchPointer {
            appDelegate.setMenuIcon(.busy)
            compileQueue.async {
                self.builder.linkerOptions =
                    " -Xlinker -image_base -Xlinker 0x" +
                    String(Int(bitPattern: slide), radix: 16)
                do {
                    let dylib = try self.builder.rebuildClass(oldClass: nil,
                                          classNameOrFile: source, extra: nil)
                    if let data = NSData(contentsOfFile: "\(dylib).dylib") {
                        commandQueue.async {
                            self.writeCommand(InjectionCommand.pseudoInject
                                                .rawValue, with: source)
                            self.writePointer(slide)
                            self.write(data as Data)
                        }
                        return
                    }
                } catch {
                    NSLog("\(error)")
                }
            }
        } else {
            super.recompileAndInject(source: source)
        }
    }
}
