//
//  UnhidingEval.swift
//
//  Created by John Holdsworth on 13/04/2021.
//
//  $Id: //depot/HotReloading/Sources/injectiond/UnhidingEval.swift#11 $
//
//  Retro-fit Unhide into InjectionIII
//
//  Unhiding is a work-around for swift giving "hidden" visibility
//  to default argument generators which are called when code uses
//  a default argument. "Hidden" visibility is somewhere between a
//  public and private declaration where the symbol doesn't become
//  part of the Swift ABI but is nevertheless required at call sites.
//  This causes problems for injection as "hidden" symbols are not
//  available outside the framework or executable that defines them.
//  So, a dynamically loading version of a source file that uses a
//  default argument cannot load due to not seeing the symbol.
//
//  This file calls a piece of C++ in Unhide.mm which scans all the object
//  files of a project looking for symbols for default argument generators
//  that are hidden and makes them public by clearing the N_PEXT flag on
//  the symbol type. Ideally this would happen between compiling and linking
//  But as it is not possible to add a build phase between compiling and
//  linking you have to build again for the object file to be linked into
//  the app executable or framework. This isn't ideal but is about as
//  good as it gets, resolving the injection of files that use default
//  arguments with the minimum disruption to the build process. This
//  file inserts this process when injection is used to keep the files
//  declaring the defaut argument patched sometimes giving an error that
//  asks the user to run the app again and retry.
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

    static let unhideQueue = DispatchQueue(label: "unhide")

    static var lastProcessed = [URL: time_t]()

    var unhidden = false

    public override func determineEnvironment(classNameOrFile: String) throws -> (URL, URL) {
        let (project, logs) =
            try super.determineEnvironment(classNameOrFile: classNameOrFile)

        if !unhidden {
            unhidden = true
            let buildDir = logs.deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Build")
            if let enumerator = FileManager.default
                    .enumerator(atPath: buildDir.path),
                let log = fopen("/tmp/unhide.log", "w") {
                Self.unhideQueue.async {
                    // linkFileLists contain the list of object files.
                    let linkFileLists = enumerator
                        .compactMap { $0 as? String }
                        .filter { $0.hasSuffix(".LinkFileList") }
                    // linkFileLists sorted to process packages
                    // first due to Edge case in Fruta example.
                    let since = Self.lastProcessed[buildDir] ?? 0
                    for path in linkFileLists.sorted(by: {
                        ($0.hasSuffix(".o.LinkFileList") ? 0 : 1) <
                        ($1.hasSuffix(".o.LinkFileList") ? 0 : 1) }) {
                        let fileURL = buildDir
                            .appendingPathComponent(path)
                        let exported = unhide_symbols(fileURL
                            .deletingPathExtension().deletingPathExtension()
                            .lastPathComponent, fileURL.path, log, since)
                        if exported != 0 {
                            let s = exported == 1 ? "" : "s"
                            print("\(APP_PREFIX)Exported \(exported) default argument\(s) in \(fileURL.lastPathComponent)")
                        }
                    }
                    Self.lastProcessed[buildDir] = time(nil)
                    unhide_reset()
                    fclose(log)
                }
            }
        }

        return (project, logs)
    }
}
