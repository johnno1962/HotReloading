//
//  FileWatcher.swift
//  InjectionIII
//
//  Created by John Holdsworth on 08/03/2015.
//  Copyright (c) 2015 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/FileWatcher.swift#2 $
//
//  Simple abstraction to watch files under a driectory.
//

import Foundation
#if SWIFT_PACKAGE
import HotReloadingGuts
#endif

let INJECTABLE_PATTERN = "[^~]\\.(mm?|cpp|swift|storyboard|xib)$"

public typealias InjectionCallback = (_ filesChanged: NSArray, _ ideProcPath: String) -> Void

public class FileWatcher: NSObject {
    var fileEvents: FSEventStreamRef! = nil
    var callback: InjectionCallback
    var context = FSEventStreamContext()

    @objc public init(root: String, callback: @escaping InjectionCallback) {
        self.callback = callback
        super.init()
        #if os(macOS)
        context.info = unsafeBitCast(self, to: UnsafeMutableRawPointer.self)
        #else
        watcher = self
        #endif
        fileEvents = FSEventStreamCreate(kCFAllocatorDefault,
             { (streamRef: FSEventStreamRef,
                clientCallBackInfo: UnsafeMutableRawPointer?,
                numEvents: Int, eventPaths: UnsafeMutableRawPointer,
                eventFlags: UnsafePointer<FSEventStreamEventFlags>,
                eventIds: UnsafePointer<FSEventStreamEventId>) in
                 #if os(macOS)
                 let watcher = unsafeBitCast(clientCallBackInfo, to: FileWatcher.self)
                 #endif
                 // Check that the event flags include an item renamed flag, this helps avoid
                 // unnecessary injection, such as triggering injection when switching between
                 // files in Xcode.
                 for i in 0 ..< numEvents {
                     let flag = Int(eventFlags[i])
                     if (flag & (kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified)) != 0 {
                        let changes = unsafeBitCast(eventPaths, to: NSArray.self)
                         DispatchQueue.main.async {
                             watcher.filesChanged(changes: changes)
                         }
                         return
                     }
                 }
             },
             &context, [root] as CFArray,
             FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
             FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagFileEvents))!
        FSEventStreamScheduleWithRunLoop(fileEvents, CFRunLoopGetMain(),
                                         "kCFRunLoopDefaultMode" as CFString)
        _ = FSEventStreamStart(fileEvents)
    }

    func filesChanged(changes: NSArray) {
        var changed = Set<NSString>()

        for path in changes {
            let path = path as! NSString
            if path.range(of: INJECTABLE_PATTERN,
                          options:.regularExpression).location != NSNotFound &&
                path.range(of: "DerivedData/|InjectionProject/|main.mm?$",
                            options:.regularExpression).location == NSNotFound &&
                FileManager.default.fileExists(atPath: path as String) {
                changed.insert(path)
            }
        }

        if changed.count != 0 {
            var path = ""
            #if os(macOS)
            if let application = NSWorkspace.shared.frontmostApplication {
                path = getProcPath(pid: application.processIdentifier)
            }
            #endif
            callback(Array(changed) as NSArray, path)
        }
    }

    #if os(macOS)
    deinit {
        FSEventStreamStop(fileEvents)
        FSEventStreamInvalidate(fileEvents)
        FSEventStreamRelease(fileEvents)
    }

    func getProcPath(pid: pid_t) -> String {
        let pathBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(MAXPATHLEN))
        defer {
            pathBuffer.deallocate()
        }
        proc_pidpath(pid, pathBuffer, UInt32(MAXPATHLEN))
        let path = String(cString: pathBuffer)
        return path
    }
    #endif
}

#if !os(macOS) // Yes, this is available in the simulator...
typealias FSEventStreamRef = OpaquePointer
typealias ConstFSEventStreamRef = OpaquePointer
struct FSEventStreamContext {
    var version: CFIndex = 0
    var info: UnsafeRawPointer?
    var retain: UnsafeRawPointer?
    var release: UnsafeRawPointer?
    var copyDescription: UnsafeRawPointer?
}
typealias FSEventStreamCreateFlags = UInt32
typealias FSEventStreamEventId = UInt64
typealias FSEventStreamEventFlags = UInt32

typealias FSEventStreamCallback = @convention(c) (ConstFSEventStreamRef, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer, UnsafePointer<FSEventStreamEventFlags>, UnsafePointer<FSEventStreamEventId>) -> Void

@_silgen_name("FSEventStreamCreate")
func FSEventStreamCreate(_ allocator: CFAllocator?, _ callback: FSEventStreamCallback, _ context: UnsafeMutablePointer<FSEventStreamContext>?, _ pathsToWatch: CFArray, _ sinceWhen: FSEventStreamEventId, _ latency: CFTimeInterval, _ flags: FSEventStreamCreateFlags) -> FSEventStreamRef?
@_silgen_name("FSEventStreamScheduleWithRunLoop")
func FSEventStreamScheduleWithRunLoop(_ streamRef: FSEventStreamRef, _ runLoop: CFRunLoop, _ runLoopMode: CFString)
@_silgen_name("FSEventStreamStart")
func FSEventStreamStart(_ streamRef: FSEventStreamRef) -> Bool

let kFSEventStreamEventIdSinceNow: UInt64 = 18446744073709551615
let kFSEventStreamCreateFlagUseCFTypes: FSEventStreamCreateFlags = 1
let kFSEventStreamCreateFlagFileEvents: FSEventStreamCreateFlags = 16
let kFSEventStreamEventFlagItemRenamed = 0x00000800
let kFSEventStreamEventFlagItemModified = 0x00001000
var watcher: FileWatcher!
#endif
