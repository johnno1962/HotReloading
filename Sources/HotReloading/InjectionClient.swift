//
//  InjectionClient.swift
//  InjectionIII
//
//  Created by John Holdsworth on 02/24/2021.
//  Copyright © 2021 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/InjectionClient.swift#83 $
//
//  Client app side of HotReloading started by +load
//  method in HotReloadingGuts/ClientBoot.mm
//

#if DEBUG || !SWIFT_PACKAGE
import Foundation
#if SWIFT_PACKAGE
#if canImport(InjectionScratch)
import InjectionScratch
#endif
import Xprobe
import ProfileSwiftUI

public struct HotReloading {
    public static var stack: Void {
        injection_stack()
    }
}
#endif

#if os(macOS)
let isVapor = true
#else
let isVapor = dlsym(SwiftMeta.RTLD_DEFAULT, VAPOR_SYMBOL) != nil
#endif

@objc(InjectionClient)
public class InjectionClient: SimpleSocket, InjectionReader {

    let injectionQueue = isVapor ? DispatchQueue(label: "InjectionQueue") : .main
    var appVersion: String?

    open func log(_ msg: String) {
        print(APP_PREFIX+msg)
    }

    #if canImport(InjectionScratch)
    func next(scratch: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
        return scratch
    }
    #endif

    public override func runInBackground() {
        let builder = SwiftInjectionEval.sharedInstance()
        builder.tmpDir = NSTemporaryDirectory()

        write(INJECTION_SALT)
        write(INJECTION_KEY)

        let frameworksPath = Bundle.main.privateFrameworksPath!
        write(builder.tmpDir)
        write(builder.arch)
        let executable = Bundle.main.executablePath!
        write(executable)

        #if canImport(InjectionScratch)
        var isiOSAppOnMac = false
        if #available(iOS 14.0, *) {
            isiOSAppOnMac = ProcessInfo.processInfo.isiOSAppOnMac
        }
        if !isiOSAppOnMac, let scratch = loadScratchImage(nil, 0, self, nil) {
            log("⚠️ You are using device injection which is very much a work in progress. Expect the unexpected.")
            writeCommand(InjectionResponse
                            .scratchPointer.rawValue, with: nil)
            writePointer(next(scratch: scratch))
        }
        #endif

        builder.forceUnhide = { self.writeCommand(InjectionResponse
                                .forceUnhide.rawValue, with: nil) }

        builder.tmpDir = readString() ?? "/tmp"

        builder.createUnhider(executable: executable,
                              SwiftInjection.objcClassRefs,
                              SwiftInjection.descriptorRefs)

        if getenv(SwiftInjection.INJECTION_UNHIDE) != nil {
            builder.legacyUnhide = true
            writeCommand(InjectionResponse.legacyUnhide.rawValue, with: "1")
        }

        var frameworkPaths = [String: String]()
        let isPlugin = builder.tmpDir == "/tmp"
        if (!isPlugin) {
            var frameworks = [String]()
            var sysFrameworks = [String]()

            for i in stride(from: _dyld_image_count()-1, through: 0, by: -1) {
                guard let imageName = _dyld_get_image_name(i),
                    strstr(imageName, ".framework/") != nil else {
                    continue
                }
                let imagePath = String(cString: imageName)
                let frameworkName = URL(fileURLWithPath: imagePath).lastPathComponent
                frameworkPaths[frameworkName] = imagePath
                if imagePath.hasPrefix(frameworksPath) {
                    frameworks.append(frameworkName)
                } else {
                    sysFrameworks.append(frameworkName)
                }
            }

            writeCommand(InjectionResponse.frameworkList.rawValue, with:
                frameworks.joined(separator: FRAMEWORK_DELIMITER))
            write(sysFrameworks.joined(separator: FRAMEWORK_DELIMITER))
            write(SwiftInjection.packageNames()
                .joined(separator: FRAMEWORK_DELIMITER))
        }

