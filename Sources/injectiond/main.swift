//
//  main.swift
//  HotReloading
//
//  Created by John Holdsworth on 02/24/2021.
//  Copyright © 2021 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/injectiond/main.swift#10 $
//
//  Server daemon side of HotReloading simulating InjectionIII.app.
//

import Cocoa
import injectiondGuts

let projectFile = CommandLine.arguments[1]
AppDelegate.ensureInterposable(project: projectFile)

if let product = getenv("PRODUCT_NAME"),
   let linkFile = getenv("LINK_FILE_LIST") {
    unhide_symbols(product, linkFile);
}

// launch as a normal Cocoa app
var argv = CommandLine.arguments.map { $0.withCString { strdup($0) } }

argv.withUnsafeMutableBufferPointer {
    _ = NSApplicationMain(Int32($0.count), $0.baseAddress!)
}
