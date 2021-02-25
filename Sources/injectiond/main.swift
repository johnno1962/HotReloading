//
//  HotReloading.swift
//  InjectionBundle
//
//  Created by John Holdsworth on 02/24/2021.
//  Copyright © 2021 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/injectiond/main.swift#4 $
//
//  Server daemon side of HotReloading simulating the
//  InjectionIII app.
//

import HotReloadingGuts
import Foundation
import SwiftRegex
import Cocoa

let projectURL = URL(fileURLWithPath: CommandLine.arguments[1])
let pbxprojURL = projectURL.appendingPathComponent("project.pbxproj")

var projectEncoding: String.Encoding = .utf8
if let projectSource = try? String(contentsOf: pbxprojURL,
                                   usedEncoding: &projectEncoding),
   !projectSource.contains("-interposable") {
    var newProjectSource = projectSource
    // For each PBXSourcesBuildPhase in project file...
    // Make sure "Other linker Flags" includes -interposable
    newProjectSource[#"""
        /\* Debug \*/ = \{
        \s+isa = XCBuildConfiguration;
        (?:.*\n)*?(\s+)buildSettings = \{
        ((?:.*\n)*?\1\};)
        """#, group: 2] = """
                            OTHER_LDFLAGS = (
                                "-Xlinker",
                                "-interposable",
                                "-Xlinker",
                                "-undefined",
                                "-Xlinker",
                                dynamic_lookup,
                            );
                            ENABLE_BITCODE = NO;
            $2
            """

    if newProjectSource != projectSource {
        let backup = pbxprojURL.path+".prepatch"
        if !FileManager.default.fileExists(atPath: backup) {
            try? projectSource.write(toFile: backup, atomically: true,
                                    encoding: projectEncoding)
        }
        do {
            try newProjectSource.write(to: pbxprojURL, atomically: true,
                                       encoding: projectEncoding)
        } catch {
            NSLog("Could not patch project \(pbxprojURL): \(error)")
        }
    }
}

// Make available MainMenu.nib and Resources to app
var cwd = [Int8](repeating: 0, count: Int(MAXPATHLEN))
cwd.withUnsafeMutableBufferPointer {
    unlink(".build/debug/Contents")
    symlink("\(String(cString: getcwd($0.baseAddress, $0.count)))/Contents", ".build/debug/Contents")
}

// launch like a normal Cocoa app
var argv = [UnsafeMutablePointer<CChar>?]()

for arg in CommandLine.arguments {
    arg.withCString {
        argv.append(strdup($0))
    }
}

argv.withUnsafeMutableBufferPointer {
    _ = NSApplicationMain(Int32($0.count), $0.baseAddress!)
}
