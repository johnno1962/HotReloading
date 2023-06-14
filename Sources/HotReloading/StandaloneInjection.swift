//
//  StandaloneInjection.swift
//
//  Created by John Holdsworth on 15/03/2022.
//  Copyright © 2022 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/StandaloneInjection.swift#59 $
//
//  Standalone version of the HotReloading version of the InjectionIII project
//  https://github.com/johnno1962/InjectionIII. This file allows you to
//  add HotReloading to a project without having to add a "Run Script"
//  build phase to run the daemon process.
//
//  The most recent change was for the InjectionIII.app injection bundles
//  to fall back to this implementation if the user is not running the app.
//  This was made possible by using the FileWatcher to find the build log
//  directory in DerivedData of the most recently built project.
//

#if DEBUG || !SWIFT_PACKAGE
#if targetEnvironment(simulator) && !APP_SANDBOXED || os(macOS)
#if SWIFT_PACKAGE
import HotReloadingGuts
import SwiftTraceGuts
#endif
import SwiftTrace

@objc(StandaloneInjection)
class StandaloneInjection: InjectionClient {

    static var singleton: StandaloneInjection?
    var watchers = [FileWatcher]()

    override func runInBackground() {
        let builder = SwiftInjectionEval.sharedInstance()
        builder.tmpDir = NSTemporaryDirectory()
        #if SWIFT_PACKAGE
        let swiftTracePath = String(cString: swiftTrace_path())
        // convert SwiftTrace path into path to logs.
        builder.derivedLogs = swiftTracePath.replacingOccurrences(of:
            #"SourcePackages/checkouts/SwiftTrace/SwiftTraceGuts/SwiftTrace.mm$"#,
            with: "Logs/Build", options: .regularExpression)
        if builder.derivedLogs == swiftTracePath {
            log("⚠️ HotReloading could find log directory from: \(swiftTracePath)")
            builder.derivedLogs = nil // let FileWatcher find logs
        }
        #endif
        signal(SIGPIPE, { _ in print(APP_PREFIX+"⚠️ SIGPIPE") })
        builder.signer = { _ in return true }
        builder.debug = { (what: Any...) in
            //print("\(APP_PREFIX)***** %@", what.map {"\($0)"}.joined(separator: " "))
        }
        builder.forceUnhide = { builder.startUnhide() }
        builder.bazelLight = true

        let home = NSHomeDirectory()
            .replacingOccurrences(of: #"(/Users/[^/]+).*"#, with: "$1",
            options: .regularExpression)
        setenv("USER_HOME", home, 1)

        var dirs = [home]
        let library = home+"/Library"
        if let extra = getenv(SwiftInjection.INJECTION_DIRECTORIES) {
            dirs = String(cString: extra).components(separatedBy: ",")
                .map { $0[#"^~"#, substitute: home] } // expand ~ in paths
            if builder.derivedLogs == nil && dirs.allSatisfy({
                $0 != home && !$0.hasPrefix(library) }) {
                log("⚠️ INJECTION_DIRECTORIES should contain ~/Library")
                dirs.append(library)
            }
        }

        let holdOff = 2.0, minInterval = 0.33 // seconds
        var lastInjected = [String: TimeInterval]()

        if getenv(SwiftInjection.INJECTION_REPLAY) != nil {
            DispatchQueue.main.sync {
                _ = SwiftInjection.replayInjections()
            }
        }

        let firstInjected = Date.timeIntervalSinceReferenceDate + holdOff
        watchers.append(FileWatcher(roots: dirs,
                                    callback: { filesChanged, idePath in
            builder.lastIdeProcPath = idePath
            if builder.derivedLogs == nil {
                if let lastBuilt = FileWatcher.derivedLog {
                    builder.derivedLogs = URL(fileURLWithPath: lastBuilt)
                        .deletingLastPathComponent().path
                    self.log("Using logs: \(lastBuilt).")
                } else {
                    self.log("⚠️ Project unknown, please build it.")
                    return
                }
            }

            for changed in filesChanged {
                guard let changed = changed as? String,
                      !changed.hasPrefix(library) && !changed.contains("/."),
                      Date.timeIntervalSinceReferenceDate -
                        lastInjected[changed, default: firstInjected] >
                        minInterval else {
                    continue
                }
                if changed.hasSuffix(".storyboard") ||
                    changed.hasSuffix(".xib") {
                    #if os(iOS) || os(tvOS)
                    if !NSObject.injectUI(changed) {
                        self.log("⚠️ Interface injection failed")
                    }
                    #endif
                } else {
                    do {
                        let tmpfile = try builder.rebuildClass(oldClass: nil,
                                        classNameOrFile: changed, extra: nil)
                        try SwiftInjection.inject(tmpfile: tmpfile)
                    } catch {
                    }
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
    }

    var swiftTracing: String?

    func maybeTrace() {
        if let pattern = getenv(SwiftInjection.INJECTION_TRACE)
            .flatMap({String(cString: $0)}), pattern != swiftTracing {
            SwiftTrace.typeLookup = getenv(SwiftInjection.INJECTION_LOOKUP) != nil
            SwiftInjection.traceInjection = true
            if pattern != "" {
                // This alone will not work for non-final class methods.
                _ = SwiftTrace.interpose(aBundle: searchBundleImages(),
                                         methodName: pattern)
            }
            swiftTracing = pattern
        }
    }
}
#endif
#endif
