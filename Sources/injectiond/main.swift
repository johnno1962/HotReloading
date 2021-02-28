//
//  main.swift
//  HotReloading
//
//  Created by John Holdsworth on 02/24/2021.
//  Copyright © 2021 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/injectiond/main.swift#8 $
//
//  Server daemon side of HotReloading simulating InjectionIII.app.
//

import Cocoa

let projectFile = CommandLine.arguments[1]
AppDelegate.ensureInterposable(project: projectFile)

// Make available MainMenu.nib and Resources to deamon
var cwdbuff = [Int8](repeating: 0, count: Int(MAXPATHLEN))
cwdbuff.withUnsafeMutableBufferPointer {
    unlink(".build/debug/Contents")
    let clone = String(cString: getcwd($0.baseAddress, $0.count))
    symlink("\(clone)/Contents", ".build/debug/Contents")
}

// launch like a normal Cocoa app
var argv = CommandLine.arguments.map { $0.withCString { strdup($0) } }

argv.withUnsafeMutableBufferPointer {
    _ = NSApplicationMain(Int32($0.count), $0.baseAddress!)
}