        var codesignStatusPipe = [Int32](repeating: 0, count: 2)
        pipe(&codesignStatusPipe)
        let reader = SimpleSocket(socket: codesignStatusPipe[0])
        let writer = SimpleSocket(socket: codesignStatusPipe[1])

        builder.signer = { dylib -> Bool in
            self.writeCommand(InjectionResponse.getXcodeDev.rawValue,
                              with: builder.xcodeDev)
            self.writeCommand(InjectionResponse.sign.rawValue, with: dylib)
            return reader.readString() == "1"
        }

        SwiftTrace.swizzleFactory = SwiftTrace.LifetimeTracker.self

        if let projectRoot = getenv(SwiftInjection.INJECTION_PROJECT_ROOT) {
            writeCommand(InjectionResponse.projectRoot.rawValue,
                         with: String(cString: projectRoot))
        }
        if let derivedData = getenv(INJECTION_DERIVED_DATA) {
            writeCommand(InjectionResponse.derivedData.rawValue,
                         with: String(cString: derivedData))
        }

        commandLoop:
        while true {
            let commandInt = readInt()
            guard let command = InjectionCommand(rawValue: commandInt) else {
                log("Invalid commandInt: \(commandInt)")
                break
            }
            switch command {
            case .EOF:
                log("EOF received from server..")
                break commandLoop
            case .signed:
                writer.write(readString() ?? "0")
            case .traceFramework:
                let frameworkName = readString() ?? "Misssing framework"
                if let frameworkPath = frameworkPaths[frameworkName] {
                    print("\(APP_PREFIX)Tracing %s\n", frameworkPath)
                    _ = SwiftTrace.interposeMethods(inBundlePath: frameworkPath,
                                                    packageName: nil)
                    SwiftTrace.trace(bundlePath:frameworkPath)
                } else {
                    log("Tracing package \(frameworkName)")
                    let mainBundlePath = Bundle.main.executablePath ?? "Missing"
                    _ = SwiftTrace.interposeMethods(inBundlePath: mainBundlePath,
                                                    packageName: frameworkName)
                }
                filteringChanged()
            default:
                process(command: command, builder: builder)
            }
        }

