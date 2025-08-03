//
//  AppDelegate.swift
//  InjectionIII
//
//  Created by John Holdsworth on 06/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/injectiond/AppDelegate.swift#82 $
//

import Cocoa
#if SWIFT_PACKAGE
import injectiondGuts
import RemoteUI

// nib compatability...
import WebKit
@objc(WebView)
class WebView : WKWebView {}
#endif

let XcodeBundleID = "com.apple.dt.Xcode"
var appDelegate: AppDelegate!

enum InjectionState: String {
    case ok = "OK"
    case idle = "Idle"
    case busy = "Busy"
    case error = "Error"
    case ready = "Ready"
}

@objc(AppDelegate)
class AppDelegate : NSObject, NSApplicationDelegate {

    @IBOutlet var window: NSWindow!
    @IBOutlet weak var enableWatcher: NSMenuItem!
    @IBOutlet weak var traceItem: NSMenuItem!
    @IBOutlet weak var traceInclude: NSTextField!
    @IBOutlet weak var traceExclude: NSTextField!
    @IBOutlet weak var traceFilters: NSWindow!
    @IBOutlet weak var statusMenu: NSMenu!
    @IBOutlet weak var startItem: NSMenuItem!
    @IBOutlet weak var xprobeItem: NSMenuItem!
    @IBOutlet weak var enabledTDDItem: NSMenuItem!
    @IBOutlet weak var enableVaccineItem: NSMenuItem!
    @IBOutlet weak var windowItem: NSMenuItem!
    @IBOutlet weak var remoteItem: NSMenuItem!
    @IBOutlet weak var updateItem: NSMenuItem!
    @IBOutlet weak var frontItem: NSMenuItem!
    @IBOutlet weak var feedbackItem: NSMenuItem!
    @IBOutlet weak var lookupItem: NSMenuItem!
    @IBOutlet weak var sponsorItem: NSMenuItem!
    @IBOutlet var statusItem: NSStatusItem!

    var watchedDirectories = Set<String>()
    weak var lastConnection: InjectionServer?
    var selectedProject: String?
    let openProject = NSLocalizedString("Select Project Directory",
                                        tableName: "Project Directory",
                                        comment: "Project Directory")

    @objc let defaults = UserDefaults.standard
    var defaultsMap: [NSMenuItem: String]!

    lazy var isSandboxed =
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    var runningXcodeDevURL: URL? =
        NSRunningApplication.runningApplications(
            withBundleIdentifier: XcodeBundleID).first?
            .bundleURL?.appendingPathComponent("Contents/Developer")
    var derivedLogs: String?

    /// Bringing in InjectionNext  patching
    static var ui: AppDelegate { return appDelegate }
    static func alreadyWatching(_ projectRoot: String) -> String? {
        return appDelegate.watchedDirectories.first { projectRoot.hasPrefix($0) }
    }
    @IBOutlet weak var deviceTesting: NSMenuItem?
    @IBOutlet weak var selectXcodeItem: NSMenuItem?
    @IBOutlet weak var patchCompilerItem: NSMenuItem?
    @IBOutlet weak var librariesField: NSTextField!
    var codeSigningID: String { selectedProject.flatMap {
        defaults.string(forKey: $0) } ?? "-" }
    func watch(path: String) {
        watchedDirectories.insert(path)
        lastConnection?.watchDirectory(path)
    }
    #if !SWIFT_PACKAGE
    @IBAction func prepareXcode(_ sender: NSMenuItem) {
        let open = NSOpenPanel()
        open.prompt = "Select Xcode to Patch"
        open.directoryURL = URL(fileURLWithPath: Defaults.xcodePath)
        open.canChooseDirectories = false
        open.canChooseFiles = true
        if open.runModal() == .OK, let path = open.url?.path {
            selectXcodeItem?.toolTip = path
            Defaults.xcodeDefault = path
            patchCompiler(sender)
        }
    }
    #endif

