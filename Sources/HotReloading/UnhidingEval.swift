//
//  UnhidingEval.swift
//
//  Created by John Holdsworth on 13/04/2021.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/UnhidingEval.swift#27 $
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

#if DEBUG || !SWIFT_PACKAGE
import Foundation
#if SWIFT_PACKAGE
import SwiftRegex
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
    var buildDir: URL?

    public override func determineEnvironment(classNameOrFile: String) throws -> (URL, URL) {
        let (project, logs) =
            try super.determineEnvironment(classNameOrFile: classNameOrFile)
        buildDir = logs.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Build")
        if legacyUnhide {
            startUnhide()
        }
        return (project, logs)
    }

    override func startUnhide() {
        if !unhidden, let buildDir = buildDir {
            unhidden = true
            Self.unhideQueue.async {
                if let enumerator = FileManager.default
                    .enumerator(atPath: buildDir.path),
                let log = fopen("/tmp/unhide.log", "w") {
                    // linkFileLists contain the list of object files.
                    var linkFileLists = [String](), frameworks = [String]()
                    for path in enumerator.compactMap({ $0 as? String }) {
                        if path.hasSuffix(".LinkFileList") {
                            linkFileLists.append(path)
                        } else if path.hasSuffix(".framework") {
                            frameworks.append(path)
                        }
                    }
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

                    #if false // never implemented
                    for framework in frameworks {
                        let fileURL = buildDir
                            .appendingPathComponent(framework)
                        let frameworkName = fileURL
                            .deletingPathExtension().lastPathComponent
                        let exported = unhide_framework(fileURL
                            .appendingPathComponent(frameworkName).path, log)
                        if exported != 0 {
                            let s = exported == 1 ? "" : "s"
                            print("\(APP_PREFIX)Exported \(exported) symbol\(s) in framework \(frameworkName)")
                        }
                    }
                    #endif

                    Self.lastProcessed[buildDir] = time(nil)
                    unhide_reset()
                    fclose(log)
                }
            }
        }
    }

    // This was required for Xcode13's new "optimisation" to compile
    // more than one primary file in a single compiler invocation.
    override func xcode13Fix(sourceFile: String,
                             compileCommand: inout String) -> String {
        let sourceName = URL(fileURLWithPath: sourceFile)
            .deletingPathExtension().lastPathComponent.escaping().lowercased()
        let hasFileList = compileCommand.contains(" -filelist ")
        var nPrimaries = 0
        // ensure there is only ever one -primary-file argument and object file
        // avoids shuffling of object files due to how the compiler is coded
        compileCommand[#" -primary-file (\#(Self.filePathRegex+Self.fileNameRegex))"#] = {
            (groups: [String], stop) -> String in
//            debug("PF: \(sourceName) \(groups)")
            nPrimaries += 1
            return groups[2].lowercased() == sourceName ||
                   groups[3].lowercased() == sourceName ?
                groups[0] : hasFileList ? "" : " "+groups[1]
        }
//        // Xcode 13 can have multiple primary files but implements default
//        // arguments in a way that no longer requires they be "unhidden".
//        if nPrimaries < 2 {
//            startUnhide()
//        }
        // The number of these options must match the number of -primary-file arguments
        // which has just been changed to only ever be one so, strip them out
        let toRemove = #" -(serialize-diagnostics|emit-(module(-doc|-source-info)?|(reference-)?dependencies|const-values)|index-unit-output)-path "#
        compileCommand = compileCommand
            .replacingOccurrences(of: toRemove + Self.argumentRegex,
                                  with: "", options: .regularExpression)
        debug("Uniqued command:", compileCommand)
        // Replace path(s) of all object files to a single one
        return super.xcode13Fix(sourceFile: sourceFile,
                                compileCommand: &compileCommand)
    }

    /// Per-object file version of unhiding on injection to export some symbols
    /// - Parameters:
    ///   - executable: Path to app executable to extract module name
    ///   - objcClassRefs: Array to accumulate class referrences
    ///   - descriptorRefs: Array to accumulate "l.got" references to "fixup"
    override func createUnhider(executable: String, _ objcClassRefs: NSMutableArray,
                                _ descriptorRefs: NSMutableArray) {
        let appModule = URL(fileURLWithPath: executable)
            .lastPathComponent.replacingOccurrences(of: " ", with: "_")
        let appPrefix = "$s\(appModule.count)\(appModule)"
        objectUnhider = { object_file in
            let logfile = "/tmp/unhide_object.log"
            if let log = fopen(logfile, "w") {
                setbuf(log, nil)
                objcClassRefs.removeAllObjects()
                descriptorRefs.removeAllObjects()
                unhide_object(object_file, appPrefix, log,
                              objcClassRefs, descriptorRefs)
//                self.log("Unhidden: \(object_file) -- \(appPrefix) -- \(self.objcClassRefs)")
            } else {
//                self.log("Could not log to \(logfile)")
            }
        }
    }

    // Non-essential functionality moved here...
    @objc public func rebuild(storyboard: String) throws {
        let (_, logsDir) = try determineEnvironment(classNameOrFile: storyboard)

        injectionNumber += 1

        // messy but fast
        guard shell(command: """
            # search through build logs, most recent first
            cd "\(logsDir.path.escaping("$"))" &&
            for log in `ls -t *.xcactivitylog`; do
                #echo "Scanning $log"
                /usr/bin/env perl <(cat <<'PERL'
                    use English;
                    use strict;

                    # line separator in Xcode logs
                    $INPUT_RECORD_SEPARATOR = "\\r";

                    # format is gzip
                    open GUNZIP, "/usr/bin/gunzip <\\"$ARGV[0]\\" 2>/dev/null |" or die;

                    # grep the log until to find codesigning for product path
                    my $realPath;
                    while (defined (my $line = <GUNZIP>)) {
                        if ($line =~ /^\\s*cd /) {
                            $realPath = $line;
                        }
                        elsif (my ($product) = $line =~ m@/usr/bin/ibtool.*? --link (([^\\ ]+\\\\ )*\\S+\\.app)@o) {
                            print $product;
                            exit 0;
                        }
                    }

                    # class/file not found
                    exit 1;
            PERL
                ) "$log" >"\(tmpfile).sh" && exit 0
            done
            exit 1;
            """) else {
            throw scriptError("Locating storyboard compile")
        }

        guard let resources = try? String(contentsOfFile: "\(tmpfile).sh")
            .trimmingCharacters(in: .whitespaces) else {
            throw scriptError("Locating product")
        }

        guard shell(command: """
            (cd "\(resources.unescape().escaping("$"))" && for i in 1 2 3 4 5; \
            do if (find . -name '*.nib' -a -newer "\(storyboard)" | \
            grep .nib >/dev/null); then break; fi; sleep 1; done; \
            while (ps auxww | grep -v grep | grep "/ibtool " >/dev/null); do sleep 1; done; \
            for i in `find . -name '*.nib'`; do cp -rf "$i" "\(
                        Bundle.main.bundlePath)/$i"; done >"\(logfile)" 2>&1)
            """) else {
                throw scriptError("Re-compilation")
        }

        _ = evalError("Copied \(storyboard)")
    }

    // Assorted bazel code moved out of SwiftEval.swift
    override func bazelLink(in projectRoot: String, since sourceFile: String,
                   compileCommand: String) throws -> String {
        guard var objects = bazelFiles(under: projectRoot, where: """
            -newer "\(sourceFile)" -a -name '*.o' | \
            egrep '(_swift_incremental|_objs)/' | grep -v /external/
            """) else {
            throw evalError("Finding Objects failed. Did you actually make a change to \(sourceFile) and does it compile? InjectionIII does not support whole module optimization. (check logfile: \(logfile))")
        }

        debug(bazelLight, projectRoot, objects)
        // precendence to incrementally compiled
        let incremental = objects.filter({ $0.contains("_swift_incremental") })
        if incremental.count > 0 {
            objects = incremental
        }

        #if true
        // With WMO, which modifies all object files
        // we need a way to filter them down to that
        // of the source file and its related module
        // library to provide shared "hidden" symbols.
        // We use the related Swift "output_file_map"
        // for the module name to include its library.
        if objects.count > 1 {
            let objectSet = Set(objects)
            if let maps  = bazelFiles(under: projectRoot,
                                      where: "-name '*output_file_map*.json'") {
                let relativePath = sourceFile .replacingOccurrences(
                    of: projectRoot+"/", with: "")
                for map in maps {
                    if let data = try? Data(contentsOf: URL(
                        fileURLWithPath: projectRoot)
                        .appendingPathComponent(map)),
                       let json = try? JSONSerialization.jsonObject(
                        with: data, options: []) as? [String: Any],
                       let info = json[relativePath] as? [String: String] {
                        if let object = info["object"],
                           objectSet.contains(object) {
                            objects = [object]
                            if let module: String =
                                map[#"(\w+)\.output_file_map"#] {
                                for lib in bazelFiles(under: projectRoot,
                                    where: "-name 'lib\(module).a'") ?? [] {
                                    moduleLibraries.insert(lib)
                                }
                            }
                            break
                        }
                    }
                }
            } else {
                _ = evalError("Error reading maps")
            }
        }
        #endif

        objects += moduleLibraries
        debug(objects)

        try link(dylib: "\(tmpfile).dylib", compileCommand: compileCommand,
                 contents: objects.map({ "\"\($0)\""}).joined(separator: " "),
                 cd: projectRoot)
        return tmpfile
    }

    func bazelFiles(under projectRoot: String, where clause:  String,
                    ext: String = "files") -> [String]? {
        let list = "\(tmpfile).\(ext)"
        if shell(command: """
            cd "\(projectRoot)" && \
            find bazel-out/* \(clause) >"\(list)" 2>>\"\(logfile)\"
            """), let files = (try? String(contentsOfFile: list))?
            .components(separatedBy: "\n").dropLast() {
            return Array(files)
        }
        return nil
    }

    override func bazelLight(projectRoot: String, recompile sourceFile: String) throws -> String? {
        let relativePath = sourceFile.replacingOccurrences(of:
            projectRoot+"/", with: "")
        let bazelRulesSwift = projectRoot +
            "/bazel-out/../external/build_bazel_rules_swift"
        let paramsScanner = tmpDir + "/bazel.pl"
        debug(projectRoot, relativePath, bazelRulesSwift, paramsScanner)

        if !sourceFile.hasSuffix(".swift") {
            throw evalError("Only Swift sources can be standalone injected with bazel")
        }

        try #"""
            use JSON::PP;
            use English;
            use strict;

            my ($params, $relative) = @ARGV;
            my $args = join('', (IO::File->new( "< $params" )
                or die "Could not open response '$params'")->getlines());
            my ($filemap) = $args =~ /"-output-file-map"\n"([^"]+)"/;
            my $file_handle = IO::File->new( "< $filemap" )
                or die "Could not open filemap '$filemap'";
            my $json_text = join'', $file_handle->getlines();
            my $json_map = decode_json( $json_text, { utf8  => 1 } );

            if (my $info = $json_map->{$relative}) {
                $args =~ s/"-(emit-(module|objc-header)-path"\n"[^"]+)"\n//g;
                my $paramscopy = "$params.copy";
                my $paramsfile = IO::File->new("> $paramscopy");
                binmode $paramsfile, ':utf8';
                $paramsfile->print($args);
                $paramsfile->close();
                print "$paramscopy\n$info->{object}\n";
                exit 0;
            }
            # source file not found
            exit 1;
            """#.write(toFile: paramsScanner,
                       atomically: false, encoding: .utf8)

        let errfile = "\(tmpfile).err"
        guard shell(command: """
            # search through bazel args, most recent first
            cd "\(bazelRulesSwift)" 2>"\(errfile)" &&
            grep module_name_ tools/worker/swift_runner.h >/dev/null 2>>"\(errfile)" ||
            (git apply -v <<'BAZEL_PATCH' 2>>"\(errfile)" && echo "⚠️ bazel patched, restart app" >>"\(errfile)" && exit 1) &&
            diff --git a/tools/worker/swift_runner.cc b/tools/worker/swift_runner.cc
            index 535dad0..19e1a6d 100644
            --- a/tools/worker/swift_runner.cc
            +++ b/tools/worker/swift_runner.cc
            @@ -369,6 +369,11 @@ std::vector<std::string> SwiftRunner::ParseArguments(Iterator itr) {
                     arg = *it;
                     output_file_map_path_ = arg;
                     out_args.push_back(arg);
            +      } else if (arg == "-module-name") {
            +        ++it;
            +        arg = *it;
            +        module_name_ = arg;
            +        out_args.push_back(arg);
                   } else if (arg == "-index-store-path") {
                     ++it;
                     arg = *it;
            @@ -410,12 +415,28 @@ std::vector<std::string> SwiftRunner::ProcessArguments(
                 ++it;
               }

            +  auto copy = "/tmp/bazel_"+module_name_+".params";
            +  unlink(copy.c_str());
               if (force_response_file_) {
                 // Write the processed args to the response file, and push the path to that
                 // file (preceded by '@') onto the arg list being returned.
                 auto new_file = WriteResponseFile(response_file_args);
                 new_args.push_back("@" + new_file->GetPath());
            +
            +    // patch to retain swiftc arguments file
            +    link(new_file->GetPath().c_str(), copy.c_str());
                 temp_files_.push_back(std::move(new_file));
            +  } else if (FILE *fp = fopen("/tmp/forced_params.txt", "w+")) {
            +    // alternate patch to capture arguments file
            +    for (auto &a : args_destination) {
            +      const char *carg = a.c_str();
            +      fprintf(fp, "%s\\n", carg);
            +      if (carg[0] != '@')
            +          continue;
            +      link(carg+1, copy.c_str());
            +      fprintf(fp, "Linked %s to %s\\n", copy.c_str(), carg+1);
            +    }
            +    fclose(fp);
               }

               return new_args;
            diff --git a/tools/worker/swift_runner.h b/tools/worker/swift_runner.h
            index 952c593..35cf055 100644
            --- a/tools/worker/swift_runner.h
            +++ b/tools/worker/swift_runner.h
            @@ -153,6 +153,9 @@ class SwiftRunner {
               // The index store path argument passed to the runner
               std::string index_store_path_;

            +  // Swift modue name from -module-name
            +  std::string module_name_ = "Unknown";
            +
               // The path of the global index store  when using
               // swift.use_global_index_store. When set, this is passed to `swiftc` as the
               // `-index-store-path`. After running `swiftc` `index-import` copies relevant
            BAZEL_PATCH

            cd "\(projectRoot)" 2>>"\(errfile)" &&
            for params in `ls -t /tmp/bazel_*.params 2>>"\(errfile)"`; do
                #echo "Scanning $params"
                /usr/bin/env perl "\(paramsScanner)" "$params" "\(relativePath)" \
                >"\(tmpfile).sh" 2>>"\(errfile)" && exit 0
            done
            exit 1;
            """), let returned = (try? String(contentsOfFile: "\(tmpfile).sh"))?
                                        .components(separatedBy: "\n") else {
            if let log = try? String(contentsOfFile: errfile), log != "" {
                throw evalError(log.contains("ls: /tmp/bazel_*.params") ? """
                    \(log)Response files not available (see: \(cmdfile))
                    Edit and save a swift source file and restart app.
                    """ : """
                    Locating response file failed (see: \(cmdfile))
                    \(log)
                    """)
            }
            return nil
        }

        let params = returned[0]
        _ = evalError("Compiling using parameters from \(params)")

        guard shell(command: """
                cd "\(projectRoot)" && \
                chmod +w `find bazel-out/* -name '*.o'`; \
                xcrun swiftc @\(params) >\"\(logfile)\" 2>&1
                """) || shell(command: """
                cd `readlink "\(projectRoot)/bazel-out"`/.. && \
                chmod +w `find bazel-out/* -name '*.o'`; \
                xcrun swiftc @\(params) >>\"\(logfile)\" 2>&1
                """),
              let compileCommand = try? String(contentsOfFile: params) else {
            throw scriptError("Recompiling")
        }

        return try bazelLink(in: projectRoot, since: sourceFile,
                             compileCommand: compileCommand)
    }

}
#endif
