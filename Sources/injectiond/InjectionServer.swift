//
//  InjectionServer.swift
//  InjectionIII
//
//  Created by John Holdsworth on 06/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/injectiond/InjectionServer.swift#40 $
//

import Cocoa
#if SWIFT_PACKAGE
import HotReloadingGuts
import injectiondGuts
import XprobeUI
#endif

let commandQueue = DispatchQueue(label: "InjectionCommand")
let compileQueue = DispatchQueue(label: "InjectionCompile")

var projectInjected = [String: [String: TimeInterval]]()
let MIN_INJECTION_INTERVAL = 1.0

public class InjectionServer: SimpleSocket {
    var fileChangeHandler: ((_ changed: NSArray, _ ideProcPath:String) -> Void)!
    var fileWatchers = [FileWatcher]()
    var pause: TimeInterval = 0.0
    var pending = [String]()
    var builder: SwiftEval!
    var lastIdeProcPath = ""
    let objcClassRefs = NSMutableArray()
    let descriptorRefs = NSMutableArray()

    open func log(_ msg: String) {
        NSLog("\(APP_PREFIX)\(APP_NAME) \(msg)")
    }

    override public class func error(_ message: String) -> Int32 {
        let saveno = errno
        let msg = String(format:message, strerror(saveno))
        NSLog("\(APP_PREFIX)\(APP_NAME) \(msg)")
        DispatchQueue.main.async {
            let alert: NSAlert = NSAlert()
            alert.messageText = "\(self)"
            alert.informativeText = msg
            alert.alertStyle = NSAlert.Style.warning
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
        }
        return -1
    }

    func sendCommand(_ command: InjectionCommand, with string: String?) {
        commandQueue.sync {
            _ = writeCommand(command.rawValue, with: string)
        }
    }

    func validateConnection() -> Bool {
        return readInt() == INJECTION_SALT && readString() == INJECTION_KEY
    }

    @objc override public func runInBackground() {
        var candiateProjectFile = appDelegate.selectedProject

        if candiateProjectFile == nil {
            DispatchQueue.main.sync {
                appDelegate.openProject(self)
            }
            candiateProjectFile = appDelegate.selectedProject
        }
        guard let projectFile = candiateProjectFile else {
            return
        }

        // tell client app the inferred project being watched
        log("Connection for project file: \(projectFile)")

        guard validateConnection() else {
            log("*** Error: SALT or KEY invalid. Are you running start_daemon.sh or InjectionIII.app from the right directory?")
            write("/tmp")
            write(InjectionCommand.invalid.rawValue)
            return
        }

        builder = UnhidingEval()
        defer {
            builder.signer = nil
            builder = nil
        }

        // client specific data for building
        if let frameworks = readString() {
            builder.frameworks = frameworks
        } else { return }

        if let arch = readString() {
            builder.arch = arch
        } else { return }

        if appDelegate.isSandboxed {
            builder.tmpDir = NSTemporaryDirectory()
        } else {
            builder.tmpDir = builder.frameworks
        }
        write(builder.tmpDir)
        log("Using tmp dir: \(builder.tmpDir)")

        // log errors to client
        builder.evalError = {
            (message: String) in
            self.log("evalError: \(message)")
            self.sendCommand(.log, with:
                (message.hasPrefix("Compiling") ?"":"⚠️ ")+message)
            return NSError(domain:"SwiftEval", code:-1,
                           userInfo:[NSLocalizedDescriptionKey: message])
        }

        builder.signer = {
            let identity = appDelegate.defaults.string(forKey: projectFile)
            if identity != nil {
                self.log("Signing with identity: \(identity!)")
            }
            return SignerService.codesignDylib(
                self.builder.tmpDir+"/eval"+$0, identity: identity)
        }

        // Xcode specific config
        if let xcodeDevURL = appDelegate.runningXcodeDevURL {
            builder.xcodeDev = xcodeDevURL.path
        }

        builder.projectFile = projectFile

        appDelegate.setMenuIcon(.ok)
        appDelegate.lastConnection = self
        pending = []

        var lastInjected = projectInjected[projectFile]
        if lastInjected == nil {
            lastInjected = [String: Double]()
            projectInjected[projectFile] = lastInjected!
        }

        guard let executable = readString() else { return }
        if appDelegate.defaults.bool(forKey: UserDefaultsReplay) &&  
            appDelegate.enableWatcher.state == .on {
            let mtime = {
                (path: String) -> time_t in
                var info = stat()
                return stat(path, &info) == 0 ? info.st_mtimespec.tv_sec : 0
            }
            let executableBuild = mtime(executable)
            for (source, _) in lastInjected! {
                if !source.hasSuffix("storyboard") && !source.hasSuffix("xib") &&
                    mtime(source) > executableBuild {
                    recompileAndInject(source: source)
                }
            }
        }

        builder.createUnhider(executable: executable,
                              objcClassRefs, descriptorRefs)

        var testCache = [String: [String]]()

        fileChangeHandler = {
            (changed: NSArray, ideProcPath: String) in
            var changed = changed as! [String]

            if UserDefaults.standard.bool(forKey: UserDefaultsTDDEnabled) {
                for injectedFile in changed {
                    var matchedTests = testCache[injectedFile]
                    if matchedTests == nil {
                        matchedTests = Self.searchForTestWithFile(injectedFile,
                              projectRoot: appDelegate
                                .watchedDirectories.first ??
                              (projectFile as NSString)
                                .deletingLastPathComponent,
                            fileManager: FileManager.default)
                        testCache[injectedFile] = matchedTests
                    }

                    changed += matchedTests!
                }
            }

            let now = NSDate.timeIntervalSinceReferenceDate
            let automatic = appDelegate.enableWatcher.state == .on
            for swiftSource in changed {
                if !self.pending.contains(swiftSource) {
                    if (now > (lastInjected?[swiftSource] ?? 0.0) + MIN_INJECTION_INTERVAL && now > self.pause) {
                        lastInjected![swiftSource] = now
                        projectInjected[projectFile] = lastInjected!
                        self.pending.append(swiftSource)
                        if !automatic {
                            let file = (swiftSource as NSString).lastPathComponent
                            self.sendCommand(.log,
                                with:"'\(file)' changed, type ctrl-= to inject")
                        }
                    }
                }
            }
            self.lastIdeProcPath = ideProcPath
            self.builder.lastIdeProcPath = ideProcPath
            if (automatic) {
                self.injectPending()
            }
        }
        defer { fileChangeHandler = nil }

        // start up file watchers to write generated tmpfile path to client app
        setProject(projectFile)
        if projectFile.contains("/Desktop/") || projectFile.contains("/Documents/") {
            sendCommand(.log, with: "\(APP_PREFIX)⚠️ Your project file seems to be in the Desktop or Documents folder and may prevent \(APP_NAME) working as it has special permissions.")
        }

        DispatchQueue.main.sync {
            appDelegate.updateTraceInclude(nil)
            appDelegate.updateTraceExclude(nil)
            appDelegate.toggleFeedback(nil)
            appDelegate.toggleLookup(nil)
        }

        // read status responses from client app
        while true {
            let commandInt = readInt()
            guard let response = InjectionResponse(rawValue: commandInt) else {
                log("InjectionServer: Unexpected case \(commandInt)")
                break
            }
            if response == .exit {
                break
            }
            process(response: response, executable: executable)
        }

        // client app disconnected
        fileWatchers.removeAll()
        appDelegate.traceItem.state = .off
        appDelegate.setMenuIcon(.idle)
    }

