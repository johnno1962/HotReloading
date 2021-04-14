//
//  UnhidingEval.swift
//
//  Created by John Holdsworth on 13/04/2021.
//
//  $Id: //depot/HotReloading/Sources/injectiond/UnhidingEval.swift#4 $
//
//  Retro-fit Unhide into InjectionIII
//

import Foundation
#if SWIFT_PACKAGE
import HotReloadingGuts
#endif

@objc
public class UnhidingEval: SwiftEval {

    @objc public override class func sharedInstance() -> SwiftEval {
        SwiftEval.instance = UnhidingEval()
        return SwiftEval.instance
    }

    var unhidden = false

    public override func determineEnvironment(classNameOrFile: String) throws -> (URL, URL) {
        let (project, logs) =
            try super.determineEnvironment(classNameOrFile: classNameOrFile)

        if !unhidden {
            let buildDir = logs.deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Build")
            if let enumerator = FileManager.default
                    .enumerator(atPath: buildDir.path),
                let log = fopen("/tmp/unhide.log", "w") {
                let linkFileLists = enumerator
                    .compactMap { $0 as? String }
                    .filter { $0.hasSuffix(".LinkFileList") }
                DispatchQueue.global(qos: .background).async {
                    for path in linkFileLists.sorted(by: {
                        ($0.hasSuffix(".o.LinkFileList") ? 0 : 1) <
                        ($1.hasSuffix(".o.LinkFileList") ? 0 : 1) }) {
                        print("\(APP_PREFIX)Processing \(path)")
                        let fileURL = buildDir
                            .appendingPathComponent(path)
                        let exported = unhide_symbols(fileURL
                            .deletingPathExtension().deletingPathExtension()
                            .lastPathComponent, fileURL.path, log)
                        if exported != 0 {
                            print("\(APP_PREFIX)Exported \(exported) default arguments")
                        }
                    }
                    unhide_reset()
                    fclose(log)
                }
            }
            unhidden = true
        }

        return (project, logs)
    }
}
