//
//  File.swift
//  
//
//  Created by John Holdsworth on 13/04/2021.
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
                    .enumerator(atPath: buildDir.path) {
                DispatchQueue.global(qos: .background).async {
                    for any in enumerator {
                        let file = any as! String
                        if file.hasSuffix(".LinkFileList") {
                            let fileURL = buildDir
                                .appendingPathComponent(file)
                            unhide_symbols(fileURL
                                .deletingPathExtension().deletingPathExtension()
                                .lastPathComponent, fileURL.path)
                        }
                    }
                }
            }
            unhidden = true
        }

        return (project, logs)
    }
}