        builder.forceUnhide = {}
        log("\(APP_NAME) disconnected.")
    }

    func process(command: InjectionCommand, builder: SwiftEval) {
        switch command {
        case .vaccineSettingChanged:
            if let data = readString()?.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                builder.vaccineEnabled = json[UserDefaultsVaccineEnabled] as! Bool
            }
        case .connected:
            let projectFile = readString() ?? "Missing project"
            log("\(APP_NAME) connected \(projectFile)")
            builder.projectFile = projectFile
            builder.derivedLogs = nil;
        case .watching:
            log("Watching files under the directory \(readString() ?? "Missing directory")")
        case .log:
            log(readString() ?? "Missing log message")
        case .ideProcPath:
            builder.lastIdeProcPath = readString() ?? ""
        case .invalid:
            log("⚠️ Server has rejected your connection. Are you running InjectionIII.app or start_daemon.sh from the right directory? ⚠️")
        case .quietInclude:
            SwiftTrace.traceFilterInclude = readString()
        case .include:
            SwiftTrace.traceFilterInclude = readString()
            filteringChanged()
        case .exclude:
            SwiftTrace.traceFilterExclude = readString()
            filteringChanged()
        case .feedback:
            SwiftInjection.traceInjection = readString() == "1"
        case .lookup:
            SwiftTrace.typeLookup = readString() == "1"
            if SwiftTrace.swiftTracing {
                log("Discovery of target app's types switched \(SwiftTrace.typeLookup ? "on" : "off")");
            }
        case .trace:
            if SwiftTrace.traceMainBundleMethods() == 0 {
                log("⚠️ Tracing Swift methods can only work if you have -Xlinker -interposable to your project's Debug \"Other Linker Flags\"")
            } else {
                log("Added trace to methods in main bundle")
            }
            filteringChanged()
        case .untrace:
            SwiftTrace.removeAllTraces()
        case .traceUI:
            if SwiftTrace.traceMainBundleMethods() == 0 {
                log("⚠️ Tracing Swift methods can only work if you have -Xlinker -interposable to your project's Debug \"Other Linker Flags\"")
            }
            SwiftTrace.traceMainBundle()
            log("Added trace to methods in main bundle")
            filteringChanged()
        case .traceUIKit:
            DispatchQueue.main.sync {
                let OSView: AnyClass = (objc_getClass("UIView") ??
                    objc_getClass("NSView")) as! AnyClass
                log("Adding trace to the framework containg \(OSView), this will take a while...")
                SwiftTrace.traceBundle(containing: OSView)
                log("Completed adding trace.")
            }
            filteringChanged()
        case .traceSwiftUI:
            if let bundleOfAnyTextStorage = swiftUIBundlePath() {
                log("Adding trace to SwiftUI calls.")
                _ = SwiftTrace.interposeMethods(inBundlePath: bundleOfAnyTextStorage, packageName:nil)
                filteringChanged()
            } else {
                log("Your app doesn't seem to use SwiftUI.")
            }
        case .uninterpose:
            SwiftTrace.revertInterposes()
            SwiftTrace.removeAllTraces()
            log("Removed all traces (and injections).")
            break;
        case .stats:
            let top = 200;
            print("""

                \(APP_PREFIX)Sorted top \(top) elapsed time/invocations by method
                \(APP_PREFIX)=================================================
                """)
            SwiftInjection.dumpStats(top:top)
            needsTracing()
        case .callOrder:
            print("""

                \(APP_PREFIX)Function names in the order they were first called:
                \(APP_PREFIX)===================================================
                """)
            for signature in SwiftInjection.callOrder() {
                print(signature)
            }
            needsTracing()
        case .fileOrder:
            print("""
                \(APP_PREFIX)Source files in the order they were first referenced:
                \(APP_PREFIX)=====================================================
                \(APP_PREFIX)(Order the source files should be compiled in target)
                """)
            SwiftInjection.fileOrder()
            needsTracing()
        case .counts:
            print("""
                \(APP_PREFIX)Counts of live objects by class:
                \(APP_PREFIX)================================
                """)
            SwiftInjection.objectCounts()
            needsTracing()
        case .fileReorder:
            writeCommand(InjectionResponse.callOrderList.rawValue,
                         with:SwiftInjection.callOrder().joined(separator: CALLORDER_DELIMITER))
            needsTracing()
        case .copy:
            if let data = readData() {
                injectionQueue.async {
                    var err: String?
                    do {
                        builder.injectionNumber += 1
                        try data.write(to: URL(fileURLWithPath: "\(builder.tmpfile).dylib"))
                        try SwiftInjection.inject(tmpfile: builder.tmpfile)
                    } catch {
                        self.log("⚠️ Injection error: \(error)")
                        err = "\(error)"
                    }
                    let response: InjectionResponse = err != nil ? .error : .complete
                    self.writeCommand(response.rawValue, with: err)
                }
            }
        case .pseudoUnlock:
            #if canImport(InjectionScratch)
            presentInjectionScratch(readString() ?? "")
            #endif
        case .objcClassRefs:
            if let array = readString()?
                .components(separatedBy: ",") as NSArray?,
               let mutable = array.mutableCopy() as? NSMutableArray {
                SwiftInjection.objcClassRefs = mutable
            }
        case .descriptorRefs:
            if let array = readString()?
                .components(separatedBy: ",") as NSArray?,
               let mutable = array.mutableCopy() as? NSMutableArray {
                SwiftInjection.descriptorRefs = mutable
            }
        case .setXcodeDev:
            if let xcodeDev = readString() {
                builder.xcodeDev = xcodeDev
            }
        case .appVersion:
            appVersion = readString()
            writeCommand(InjectionResponse.buildCache.rawValue,
                         with: builder.buildCacheFile)
        case .profileUI:
            DispatchQueue.main.async {
                ProfileSwiftUI.profile()
            }
        default:
            processOnMainThread(command: command, builder: builder)
        }
    }

    func processOnMainThread(command: InjectionCommand, builder: SwiftEval) {
        guard let changed = self.readString() else {
            log("⚠️ Could not read changed filename?")
            return
        }
        #if canImport(InjectionScratch)
        if command == .pseudoInject,
           let imagePointer = self.readPointer() {
            var percent = 0.0
            pushPseudoImage(changed, imagePointer)
            guard let imageEnd = loadScratchImage(imagePointer,
                self.readInt(), self, &percent) else { return }

            DispatchQueue.main.async {
                do {
                    builder.injectionNumber += 1
                    let tmpfile = String(cString: searchLastLoaded())
                    let newClasses = try SwiftEval.instance.extractClasses(dl: UnsafeMutableRawPointer(bitPattern: ~0)!, tmpfile: tmpfile)
                    try SwiftInjection.inject(tmpfile: tmpfile, newClasses: newClasses)
                } catch {
                    NSLog("Pseudo: \(error)")
                }
                if percent > 75 {
                    print(String(format: "\(APP_PREFIX)You have used %.1f%% of InjectionScratch space.", percent))
                }
                self.writeCommand(InjectionResponse.scratchPointer.rawValue, with: nil)
                self.writePointer(self.next(scratch: imageEnd))
            }
            return
        }
        #endif
        injectionQueue.async {
            var err: String?
            switch command {
            case .load:
                do {
                    builder.injectionNumber += 1
                    try SwiftInjection.inject(tmpfile: changed)
                } catch {
                    err = error.localizedDescription
                }
            case .inject:
                if changed.hasSuffix("storyboard") || changed.hasSuffix("xib") {
                    #if os(iOS) || os(tvOS)
                    if !NSObject.injectUI(changed) {
                        err = "Interface injection failed"
                    }
                    #else
                    err = "Interface injection not available on macOS."
                    #endif
                } else {
                    builder.forceUnhide = { builder.startUnhide() }
                    SwiftInjection.inject(classNameOrFile: changed)
                }
            #if SWIFT_PACKAGE
            case .xprobe:
                Xprobe.connect(to: nil, retainObjects:true)
                Xprobe.search("")
            case .eval:
                let parts = changed.components(separatedBy:"^")
                guard let pathID = Int(parts[0]) else { break }
                self.writeCommand(InjectionResponse.pause.rawValue, with:"5")
                if let object = (xprobePaths[pathID] as? XprobePath)?
                    .object() as? NSObject, object.responds(to: Selector(("swiftEvalWithCode:"))),
                   let code = (parts[3] as NSString).removingPercentEncoding,
                   object.swiftEval(code: code) {
                } else {
                    self.log("Xprobe: Eval only works on NSObject subclasses where the source file has the same name as the class and is in your project.")
                }
                Xprobe.write("$('BUSY\(pathID)').hidden = true; ")
            #endif
            default:
                self.log("⚠️ Unimplemented command: #\(command.rawValue). " +
                         "Are you running the most recent versions?")
            }
            let response: InjectionResponse = err != nil ? .error : .complete
            self.writeCommand(response.rawValue, with: err)
        }
    }

    func needsTracing() {
        if !SwiftTrace.swiftTracing {
            log("⚠️ You need to have traced something to gather stats.")
        }
    }

    func filteringChanged() {
        if SwiftTrace.swiftTracing {
            let exclude = SwiftTrace.traceFilterExclude
            if let include = SwiftTrace.traceFilterInclude {
                print(String(format: exclude != nil ?
                   "\(APP_PREFIX)Filtering trace to include methods matching '%@' but not '%@'." :
                   "\(APP_PREFIX)Filtering trace to include methods matching '%@'.",
                   include, exclude != nil ? exclude! : ""))
            } else {
                print(String(format: exclude != nil ?
                   "\(APP_PREFIX)Filtering trace to exclude methods matching '%@'." :
                   "\(APP_PREFIX)Not filtering trace (Menu Item: 'Set Filters')",
                   exclude != nil ? exclude! : ""))
            }
        }
    }
}
#endif
