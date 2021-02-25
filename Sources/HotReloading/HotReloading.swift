//
//  HotReloading.swift
//  InjectionBundle
//
//  Created by John Holdsworth on 02/24/2021.
//  Copyright © 2021 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/HotReloading.swift#3 $
//
//  Client app side of HotReloading started by +load
//  method in HotReloadingGuts/ClientBoot.mm
//

import Foundation
import HotReloadingGuts

@objc(HotReloading)
public class HotReloading: SimpleSocket {

    public override func runInBackground() {
        let builder = SwiftInjectionEval.sharedInstance()
        builder.tmpDir = NSTemporaryDirectory()
        
        write(INJECTION_SALT)
        write(INJECTION_KEY)

        write(builder.tmpDir)
        write(builder.arch)
        write(Bundle.main.executablePath!)

        builder.tmpDir = readString() ?? "/tmp"

        while let command = InjectionCommand(rawValue: readInt()),
              command != .EOF {
            switch command {
            case .vaccineSettingChanged:
                _ = readString()
            case .connected:
                builder.projectFile = readString()!
                builder.derivedLogs = nil;
                print("\(prefix)HotReloading connected \(builder.projectFile ?? "Missing project")")
            case .watching:
                print("\(prefix)Watching \(readString() ?? "Missing directory")")
            case .log:
                print(prefix+(readString() ?? "Missing log message"))
            case .ideProcPath:
                _ = readString()
            case .load:
                if let changed = self.readString() {
                    DispatchQueue.main.sync {
                        do {
                            try SwiftInjection.inject(tmpfile: changed)
                        } catch {
                            print(error)
                        }
                    }
                }
            case .invalid:
                print("\(prefix)Invalid INJECTION_SALT")
            default:
                print("\(prefix)Unimplemented connand: \(command.rawValue)")
            }
        }
    }
}
