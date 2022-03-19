//
//  InjtionStandalone.swift
//
//  Created by John Holdsworth on 15/03/2022.
//  Copyright © 2022 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/InjectionStandalone.swift#11 $
//
//  Standalone version of the HotReloading version of the InjectionIII project
//  https://github.com/johnno1962/InjectionIII. This file allows you to
//  add HotReloading to a project without having to add a "Run Script"
//  build phase to run the daemon process.
//

#if SWIFT_PACKAGE
import HotReloadingGuts
import SwiftTraceGuts
import SwiftRegex

@objc(InjectionStandalone)
class InjectionStandalone: InjectionClient {

    var watchers = [FileWatcher]()

    override func runInBackground() {
        let builder = SwiftInjectionEval.sharedInstance()
        let swiftTracePath = String(cString: swiftTrace_path())
        builder.tmpDir = NSTemporaryDirectory()
        builder.derivedLogs = swiftTracePath.replacingOccurrences(of:
            "SourcePackages/checkouts/SwiftTrace/SwiftTraceGuts/SwiftTrace.mm",
            with: "Logs/Build")
        if builder.derivedLogs == swiftTracePath {
            log("⚠️ HotReloading could find log directory from: \(swiftTracePath)")
        }
        builder.signer = { _ in return true }
        builder.HRLog = { (what: Any...) in }

        SwiftInjection.traceInjection = getenv("INJECTION_TRACE") != nil

        if let home = NSHomeDirectory()[#"/Users/[^/]+"#] as String? {
            var dirs = [home]
            if let extra = getenv("INJECTION_DIRECTORIES") {
                dirs = String(cString: extra).components(separatedBy: ",")
                    .map { $0.replacingOccurrences(of: "~", with: home) }
            }
            for dir in dirs {
                watchers.append(FileWatcher(root: dir, callback: { filesChanged, _ in
                    for changed in filesChanged {
                        do {
                            let tmpfile = try builder.rebuildClass(oldClass: nil,
                                classNameOrFile: changed as! String, extra: nil)
                            try SwiftInjection.inject(tmpfile: tmpfile)
                        } catch {
                        }
                    }
                }))
            }
            log("HotReloading available for sources under \(dirs)")
        } else {
            log("⚠️ HotReloading could not parse home directory.")
        }
    }
}
#endif
