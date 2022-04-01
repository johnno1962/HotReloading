//
//  StandaloneInjection.swift
//
//  Created by John Holdsworth on 15/03/2022.
//  Copyright © 2022 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/StandaloneInjection.swift#4 $
//
//  Standalone version of the HotReloading version of the InjectionIII project
//  https://github.com/johnno1962/InjectionIII. This file allows you to
//  add HotReloading to a project without having to add a "Run Script"
//  build phase to run the daemon process. This file uses the SwiftRegex5
//  package which defines various subscripting operators on a string with
//  a Regex. When a second string is supplied this acts as a inline string
//  substitution. Regex patterns are raw strings to emphasise this role.
//

#if SWIFT_PACKAGE
import HotReloadingGuts
import SwiftTraceGuts
import SwiftRegex

@objc(StandaloneInjection)
class StandaloneInjection: InjectionClient {

    static var singleton: StandaloneInjection?
    var watchers = [FileWatcher]()

    override func runInBackground() {
        let builder = SwiftInjectionEval.sharedInstance()
        let swiftTracePath = String(cString: swiftTrace_path())
        builder.tmpDir = NSTemporaryDirectory()
        builder.derivedLogs = swiftTracePath[
            #"SourcePackages/checkouts/SwiftTrace/SwiftTraceGuts/SwiftTrace.mm$"#,
            substitute: "Logs/Build"] // convert SwiftTrace path into path to logs.
        if builder.derivedLogs == swiftTracePath {
            log("⚠️ HotReloading could find log directory from: \(swiftTracePath)")
        }
        builder.signer = { _ in return true }
        builder.HRLog = { (what: Any...) in }
        signal(SIGPIPE, {_ in
            print(APP_PREFIX+"⚠️ SIGPIPE")
        })

        builder.forceUnhide = { builder.startUnhide() }
        SwiftInjection.traceInjection = getenv("INJECTION_TRACE") != nil

        if let executable = Bundle.main.executablePath {
            builder.createUnhider(executable: executable,
                                  SwiftInjection.objcClassRefs,
                                  SwiftInjection.descriptorRefs)
        }

        if let home = NSHomeDirectory()[#"/Users/[^/]+"#] as String? {
            var dirs = [home]
            if let extra = getenv("INJECTION_DIRECTORIES") {
                dirs = String(cString: extra).components(separatedBy: ",")
                    .map { $0[#"^~"#, substitute: home] } // expand ~ in paths
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
            Self.singleton = self
        } else {
            log("⚠️ HotReloading could not parse home directory.")
        }
    }
}
#endif
