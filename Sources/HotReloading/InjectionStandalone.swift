//
//  InjtionStandalone.swift
//
//  Created by John Holdsworth on 15/03/2022.
//  Copyright © 2022 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/InjectionStandalone.swift#1 $
//
//  Standalone version of HotReloading version of InjectionIII project
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

    var watcher: FileWatcher?

    override func runInBackground() {
        let builder = SwiftInjectionEval.sharedInstance()
        builder.tmpDir = NSTemporaryDirectory()
        builder.derivedLogs =
            URL(fileURLWithPath: String(cString: swiftTrace_path()))
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Logs/Build").path
        builder.signer = { _ in return true }
        builder.HRLog = { (what: Any...) in }

        SwiftInjection.traceInjection = getenv("INJECTION_TRACE") != nil

        if let home = builder.derivedLogs?[#"/Users/[^/]+"#] as String? {
            print(APP_PREFIX+"HotReloading available for sources under "+home)
            watcher = FileWatcher(root: home, callback: { filesChanged, _ in
                for changed in filesChanged {
                    do {
                        let tmpfile = try builder.rebuildClass(oldClass: nil,
                            classNameOrFile: changed as! String, extra: nil)
                        try SwiftInjection.inject(tmpfile: tmpfile)
                    } catch {
                    }
                }
            })
        }
    }
}
#endif