    @objc func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Insert code here to initialize your application
        appDelegate = self

        let statusBar = NSStatusBar.system
        statusItem = statusBar.statusItem(withLength: statusBar.thickness)
        statusItem.highlightMode = true
        statusItem.menu = statusMenu
        statusItem.isEnabled = true
        statusItem.title = ""

        if isSandboxed {
//            sponsorItem.isHidden = true
            updateItem.isHidden = true
        } else if let platform = getenv("PLATFORM_NAME"),
           strcmp(platform, "iphonesimulator") == 0 {
            DeviceServer.startServer(HOTRELOADING_PORT)
        } else if let unlock = defaults.string(forKey: UserDefaultsUnlock) {
            let deviceInform = "deviceInform"
            var openPort = ""
            if unlock == "any" {
                if defaults.string(forKey: deviceInform) == nil {
                    let alert: NSAlert = NSAlert()
                    alert.messageText = "Device Injection"
                    alert.informativeText = """
                        This release supports injection on a real device \
                        as well as in the simulator. In order to do this it \
                        needs to open a port to receive socket connections \
                        from a device which will provoke an OS warning if \
                        your Mac's firewall is enabled. Decline the prompt \
                        if you don't intend to use this feature.
                        """
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "OK")
                    _ = alert.runModal()
                    defaults.set("Informed", forKey: deviceInform)
                }
                openPort = "*"
                setenv("XPROBE_ANY", "1", 1)
                DeviceServer.multicastServe(HOTRELOADING_MULTICAST,
                                            port: HOTRELOADING_PORT)
            }
            DeviceServer.startServer(openPort+HOTRELOADING_PORT)
        }

        #if !SWIFT_PACKAGE
        InjectionServer.startServer(INJECTION_ADDRESS)
        #endif

        defaultsMap = [
            frontItem: UserDefaultsOrderFront,
            enabledTDDItem: UserDefaultsTDDEnabled,
            enableVaccineItem: UserDefaultsVaccineEnabled,
            feedbackItem: UserDefaultsFeedback,
            lookupItem: UserDefaultsLookup,
            remoteItem: UserDefaultsRemote
        ]

        for (menuItem, defaultsKey) in defaultsMap {
            menuItem.state = defaults.bool(forKey: defaultsKey) ? .on : .off
        }

        #if SWIFT_PACKAGE
        if remoteItem.state == .on {
            remoteItem.state = .off
            startRemote(remoteItem)
        }
        #else
        if !isSandboxed && defaults.value(forKey: UserDefaultsFeed) != nil {
            selectXcodeItem?.isHidden = false
            selectXcodeItem?.toolTip = Defaults.xcodePath
            selectXcodeItem?.state =
                updatePatchUnpatch() == .patched ? .on : .off
        }
        #endif

        setMenuIcon(.idle)
        versionSpecific()
    }

    func versionSpecific() {
        #if SWIFT_PACKAGE
        let appName = "Hot Reloading"
        statusMenu.item(withTitle: "Open Project")?.isHidden = true
        var arguments = CommandLine.arguments.dropFirst()
        let projectURL = URL(fileURLWithPath: arguments.removeFirst())
        let projectRoot = projectURL.deletingLastPathComponent()
        AppDelegate.ensureInterposable(project: projectURL.path)
        NSDocumentController.shared.noteNewRecentDocumentURL(projectRoot)
        derivedLogs = arguments.removeFirst()

        selectedProject = projectURL.path
        appDelegate.watchedDirectories = [projectRoot.path]
        for dir in arguments where !dir.hasPrefix(projectRoot.path) {
            appDelegate.watchedDirectories.insert(dir)
        }
        #else
        let appName = "InjectionIII"
        DDHotKeyCenter.shared()?
            .registerHotKey(withKeyCode: UInt16(kVK_ANSI_Equal),
               modifierFlags: NSEvent.ModifierFlags.control.rawValue,
               target:self, action:#selector(autoInject(_:)), object:nil)

        NSApp.servicesProvider = self
        if let projectFile = defaults
            .string(forKey: UserDefaultsProjectFile) {
            // Received project file from command line option.
            _ = self.application(NSApp, openFile:
                URL(fileURLWithPath: projectFile).deletingLastPathComponent().path)
        } else if let lastWatched = defaults.string(forKey: UserDefaultsLastWatched) {
            _ = self.application(NSApp, openFile: lastWatched)
        } else {
            NSUpdateDynamicServices()
        }

        let nextUpdateCheck = defaults.double(forKey: UserDefaultsUpdateCheck)
        if !isSandboxed && nextUpdateCheck != 0.0 {
            updateItem.state = .on
            if Date.timeIntervalSinceReferenceDate > nextUpdateCheck {
                self.updateCheck(nil)
            }
        }
        #endif
        statusItem.title = appName
        if let quit = statusMenu.item(at: statusMenu.items.count-1) {
            quit.title = "Quit "+appName
            #if !SWIFT_PACKAGE
            if let build = Bundle.main
                .infoDictionary?[kCFBundleVersionKey as String] {
                quit.toolTip = "Quit (build #\(build))"
            }
            #endif
        }
    }

    func application(_ theApplication: NSApplication, openFile filename: String) -> Bool {
        #if SWIFT_PACKAGE
        return false
        #else
        guard filename != Bundle.main.bundlePath,
            let url = resolve(path: filename),
            let fileList = try? FileManager.default
               .contentsOfDirectory(atPath: url.path) else {
            return false
        }

        if url.pathExtension == "xcworkspace" ||
            url.pathExtension == "xcodeproj" {
            let alert: NSAlert = NSAlert()
            alert.messageText = "InjectionIII"
            alert.informativeText = """
                Please select the project directory to watch \
                for file changes under, not the project file.
                """
            alert.alertStyle = NSAlert.Style.warning
            alert.addButton(withTitle: "Sorry")
            _ = alert.runModal()
            return false
        }

        let projectFiles = SwiftEval.projects(in: fileList)

        selectedProject = nil
        if url.path.hasSuffix(".swiftpm") {
            selectedProject = url.path
            let pkg = url.appendingPathComponent("Package.swift")
            if let manifest = try? String(contentsOf: pkg),
                !manifest.contains("-interposable") {
                var modified = manifest
                modified[#"""
                    (
                            \)
                        ]
                    \)
                    )\Z
                    """#] = """
                    ,
                                linkerSettings: [
                                    .unsafeFlags(["-Xlinker", "-interposable"],
                                                 .when(configuration: .debug))
                                ]$1
                    """
                if modified != manifest {
                    do {
                        try modified.write(to: pkg, atomically: true, encoding: .utf8)
                        let alert: NSAlert = NSAlert()
                        alert.messageText = "InjectionIII"
                        alert.informativeText = """
                            InjectionIII has patched Package.swift to include the -interposable linker flag. Use Menu item "Prepare Project" to complete conversion.
                            """
                        alert.alertStyle = NSAlert.Style.warning
                        alert.addButton(withTitle: "OK")
                        _ = alert.runModal()
                    } catch {
                    }
                }
            }
        } else if projectFiles == nil || projectFiles!.count > 1 {
            for lastProjectFile in [UserDefaultsProjectFile,
                                    UserDefaultsLastProject]
                .compactMap({ defaults.string(forKey: $0) }) {
                for project in projectFiles ?? [] {
                    if selectedProject == nil,
                        url.appendingPathComponent(project)
                            .path == lastProjectFile {
                        selectedProject = lastProjectFile
                    }
                }
            }
            if selectedProject == nil {
                let open = NSOpenPanel()
                open.prompt = "Select Project File"
                open.directoryURL = url
                open.canChooseDirectories = false
                open.canChooseFiles = true
                // open.showsHiddenFiles = TRUE;
                if open.runModal() == .OK,
                    let url = open.url {
                    selectedProject = url.path
                }
            }
        } else if projectFiles != nil {
            selectedProject = url
                .appendingPathComponent(projectFiles![0]).path
        }

        guard let projectFile = selectedProject else {
            let alert: NSAlert = NSAlert()
            alert.messageText = "InjectionIII"
            alert.informativeText = "Please select a directory with either a .xcworkspace or .xcodeproj file, below which, are the files you wish to inject."
            alert.alertStyle = NSAlert.Style.warning
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
            return false
        }

        watchedDirectories.removeAll()
        watchedDirectories.insert(url.path)
        if let alsoWatch = defaults.string(forKey: "addDirectory"),
            let resolved = resolve(path: alsoWatch) {
            watchedDirectories.insert(resolved.path)
        }
        lastConnection?.setProject(projectFile)
//            AppDelegate.ensureInterposable(project: selectedProject!)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        statusItem.menu?.item(withTitle: "Open Recent")?.toolTip = url.path
//            let projectName = URL(fileURLWithPath: projectFile)
//                .deletingPathExtension().lastPathComponent
//            traceInclude.stringValue = projectName
//            updateTraceInclude(nil)
        defaults.set(projectFile, forKey: UserDefaultsLastProject)
        defaults.set(url.path, forKey: UserDefaultsLastWatched)
        return true
        #endif
    }

    func persist(url: URL) {
        if !isSandboxed { return }
        var bookmarks = defaults.value(forKey: UserDefaultsBookmarks)
            as? [String : Data] ?? [String: Data]()
        do {
            bookmarks[url.path] =
                try url.bookmarkData(options: [.withSecurityScope,
                                               .securityScopeAllowOnlyReadAccess],
                                     includingResourceValuesForKeys: [],
                                     relativeTo: nil)
            defaults.set(bookmarks, forKey: UserDefaultsBookmarks)
        } catch {
            _ = InjectionServer.error("Bookmarking failed for \(url), \(error)")
        }
    }

    func resolve(path: String) -> URL? {
        var isStale: Bool = false
        if !isSandboxed, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        } else if let bookmarks =
            defaults.value(forKey: UserDefaultsBookmarks) as? [String : Data],
            let bookmark = bookmarks[path],
            let resolved = try? URL(resolvingBookmarkData: bookmark,
                           options: .withSecurityScope,
                           relativeTo: nil,
                           bookmarkDataIsStale: &isStale), !isStale {
            _ = resolved.startAccessingSecurityScopedResource()
            return resolved
        } else {
            let open = NSOpenPanel()
            open.prompt = openProject
            if path != "" {
                open.directoryURL = URL(fileURLWithPath: path)
            }
            open.canChooseDirectories = true
            open.canChooseFiles = true
            // open.showsHiddenFiles = TRUE;
            if open.runModal() == .OK,
                let url = open.url {
                persist(url: url)
                return url
            }
        }

        return nil
    }

    func setMenuIcon(_ state: InjectionState) {
        DispatchQueue.main.async {
            let tiffName = "Injection"+state.rawValue
            if let path = Bundle.main.path(forResource: tiffName, ofType: "tif"),
                let image = NSImage(contentsOfFile: path) {
    //            image.template = TRUE;
                self.statusItem.image = image
                self.statusItem.alternateImage = self.statusItem.image
                let appRunning = tiffName != "InjectionIdle"
                self.startItem.isEnabled = appRunning
                self.xprobeItem.isEnabled = appRunning
                for item in self.traceItem.submenu!.items {
                    if item.tag == 0 {
                        item.isEnabled = appRunning
                        if !appRunning {
                            item.state = .off
                        }
                    }
                }
            }
        }
    }

    @IBAction func openProject(_ sender: Any) {
        _ = application(NSApp, openFile: "")
    }

    @IBAction func addDirectory(_ sender: Any) {
        let open = NSOpenPanel()
        open.prompt = openProject
        open.allowsMultipleSelection = true
        open.canChooseDirectories = true
        open.canChooseFiles = false
        if open.runModal() == .OK {
            for url in open.urls {
                watch(path: url.path)
                persist(url: url)
            }
        }
    }

    func setFrameworks(_ frameworks: String, menuTitle: String) {
        DispatchQueue.main.async {
            guard let frameworksMenu = self.traceItem.submenu?
                    .item(withTitle: menuTitle)?.submenu else { return }
            frameworksMenu.removeAllItems()
            for framework in frameworks
                .components(separatedBy: FRAMEWORK_DELIMITER).sorted()
                where framework != "" {
                frameworksMenu.addItem(withTitle: framework, action:
                    #selector(self.traceFramework(_:)), keyEquivalent: "")
                    .target = self
            }
        }
    }

    @objc func traceFramework(_ sender: NSMenuItem) {
        toggleState(sender)
        lastConnection?.sendCommand(.traceFramework, with: sender.title)
    }

    @IBAction func toggleTDD(_ sender: NSMenuItem) {
        toggleState(sender)
    }

    @IBAction func toggleVaccine(_ sender: NSMenuItem) {
        toggleState(sender)
        lastConnection?.sendCommand(.vaccineSettingChanged, with:vaccineConfiguration())
    }

    @IBAction func toggleFeedback(_ sender: NSMenuItem?) {
        sender.flatMap { toggleState($0) }
        lastConnection?.sendCommand(.feedback,
                                    with: feedbackItem.state == .on ? "1" : "0")
    }

    @IBAction func toggleLookup(_ sender: NSMenuItem?) {
        sender.flatMap { toggleState($0) }
        lastConnection?.sendCommand(.lookup,
                                    with: lookupItem.state == .on ? "1" : "0")
    }

    @IBAction func startRemote(_ sender: NSMenuItem) {
        #if SWIFT_PACKAGE
        remoteItem.state = .off
        toggleState(remoteItem)
        RMWindowController.startServer(sender)
        #endif
    }

    @IBAction func stopRemote(_ sender: NSMenuItem) {
        #if SWIFT_PACKAGE
        remoteItem.state = .on
        toggleState(remoteItem)
        RMWindowController.stopServer()
        #endif
    }

    @IBAction func traceApp(_ sender: NSMenuItem) {
        toggleState(sender)
        lastConnection?.sendCommand(sender.state == .on ?
            .trace : .untrace, with: nil)
    }

    @IBAction func traceUIApp(_ sender: NSMenuItem) {
        toggleState(sender)
        lastConnection?.sendCommand(.traceUI, with: nil)
    }

    @IBAction func traceUIKit(_ sender: NSMenuItem) {
        toggleState(sender)
        lastConnection?.sendCommand(.traceUIKit, with: nil)
    }

    @IBAction func traceSwiftUI(_ sender: NSMenuItem) {
        toggleState(sender)
        lastConnection?.sendCommand(.traceSwiftUI, with: nil)
    }

    @IBAction func profileSwiftUI(_ sender: NSMenuItem) {
        toggleState(sender)
        lastConnection?.sendCommand(.profileUI, with: nil)
    }

    @IBAction func traceStats(_ sender: NSMenuItem) {
        lastConnection?.sendCommand(.stats, with: nil)
    }

    @IBAction func remmoveTraces(_ sender: NSMenuItem?) {
        lastConnection?.sendCommand(.uninterpose, with: nil)
    }

    @IBAction func showTraceFilters(_ sender: NSMenuItem?) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        traceFilters.makeKeyAndOrderFront(sender)
    }

    @IBAction func updateTraceInclude(_ sender: NSButton?) {
        guard traceInclude.stringValue != "" || sender != nil else { return }
        update(filter: sender == nil ? .quietInclude : .include,
               textField: traceInclude)
    }

    @IBAction func updateTraceExclude(_ sender: NSButton?) {
        guard traceExclude.stringValue != "" || sender != nil else { return }
        update(filter: .exclude, textField: traceExclude)
    }

    func update(filter: InjectionCommand, textField: NSTextField) {
        let regex = textField.stringValue
        do {
            if regex != "" {
                _ = try NSRegularExpression(pattern: regex, options: [])
            }
            lastConnection?.sendCommand(filter, with: regex)
        } catch {
            let alert = NSAlert(error: error)
            alert.informativeText = "Invalid regular expression syntax '\(regex)' for filter. Characters [](){}|?*+\\ and . have special meanings. Type: man re_syntax, in the terminal."
            alert.runModal()
            textField.becomeFirstResponder()
            showTraceFilters(nil)
        }
    }

    func vaccineConfiguration() -> String {
        let vaccineSetting = UserDefaults.standard.bool(forKey: UserDefaultsVaccineEnabled)
        let dictionary = [UserDefaultsVaccineEnabled: vaccineSetting]
        let jsonData = try! JSONSerialization
            .data(withJSONObject: dictionary, options:[])
        let configuration = String(data: jsonData, encoding: .utf8)!
        return configuration
    }

    @IBAction func toggleState(_ sender: NSMenuItem) {
        sender.state = sender.state == .on ? .off : .on
        if let defaultsKey = defaultsMap[sender] {
            defaults.set(sender.state, forKey: defaultsKey)
        }
    }

    @IBAction func autoInject(_ sender: NSMenuItem) {
        lastConnection?.injectPending()
//    #if false
//        NSError *error = nil;
//        // Install helper tool
//        if ([HelperInstaller isInstalled] == NO) {
//    #pragma clang diagnostic push
//    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
//            if ([[NSAlert alertWithMessageText:@"Injection Helper"
//                                 defaultButton:@"OK" alternateButton:@"Cancel" otherButton:nil
//                     informativeTextWithFormat:@"InjectionIII needs to install a privileged helper to be able to inject code into "
//                  "an app running in the iOS simulator. This is the standard macOS mechanism.\n"
//                  "You can remove the helper at any time by deleting:\n"
//                  "/Library/PrivilegedHelperTools/com.johnholdsworth.InjectorationIII.Helper.\n"
//                  "If you'd rather not authorize, patch the app instead."] runModal] == NSAlertAlternateReturn)
//                return;
//    #pragma clang diagnostic pop
//            if ([HelperInstaller install:&error] == NO) {
//                NSLog(@"Couldn't install Smuggler Helper (domain: %@ code: %d)", error.domain, (int)error.code);
//                [[NSAlert alertWithError:error] runModal];
//                return;
//            }
//        }
//
//        // Inject Simulator process
//        NSString *bundlePath = [[NSBundle mainBundle] pathForResource:@"iOSInjection" ofType:@"bundle"];
//        if ([HelperProxy inject:bundlePath error:&error] == FALSE) {
//            NSLog(@"Couldn't inject Simulator (domain: %@ code: %d)", error.domain, (int)error.code);
//            [[NSAlert alertWithError:error] runModal];
//        }
//    #endif
    }

    @IBAction func help(_ sender: Any) {
        _ = NSWorkspace.shared.open(URL(string:
            "https://github.com/johnno1962/InjectionIII")!)
    }

    @IBAction func sponsor(_ sender: Any) {
        _ = NSWorkspace.shared.open(URL(string:
            "https://github.com/sponsors/johnno1962")!)
    }

    @IBAction func book(_ sender: Any) {
        _ = NSWorkspace.shared.open(URL(string:
            "https://books.apple.com/book/id1551005489")!)
    }

    @objc
    public func applicationWillTerminate(aNotification: NSNotification) {
            // Insert code here to tear down your application
        #if !SWIFT_PACKAGE
        DDHotKeyCenter.shared()
            .unregisterHotKey(withKeyCode: UInt16(kVK_ANSI_Equal),
             modifierFlags: NSEvent.ModifierFlags.control.rawValue)
        #endif
    }
}
