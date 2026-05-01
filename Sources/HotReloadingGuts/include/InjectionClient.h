//
//  InjectionClient.h
//  InjectionBundle
//
//  Created by John Holdsworth on 06/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloadingGuts/include/InjectionClient.h#70 $
//
//  Shared definitions between server and client.
//

#import <Foundation/Foundation.h>
#import "UserDefaults.h"
#import <mach-o/dyld.h>
#ifndef __IPHONE_OS_VERSION_MIN_REQUIRED
#import <AppKit/NSWorkspace.h>
#import <libproc.h>
#import "../../injectiondGuts/include/Xcode.h"
#endif

#define HOTRELOADING_PORT ":8899"
#define HOTRELOADING_SALT 2122172543
#define HOTRELOADING_MULTICAST "239.255.255.239"

#ifdef INJECTION_III_APP
#define INJECTION_ADDRESS ":8898"
#import "../../../../InjectionIII/InjectionIIISalt.h"
#define INJECTION_KEY @"bvijkijyhbtrbrebzjbbzcfbbvvq"
#define APP_NAME "InjectionIII"
#define APP_PREFIX "💉 "
#else
#define INJECTION_ADDRESS HOTRELOADING_PORT
#define INJECTION_SALT HOTRELOADING_SALT
extern NSString *INJECTION_KEY;
#define APP_NAME "HotReloading"
#define APP_PREFIX "🔥 "
#if DEBUG
@interface NSObject(InjectionTester)
- (void)swiftTraceInjectionTest:(NSString *)sourceFile
                         source:(NSString *)source;
@end
#endif
#endif

#define COMMANDS_PORT ":8896"
#define DYLIB_PREFIX "/eval_injection_" // Was expected by DLKit
#define VAPOR_SYMBOL "$s10RoutingKit10ParametersVN"
#define FRAMEWORK_DELIMITER @","
#define CALLORDER_DELIMITER @"---"

/// Build setting reauired for per-compilation logging since Xcode 16.3
#define EMIT_FRONTEND_COMMAND_LINES "EMIT_FRONTEND_COMMAND_LINES"

// Environment variables that can be used in schemes.
/// IP or hostname of developer's machine for connecting from device.
#define INJECTION_HOST "INJECTION_HOST"
/// Default list of directories fo watch, should include ~/Library/Developer.
#define INJECTION_DIRECTORIES "INJECTION_DIRECTORIES"
/// The root directory(s) to (auto-)file watch of the project being injected.
#define INJECTION_PROJECT_ROOT "INJECTION_PROJECT_ROOT"
/// Notification on injection as alternative to @objc func injected() method
#define INJECTION_BUNDLE_NOTIFICATION "INJECTION_BUNDLE_NOTIFICATION"
/// Preserve the value of top level and static variables over an injection.
#define INJECTION_PRESERVE_STATICS "INJECTION_PRESERVE_STATICS"
/// Directory containing Bazel workspace.
#define BUILD_WORKSPACE_DIRECTORY "BUILD_WORKSPACE_DIRECTORY"
/// Regex of types to exclude from sweep to implement @objc func injected().
#define INJECTION_SWEEP_EXCLUDE "INJECTION_SWEEP_EXCLUDE"
/// Enable verbose logging of types as they are swept  to localise problems.
#define INJECTION_SWEEP_DETAIL "INJECTION_SWEEP_DETAIL"
/// Don't run "standalone" injection in the simulator after failing to connect.
#define INJECTION_NOSTANDALONE "INJECTION_NOSTANDALONE"
/// Opt-into legacy injection of generics classes using the object sweep.
#define INJECTION_OF_GENERICS "INJECTION_OF_GENERICS"
/// Opt-out of new injection of generic classes not using the sweep.
#define INJECTION_NOGENERICS "INJECTION_NOGENERICS"
/// Opt-out of "hook" enabling injection of code that uses key paths.
#define INJECTION_NOKEYPATHS "INJECTION_NOKEYPATHS"
/// Opt-into enabling injection of key paths when not using TCA.
#define INJECTION_KEYPATHS "INJECTION_KEYPATHS"
/// Verbose logging of steps binding injected code into your app.
#define INJECTION_DETAIL "INJECTION_DETAIL"

#define INJECTION_METRICS_NOTIFICATION "INJECTION_METRICS_NOTIFICATION"