    func process(response: InjectionResponse, executable: String) {
            switch response {
            case .frameworkList:
                appDelegate.setFrameworks(readString() ?? "",
                                          menuTitle: "Trace Framework")
                appDelegate.setFrameworks(readString() ?? "",
                                          menuTitle: "Trace SysInternal")
                appDelegate.setFrameworks(readString() ?? "",
                                          menuTitle: "Trace Package")
            case .complete:
                appDelegate.setMenuIcon(.ok)
                if appDelegate.frontItem.state == .on {
                    print(executable)
                    let appToOrderFront: URL
                    if executable.contains("/MacOS/") {
                        appToOrderFront = URL(fileURLWithPath: executable)
                            .deletingLastPathComponent()
                            .deletingLastPathComponent()
                            .deletingLastPathComponent()
                    } else if executable.contains("/Wrapper/") {
                        appToOrderFront = URL(fileURLWithPath: executable)
                            .deletingLastPathComponent()
                    } else {
                        appToOrderFront = URL(fileURLWithPath: builder.xcodeDev)
                            .appendingPathComponent("Applications/Simulator.app")
                    }
                    NSWorkspace.shared.open(appToOrderFront)
                }
                break
            case .pause:
                pause = NSDate.timeIntervalSinceReferenceDate + Double(readString() ?? "0.0")!
                break
            case .sign:
                if !appDelegate.isSandboxed && xprobePlugin == nil {
                    sendCommand(.signed, with: "0")
                    break
                }
                sendCommand(.signed, with: builder
                                .signer!(readString() ?? "") ? "1": "0")
            case .callOrderList:
                if let calls = readString()?
                    .components(separatedBy: CALLORDER_DELIMITER) {
                    appDelegate.fileReorder(signatures: calls)
                }
                break
            case .error:
                appDelegate.setMenuIcon(.error)
                log("Injection error: \(readString() ?? "Uknown")")
                break;
            case .legacyUnhide:
                builder.legacyUnhide = readString() == "1"
            case .forceUnhide:
                builder.startUnhide()
            default:
                break
            }
    }

