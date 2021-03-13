//
//  main.swift
//  HotReloading
//
//  Created by John Holdsworth on 02/24/2021.
//  Copyright © 2021 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/injectiond/main.swift#18 $
//
//  Server daemon side of HotReloading simulating InjectionIII.app.
//

import Cocoa
import injectiondGuts

let projectFile = CommandLine.arguments[1]
AppDelegate.ensureInterposable(project: projectFile)

// Default argument symbols need to not be "hidden"
// so files using default arguments can be injected.
if let symroot = getenv("SYMROOT"),
   let product = getenv("PRODUCT_NAME"),
   let linkFile = getenv("LINK_FILE_LIST") {
    unhide_symbols(product, linkFile)

    // Unhide of app Packages
    let buildDir = URL(fileURLWithPath:
        String(cString: symroot)).deletingLastPathComponent()
    if let enumerator = FileManager.default
            .enumerator(atPath: buildDir.path) {
        for any in enumerator {
            let file = any as! String
            if file.hasSuffix(".o.LinkFileList") {
                let fileURL = buildDir
                    .appendingPathComponent(file)
                unhide_symbols(fileURL
                    .deletingPathExtension().deletingPathExtension()
                    .lastPathComponent, fileURL.path)
            }
        }
    }
}

// launch as a normal Cocoa app
var argv = CommandLine.arguments.map { $0.withCString { strdup($0) } }

argv.withUnsafeMutableBufferPointer {
    _ = NSApplicationMain(Int32($0.count), $0.baseAddress!)
}
