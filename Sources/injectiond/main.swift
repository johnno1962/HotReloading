//
//  HotReloading.swift
//  InjectionBundle
//
//  Created by John Holdsworth on 02/24/2021.
//  Copyright © 2021 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/injectiond/main.swift#2 $
//
//  Server daemon side of HotReloading simulating InjectionIII app.
//

import HotReloadingGuts
import Foundation
import SwiftRegex

let projectURL = URL(fileURLWithPath: CommandLine.arguments[1])

let pbxprojURL = projectURL.appendingPathComponent("project.pbxproj")

var projectEncoding: String.Encoding = .utf8

if let projectSource = try? String(contentsOf: pbxprojURL,
                                   usedEncoding: &projectEncoding),
   !projectSource.contains("-interposable") {
    var newProjectSource = projectSource
        // For each PBXSourcesBuildPhase in project file
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
        let backup = pbxprojURL.path+".preorder"
        if !FileManager.default.fileExists(atPath: backup) {
            try? projectSource.write(toFile: backup, atomically: true,
                                    encoding: projectEncoding)
        }
        do {
            try newProjectSource.write(to: pbxprojURL, atomically: false,
                                       encoding: projectEncoding)
        } catch {
            NSLog("Could not patch project \(pbxprojURL)")
        }
    }
}

class AppDelegate {

    struct HasState {
        enum State { case off, on }
        var state: State
    }

    var traceItem = HasState(state: .on)
    let frontItem = HasState(state: .on)
    let enableWatcher = HasState(state: .on)
    let isSandboxed = false

    var defaults = UserDefaults.standard
    weak var lastConnection: InjectionServer?
    var selectedProject: String? = projectURL.path
    var watchedDirectories = Set<String>([projectURL.deletingLastPathComponent().path])
    let runningXcodeDevURL: URL? = URL(fileURLWithPath: ProcessInfo().environment["DEVELOPER_DIR"] ??
        "/Applications/Xcode.app/Contents/Developer")

    func setMenuIcon(_ name: String) {
    }
    func fileReorder(signatures: [String]) {
    }
    func setFrameworks(_ frameworks: String, menuTitle: String) {
    }
    func vaccineConfiguration() -> String {
        return ""
    }
}

var appDelegate = AppDelegate()

for dir in CommandLine.arguments.dropFirst().dropFirst() {
    appDelegate.watchedDirectories.insert(dir)
}

InjectionServer.startServer(INJECTION_ADDRESS)

RunLoop.main.run()
