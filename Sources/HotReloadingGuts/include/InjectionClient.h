//
//  HotReloading.swift
//  InjectionBundle
//
//  Created by John Holdsworth on 02/24/2021.
//  Copyright © 2021 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloadingGuts/include/InjectionClient.h#7 $
//
//  Server daemon side of HotReloading simulating InjectionIII.app.
//

#import "SimpleSocket.h"
#import "UserDefaults.h"
#import "SignerService.h"
#import <mach-o/dyld.h>
#ifndef __IPHONE_OS_VERSION_MIN_REQUIRED
#import <AppKit/NSWorkspace.h>
#import <libproc.h>
#endif

#import "Xprobe.h"
//#import "Xtrace.h"

#define INJECTION_SALT 2122172543
extern NSString *INJECTION_KEY;

@interface Cobblers
@property BOOL vaccineEnabled;
+ (Cobblers *)sharedInstance;
- (void)vaccine:object;
+ (void)flash:vc;
- (void)rebuildWithStoryboard:(NSString *)changed error:(NSError **)err;
@end

@interface NSObject(HotReloading)
+ (void)runXCTestCase:(Class)aTestCase;
+ (BOOL)injectUI:(NSString *)changed;
@end

#define INJECTION_ADDRESS @":8899"
#define FRAMEWORK_DELIMITER @","
#define CALLORDER_DELIMITER @"---"

@interface InjectionClient : SimpleSocket

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

    InjectionExit = ~0
};

