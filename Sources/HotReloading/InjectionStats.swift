//
//  InjectionStats.swift
//  
//  Created by John Holdsworth on 26/10/2022.
//  Copyright © 2022 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/InjectionStats.swift#1 $
//

import Foundation
import SwiftTrace
#if SWIFT_PACKAGE
import SwiftTraceGuts
#endif

extension SwiftInjection {

    @objc public class func dumpStats(top: Int) {
        let invocationCounts =  SwiftTrace.invocationCounts()
        for (method, elapsed) in SwiftTrace.sortedElapsedTimes(onlyFirst: top) {
            print("\(String(format: "%.1f", elapsed*1000.0))ms/\(invocationCounts[method] ?? 0)\t\(method)")
        }
    }

    @objc public class func callOrder() -> [String] {
        return SwiftTrace.callOrder().map { $0.signature }
    }

    @objc public class func fileOrder() {
        let builder = SwiftEval.sharedInstance()
        let signatures = callOrder()

        guard let projectRoot = builder.projectFile.flatMap({
                URL(fileURLWithPath: $0).deletingLastPathComponent().path+"/"
            }),
            let (_, logsDir) =
                try? builder.determineEnvironment(classNameOrFile: "") else {
            log("File ordering not available.")
            return
        }

        let tmpfile = builder.tmpDir+"/eval101"
        var found = false

        SwiftEval.uniqueTypeNames(signatures: signatures) { typeName in
            if !typeName.contains("("), let (_, foundSourceFile) =
                try? builder.findCompileCommand(logsDir: logsDir,
                    classNameOrFile: typeName, tmpfile: tmpfile) {
                print(foundSourceFile
                        .replacingOccurrences(of: projectRoot, with: ""))
                found = true
            }
        }

        if !found {
            log("Do you have the right project selected?")
        }
    }

    @objc public class func packageNames() -> [String] {
        var packages = Set<String>()
        for suffix in SwiftTrace.traceableFunctionSuffixes {
            findSwiftSymbols(Bundle.main.executablePath!, suffix) {
                (_, symname: UnsafePointer<Int8>, _, _) in
                if let sym = SwiftMeta.demangle(symbol: String(cString: symname)),
                    !sym.hasPrefix("(extension in "),
                    let endPackage = sym.firstIndex(of: ".") {
                    packages.insert(sym[..<(endPackage+0)])
                }
            }
        }
        return Array(packages)
    }

    @objc public class func objectCounts() {
        for (className, count) in SwiftTrace.liveObjects
            .map({(_typeName(autoBitCast($0.key)), $0.value.count)})
            .sorted(by: {$0.0 < $1.0}) {
            print("\(count)\t\(className)")
        }
    }
}
