//
//  StandaloneInjection.swift
//
//  Created by John Holdsworth on 15/03/2022.
//  Copyright © 2022 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/StandaloneInjection.swift#28 $
//
//  Standalone version of the HotReloading version of the InjectionIII project
//  https://github.com/johnno1962/InjectionIII. This file allows you to
//  add HotReloading to a project without having to add a "Run Script"
//  build phase to run the daemon process. This file uses the SwiftRegex5
//  package which defines various subscripting operators on a string with
//  a Regex. When a second string is supplied this acts as a inline string
//  substitution. Regex patterns are raw strings to emphasise this role.
//

#if targetEnvironment(simulator) || os(macOS)
#if SWIFT_PACKAGE
import HotReloadingGuts
import SwiftTraceGuts
import SwiftRegex
#endif

@objc(StandaloneInjection)
class StandaloneInjection: InjectionClient {

    static var singleton: StandaloneInjection?
    var watchers = [FileWatcher]()

    override func runInBackground() {
        let builder = SwiftInjectionEval.sharedInstance()
        #if os(macOS)
        builder.tmpDir = NSTemporaryDirectory()
        #else
        builder.tmpDir = "/tmp"
        #endif
        #if SWIFT_PACKAGE
        let swiftTracePath = String(cString: swiftTrace_path())
        builder.derivedLogs = swiftTracePath[
            #"SourcePackages/checkouts/SwiftTrace/SwiftTraceGuts/SwiftTrace.mm$"#,
            substitute: "Logs/Build"] // convert SwiftTrace path into path to logs.
        if builder.derivedLogs == swiftTracePath {
            log("⚠️ HotReloading could find log directory from: \(swiftTracePath)")
        }
        #endif
        builder.signer = { _ in return true }
        builder.HRLog = { (what: Any...) in
            //print("\(APP_PREFIX)***** %@", what.map {"\($0)"}.joined(separator: " "))
        }
        signal(SIGPIPE, {_ in
            print(APP_PREFIX+"⚠️ SIGPIPE")
        })

        builder.forceUnhide = { builder.startUnhide() }
        SwiftInjection.traceInjection = getenv("INJECTION_TRACE") != nil

        let minInterval = 0.33
        var lastInjected = [String: TimeInterval]()

        if let home = NSHomeDirectory()[#"/Users/[^/]+"#] as String? {
            var dirs = [home]
            if let extra = getenv("INJECTION_PROJECT_ROOT") ??
                            getenv("INJECTION_DIRECTORIES") {
                dirs = String(cString: extra).components(separatedBy: ",")
                    .map { $0[#"^~"#, substitute: home] } // expand ~ in paths
            }
            watchers.append(FileWatcher(roots: dirs,
                                        callback: { filesChanged, idePath in
                    if builder.derivedLogs == nil {
                        if let lastChanged = FileWatcher.derivedLogs {
                            builder.derivedLogs = lastChanged
                            self.log("Using logs: \(lastChanged).")
                        } else {
                            self.log("⚠️ Unknown project, please build it.")
                            return
                        }
                    }
                    for changed in filesChanged {
                        guard let changed = changed as? String,
                              !changed.hasPrefix(home+"/Library/"),
                              !changed.contains("/."),
                              Date.timeIntervalSinceReferenceDate -
                                lastInjected[changed, default: 0.0] >
                                minInterval else {
                            continue
                        }
                        if changed.hasSuffix("storyboard") ||
                            changed.hasSuffix("xib") {
                            #if os(iOS) || os(tvOS)
                            if !NSObject.injectUI(changed) {
                                self.log("⚠️ Interface injection failed")
                            }
                            #endif
                            continue
                        }
                        do {
                            let tmpfile = try builder.rebuildClass(oldClass: nil,
                                classNameOrFile: changed, extra: nil)
                            try SwiftInjection.inject(tmpfile: tmpfile)
                        } catch {
                        }
                        lastInjected[changed] = Date.timeIntervalSinceReferenceDate
                    }
                }))
            log("HotReloading available for sources under \(dirs)")
            if #available(iOS 14.0, tvOS 14.0, *) {
            } else {
                log("ℹ️ HotReloading not available on Apple Silicon before iOS 14.0")
            }
            if let executable = Bundle.main.executablePath {
                builder.createUnhider(executable: executable,
                                      SwiftInjection.objcClassRefs,
                                      SwiftInjection.descriptorRefs)
            }
            Self.singleton = self
        } else {
            log("⚠️ HotReloading could not parse home directory.")
        }
    }
}
#endif