/// InjectionIII specific:
/// Derived data override
#define INJECTION_DERIVED_DATA "INJECTION_DERIVED_DATA"
/// Enable for for X as? Y where Y is injected
#define INJECTION_DYNAMIC_CAST "INJECTION_DYNAMIC_CAST"
/// Enable injection code when running tests
#define INJECTION_USEINTESTS "INJECTION_USEINTESTS"
/// Force standalone mode
#define INJECTION_STANDALONE "INJECTION_STANDALONE"
/// Enable legacy unhide behaviour
#define INJECTION_UNHIDE "INJECTION_UNHIDE"
/// Inhibits standalone mode to connect to app
#define INJECTION_DAEMON "INJECTION_DAEMON"
/// Replay previous injections on app start
#define INJECTION_REPLAY "INJECTION_REPLAY"
/// Look up custom app types when tracing
#define INJECTION_LOOKUP "INJECTION_LOOKUP"
/// Trace methods matching regex pattern
#define INJECTION_TRACE "INJECTION_TRACE"

@protocol InjectionReader <NSObject>
- (BOOL)readBytes:(void *)buffer length:(size_t)length cmd:(SEL)cmd;
@end

@interface InjectionClientLegacy
@property BOOL vaccineEnabled;
+ (InjectionClientLegacy *)sharedInstance;
- (void)vaccine:object;
+ (void)flash:vc;
- (void)rebuildWithStoryboard:(NSString *)changed error:(NSError **)err;
@end

@interface NSObject(HotReloading)
+ (void)runXCTestCase:(Class)aTestCase;
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
+ (BOOL)injectUI:(NSString *)changed;
#endif
@end

@interface NSProcessInfo(iOSAppOnMac)
@property BOOL isiOSAppOnMac;
@end

typedef NS_ENUM(int, InjectionCommand) {
    // commands to Bundle
    InjectionConnected,
    InjectionWatching,
    InjectionLog,
    InjectionSigned,
    InjectionLoad,
    InjectionInject,
    InjectionIdeProcPath,
    InjectionXprobe,
    InjectionEval,
    InjectionVaccineSettingChanged,

    InjectionTrace,
    InjectionUntrace,
    InjectionTraceUI,
    InjectionTraceUIKit,
    InjectionTraceSwiftUI,
    InjectionTraceFramework,
    InjectionQuietInclude,
    InjectionInclude,
    InjectionExclude,
    InjectionStats,
    InjectionCallOrder,
    InjectionFileOrder,
    InjectionFileReorder,
    InjectionUninterpose,
    InjectionFeedback,
    InjectionLookup,
    InjectionCounts,
    InjectionCopy,
    InjectionPseudoUnlock,
    InjectionPseudoInject,
    InjectionObjcClassRefs,
    InjectionDescriptorRefs,
    InjectionSetXcodeDev,
    InjectionAppVersion,
    InjectionProfileUI,

    InjectionInvalid = 1000,

    InjectionEOF = ~0
};

typedef NS_ENUM(int, InjectionResponse) {
    // responses from bundle
    InjectionComplete,
    InjectionPause,
    InjectionSign,
    InjectionError,
    InjectionFrameworkList,
    InjectionCallOrderList,
    InjectionScratchPointer,
    InjectionTestInjection,
    InjectionLegacyUnhide,
    InjectionForceUnhide,
    InjectionProjectRoot,
    InjectionGetXcodeDev,
    InjectionBuildCache,
    InjectionDerivedData,
    InjectionPlatform,

    InjectionExit = ~0
};

#ifdef __cplusplus
extern "C" {
#endif
// defined in Unhide.mm
extern int unhide_symbols(const char *framework, const char *linkFileList, FILE *log, time_t since);
extern int unhide_object(const char *object_file, const char *framework, FILE *log,
                         NSMutableArray<NSString *> *class_references,
                         NSMutableArray<NSString *> *descriptor_refs);
extern void unhide_reset(void);

#if !TARGET_IPHONE_SIMULATOR
extern void reverse_symbolics(const void *image);
#endif

// objc4-internal.h
struct objc_image_info;
OBJC_EXPORT Class objc_readClassPair(Class cls,
                                     const struct objc_image_info *info)
    OBJC_AVAILABLE(10.10, 8.0, 9.0, 1.0, 2.0);
#ifdef __cplusplus
}
#endif
