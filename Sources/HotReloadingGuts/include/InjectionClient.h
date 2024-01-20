//
//  InjectionClient.h
//  InjectionBundle
//
//  Created by John Holdsworth on 06/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloadingGuts/include/InjectionClient.h#54 $
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
#import "/tmp/InjectionIIISalt.h"
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

#define VAPOR_SYMBOL "$s10RoutingKit10ParametersVN"
#define FRAMEWORK_DELIMITER @","
#define CALLORDER_DELIMITER @"---"

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
extern int unhide_framework(const char *framework, FILE *log);
extern void unhide_reset(void);

extern void reverse_symbolics(const void *image);

// objc4-internal.h
struct objc_image_info;
OBJC_EXPORT Class objc_readClassPair(Class cls,
                                     const struct objc_image_info *info)
    OBJC_AVAILABLE(10.10, 8.0, 9.0, 1.0, 2.0);
#ifdef __cplusplus
}
#endif
