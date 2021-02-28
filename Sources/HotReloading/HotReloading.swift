//
//  HotReloading.swift
//  HotReloading
//
//  Created by John Holdsworth on 02/24/2021.
//  Copyright © 2021 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/HotReloading.swift#10 $
//
//  Client app side of HotReloading started by +load
//  method in HotReloadingGuts/InjectionClient.mm
//

import Foundation
import SwiftTrace
import SwiftTraceGuts
import HotReloadingGuts

@objc(HotReloading)
public class HotReloading: SimpleSocket {

    @objc class func connectedAddress() -> String {
        return "127.0.0.1"
    }

    public override func runInBackground() {
        let builder = SwiftInjectionEval.sharedInstance()
        builder.tmpDir = NSTemporaryDirectory()

        write(INJECTION_SALT)
        write(INJECTION_KEY)

        let frameworksPath = Bundle.main.privateFrameworksPath!
        write(builder.tmpDir)
        write(builder.arch)
        write(Bundle.main.executablePath!)

        builder.tmpDir = readString() ?? "/tmp"

        var frameworkPaths = [String: String]()
        let isPlugin = builder.tmpDir == "/tmp"
        if (!isPlugin) {
            var frameworks = [String]()
            var sysFrameworks = [String]()
            var imageMap = [String: String]()
            let bundleFrameworks = frameworksPath

            for i in stride(from: _dyld_image_count()-1, through: 0, by: -1) {
                let imageName = _dyld_get_image_name(i)!
                if strstr(imageName, ".framework/") == nil {
                    continue
                }
                let imagePath = String(cString: imageName)
                let frameworkName = URL(fileURLWithPath: imagePath).lastPathComponent
                imageMap[frameworkName] = imagePath
                if String(cString: imageName).hasPrefix(bundleFrameworks) {
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
            frameworkPaths = imageMap;
        }

        builder.signer = { dylib -> Bool in
            self.writeCommand(InjectionResponse.sign.rawValue, with: dylib)
            return self.readInt() == InjectionCommand.signed.rawValue &&
                self.readString() == "1"
        }

        while let command = InjectionCommand(rawValue: readInt()),
              command != .EOF {
            switch command {
            case .vaccineSettingChanged:
                if let data = readString()?.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    builder.vaccineEnabled = json[UserDefaultsVaccineEnabled] as! Bool
                }
            case .connected:
                builder.projectFile = readString() ?? "Missing project"
                builder.derivedLogs = nil;
                print("\(prefix)HotReloading connected \(builder.projectFile!)")
            case .watching:
                print("\(prefix)Watching \(readString() ?? "Missing directory")")
            case .log:
                print(prefix+(readString() ?? "Missing log message"))
            case .ideProcPath:
                builder.lastIdeProcPath = readString() ?? ""
            case .load:
                guard let changed = self.readString() else { break }
                DispatchQueue.main.sync {
                    do {
                        try SwiftInjection.inject(tmpfile: changed)
                    } catch {
                        print(error)
                    }
                }
                writeCommand(InjectionResponse.complete.rawValue, with: nil)
            case .inject:
                guard let changed = readString() else { break }
                DispatchQueue.main.sync {
                    _ = NSObject.injectUI(changed)
                }
                writeCommand(InjectionResponse.complete.rawValue, with: nil)
            case .invalid:
                print("\(prefix)⚠️ Server has rejected your connection. Are you running start_daemon.sh from the right directory? ⚠️")
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
                    print("\(prefix)Discovery of target app's types switched \(SwiftTrace.typeLookup ? "on" : "off")");
                }
            case .xprobe:
                _ = readString()
                Xprobe.connect(to: nil, retainObjects:true)
                Xprobe.search("")
            case .trace:
                SwiftTrace.traceMainBundleMethods()
                print("\(prefix)Added trace to non-final methods of classes in app bundle")
            case .untrace:
                SwiftTrace.removeAllTraces()
            case .traceUI:
                SwiftTrace.traceMainBundleMethods()
                SwiftTrace.traceMainBundle()
                print("\(prefix)Added trace to methods in main bundle\n")
            case .traceUIKit:
                DispatchQueue.main.sync {
                    let OSView: AnyClass = (objc_getClass("UIView") ??
                        objc_getClass("NSView")) as! AnyClass
                    print("\(prefix)Adding trace to the framework containg \(OSView), this will take a while...")
                    SwiftTrace.traceBundle(containing: OSView)
                    print("\(prefix)Completed adding trace.")
                }
            case .traceSwiftUI:
                if let AnyText = swiftUIBundlePath() {
                    print("\(prefix)Adding trace to SwiftUI calls.")
                    SwiftTrace.interposeMethods(inBundlePath:AnyText, packageName:nil)
                    filteringChanged()
                } else {
                    print("\(prefix)Your app doesn't seem to use SwiftUI.")
                }
            case .traceFramework:
                let frameworkName = readString() ?? "Misssing framework"
                if let frameworkPath = frameworkPaths[frameworkName] {
                    print("\(prefix)Tracing %s\n", frameworkPath)
                    SwiftTrace.interposeMethods(inBundlePath:frameworkPath, packageName:nil)
                    SwiftTrace.trace(bundlePath:frameworkPath)
                } else {
                    print("\(prefix)Tracing package \(frameworkName)")
                    let mainBundlePath = Bundle.main.executablePath ?? "Missing"
                    SwiftTrace.interposeMethods(inBundlePath:mainBundlePath,
                                                packageName:frameworkName)
                }
                filteringChanged()
            case .uninterpose:
                SwiftTrace.revertInterposes()
                SwiftTrace.removeAllTraces()
                print("\(prefix)Removed all traces (and injections).")
                break;
            case .stats:
                let top = 200;
                print("""

                    \(prefix)Sorted top \(top) elapsed time/invocations by method
                    \(prefix)=================================================
                    """)
                SwiftInjection.dumpStats(top:top)
                needsTracing()
            case .callOrder:
                print("""

                    \(prefix)Function names in the order they were first called:
                    \(prefix)===================================================
                    """)
                for signature in SwiftInjection.callOrder() {
                    print(signature)
                }
                needsTracing()
            case .fileOrder:
                print("""
                    \(prefix)Source files in the order they were first referenced:
                    \(prefix)=====================================================
                    \(prefix)(Order the source files should be compiled in target)
                    """)
                SwiftInjection.fileOrder()
                needsTracing()
            case .fileReorder:
                writeCommand(InjectionResponse.callOrderList.rawValue,
                             with:SwiftInjection.callOrder().joined(separator: CALLORDER_DELIMITER))
                needsTracing()
            case .signed:
                write(readString() ?? "0")
            case .eval:
                let parts = readString()?.components(separatedBy:"^")
                DispatchQueue.main.sync {
                    if let parts = parts,
                       let pathID = Int(parts[0]) {
                        self.writeCommand(InjectionResponse.pause.rawValue, with:"5")
                        if let object = (xprobePaths[pathID] as? XprobePath)?
                            .object() as? NSObject, object.responds(to: Selector(("swiftEvalWithCode:"))),
                           let code = (parts[3] as NSString).removingPercentEncoding,
                           object.swiftEval(code: code) {
                        } else {
                            print("\(prefix)Xprobe: Eval only works on NSObject subclasses where the source file has the same name as the class and is in your project.")
                        }
                        Xprobe.write("$('BUSY\(pathID)').hidden = true; ")
                    }
                }
            default:
                print("\(prefix)Unimplemented command: \(command.rawValue)")
            }
        }

        print("\(prefix)HotReloading disconnected.")
    }

    func needsTracing() {
        if SwiftTrace.swiftTracing {
            print("\(prefix)⚠️ You need to have traced something to gather stats.")
        }
    }

    func filteringChanged() {
        if SwiftTrace.swiftTracing {
            let exclude = SwiftTrace.traceFilterExclude
            if let include = SwiftTrace.traceFilterInclude {
                print(String(format: exclude != nil ?
                   "\(prefix)Filtering trace to include methods matching '%@' but not '%@'." :
                   "\(prefix)Filtering trace to include methods matching '%@'.",
                   include, exclude != nil ? exclude! : ""))
            } else {
                print(String(format: exclude != nil ?
                   "\(prefix)Filtering trace to exclude methods matching '%@'." :
                   "\(prefix)Not filtering trace (Menu Item: 'Set Filters')",
                   exclude != nil ? exclude! : ""))
            }
        }
    }
}