    func recompileAndInject(source: String) {
        sendCommand(.ideProcPath, with: lastIdeProcPath)
        appDelegate.setMenuIcon(.busy)
        if appDelegate.isSandboxed ||
            source.hasSuffix(".storyboard") || source.hasSuffix(".xib") {
            #if SWIFT_PACKAGE
            try? source.write(toFile: "/tmp/injecting_storyboard.txt",
                              atomically: false, encoding: .utf8)
            #endif
            sendCommand(.inject, with: source)
        } else {
            compileQueue.async {
                if let dylib = try? self.builder?.rebuildClass(oldClass: nil,
                                       classNameOrFile: source, extra: nil) {
                    #if SWIFT_PACKAGE && false // for virtualised simulator
                    if let data = NSData(contentsOfFile: "\(dylib).dylib") {
                        commandQueue.sync {
                            self.write(InjectionCommand.copy.rawValue)
                            self.write(data as Data)
                        }
                    } else {
                        self.sendCommand(.log, with: "\(APP_PREFIX)Error reding \(dylib).dylib")
                    }
                    #else
                    self.sendCommand(.load, with: dylib)
                    #endif
                } else {
                    appDelegate.setMenuIcon(.error)
                }
            }
        }
    }

    public func watchDirectory(_ directory: String) {
        fileWatchers.append(FileWatcher(root: directory,
                                        callback: fileChangeHandler))
        sendCommand(.watching, with: directory)
    }

    @objc public func injectPending() {
        for swiftSource in pending {
            recompileAndInject(source: swiftSource)
        }
        pending.removeAll()
    }

    @objc public func setProject(_ projectFile: String) {
        guard fileChangeHandler != nil else { return }

        builder?.projectFile = projectFile
        #if !SWIFT_PACKAGE
        let projectName = URL(fileURLWithPath: projectFile)
            .deletingPathExtension().lastPathComponent
        let derivedLogs = String(format:
            "%@/Library/Developer/Xcode/DerivedData/%@-%@/Logs/Build",
                                 NSHomeDirectory(), projectName
                                    .replacingOccurrences(of: #"[\s]+"#, with:"_",
                                                   options: .regularExpression),
            XcodeHash.hashString(forPath: projectFile))
        #else
        let derivedLogs = appDelegate.derivedLogs ?? "No derived logs"
        #endif
        if FileManager.default.fileExists(atPath: derivedLogs) {
            builder?.derivedLogs = derivedLogs
        }

        sendCommand(.vaccineSettingChanged,
                    with:appDelegate.vaccineConfiguration())
        fileWatchers.removeAll()
        sendCommand(.connected, with: projectFile)
        for directory in appDelegate.watchedDirectories {
            watchDirectory(directory)
        }
    }

    class func searchForTestWithFile(_ injectedFile: String,
            projectRoot: String, fileManager: FileManager) -> [String] {
        var matchedTests = [String]()
        let injectedFileName = URL(fileURLWithPath: injectedFile)
            .deletingPathExtension().lastPathComponent
        let projectUrl = URL(fileURLWithPath: projectRoot)
        if let enumerator = fileManager.enumerator(at: projectUrl,
                includingPropertiesForKeys: [URLResourceKey.nameKey,
                                             URLResourceKey.isDirectoryKey],
                options: .skipsHiddenFiles,
                errorHandler: {
                    (url: URL, error: Error) -> Bool in
                    NSLog("[Error] \(error) (\(url))")
                    return false
        }) {
            for fileURL in enumerator {
                var filename: AnyObject?
                var isDirectory: AnyObject?
                if let fileURL = fileURL as? NSURL {
                    try! fileURL.getResourceValue(&filename, forKey:URLResourceKey.nameKey)
                    try! fileURL.getResourceValue(&isDirectory, forKey:URLResourceKey.isDirectoryKey)

                    if filename?.hasPrefix("_") == true &&
                        isDirectory?.boolValue == true {
                        enumerator.skipDescendants()
                        continue
                    }

                    if isDirectory?.boolValue == false &&
                        filename?.lastPathComponent !=
                            (injectedFile as NSString).lastPathComponent &&
                        filename?.lowercased
                            .contains(injectedFileName.lowercased()) == true &&
                        filename?.contains("Tests.") == true {
                        matchedTests.append(fileURL.path!)
                    }
                }
            }
        }

        return matchedTests
    }

    public class func urlEncode(string: String) -> String {
        let unreserved = "-._~/?"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: unreserved)
        return string.addingPercentEncoding(withAllowedCharacters: allowed)!
    }

    deinit {
        log("\(self).deinit()")
    }
}
