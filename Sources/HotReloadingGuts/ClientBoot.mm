//
//  ClientBoot.mm
//  InjectionIII
//
//  Created by John Holdsworth on 02/24/2021.
//  Copyright © 2021 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloadingGuts/ClientBoot.mm#92 $
//
//  Initiate connection to server side of InjectionIII/HotReloading.
//

#if DEBUG || !SWIFT_PACKAGE
#import "InjectionClient.h"
#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "SimpleSocket.h"
#import <dlfcn.h>

#ifndef INJECTION_III_APP
NSString *INJECTION_KEY = @__FILE__;
#endif

#if defined(DEBUG) || defined(INJECTION_III_APP)
@interface BundleInjection: NSObject
@end
@implementation BundleInjection

+ (void)load {
    if (Class clientClass = objc_getClass("InjectionClient"))
        [self performSelectorInBackground:@selector(tryConnect:)
                               withObject:clientClass];
}

static SimpleSocket *injectionClient;
NSString *injectionHost = @"127.0.0.1";

+ (void)tryConnect:(Class)clientClass {
    NSString *socketAddr = @INJECTION_ADDRESS;
    __unused const char *buildPhase = APP_PREFIX"You'll need to be running a recent copy of the InjectionIII.app downloaded from https://github.com/johnno1962/InjectionIII/releases?\n"
    APP_PREFIX"And have typed: defaults write com.johnholdsworth.InjectionIII deviceUnlock any\n";
    BOOL isVapor = dlsym(RTLD_DEFAULT, VAPOR_SYMBOL) != nullptr;
#if !defined(INJECTION_III_APP)
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_OSX
    BOOL isiOSAppOnMac = false;
    if (@available(iOS 14.0, *)) {
        isiOSAppOnMac = [NSProcessInfo processInfo].isiOSAppOnMac;
    }
    if (!isiOSAppOnMac && !isVapor && !getenv("INJECTION_DAEMON"))
        if (Class standalone = objc_getClass("StandaloneInjection")) {
            [[standalone new] run];
            return;
        }
#elif TARGET_OS_IPHONE
    const char *envHost = getenv("INJECTION_HOST");
    #ifdef DEVELOPER_HOST
    if (!isdigit(DEVELOPER_HOST[0]) && !envHost)
        printf(APP_PREFIX"Sending multicast packet to connect to your development host %s.\n"
               APP_PREFIX"If this fails,hardcode your Mac's IP address in HotReloading/Package.swift\n"
               "   or add an environment variable INJECTION_HOST with this value.\n%s", DEVELOPER_HOST, buildPhase);
    #endif
    injectionHost = [NSString stringWithUTF8String: envHost ?: [clientClass
        getMulticastService:HOTRELOADING_MULTICAST port:HOTRELOADING_PORT
                    message:APP_PREFIX"Connecting to %s (%s)...\n"]];
    socketAddr = [injectionHost stringByAppendingString:socketAddr];
#endif
#endif
    for (int retry=0, retrys=1; retry<retrys; retry++) {
        if (retry)
            [NSThread sleepForTimeInterval:1.0];
        if ((injectionClient = [clientClass connectTo:socketAddr])) {
            [injectionClient run];
            return;
        }
    }

#if TARGET_IPHONE_SIMULATOR || TARGET_OS_OSX
    BOOL usingInjectPackage = dlsym(RTLD_DEFAULT, "$s6InjectAAON") != nullptr;
    if ((usingInjectPackage || getenv("INJECTION_DAEMON")) &&
        !getenv("INJECTION_STANDALONE")) {
        if (usingInjectPackage)
        printf(APP_PREFIX"Not falling back to standalone HotReloading as you are using the ‘Inject’ package. "
               "Use MenuBar app to control Injection status or opt in by using INJECTION_STANDALONE env var.\n");
        return;
    }
    else if (Class standalone = objc_getClass("StandaloneInjection")) {
        printf(APP_PREFIX"Unable to connect to InjectionIII app, falling back to standalone HotReloading.\n");
        [[standalone new] run];
        return;
    }
#endif

    if (isVapor) {
        printf(APP_PREFIX"Unable to connect to HotReloading server, "
               "please run %s/start_daemon.sh from inside the project "
               "root and restart the server.\n",
               @__FILE__.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent
               .stringByDeletingLastPathComponent.UTF8String);
        return;
    }
#ifdef INJECTION_III_APP
    printf(APP_PREFIX"⚠️ Injection bundle loaded but could not connect. Is InjectionIII.app running?\n");
#else
    printf(APP_PREFIX"⚠️ HotReloading loaded but could not connect to %s. Is InjectionIII.app running? ⚠️\n", injectionHost.UTF8String);
#endif
#ifndef __IPHONE_OS_VERSION_MIN_REQUIRED
    printf(APP_PREFIX"⚠️ For a macOS app you need to turn off the sandbox to connect. ⚠️\n");
#endif
}

+ (const char *)connectedAddress {
    return injectionHost.UTF8String;
}
@end

#if DEBUG && !defined(INJECTION_III_APP)
@implementation NSObject(InjectionTester)
- (void)swiftTraceInjectionTest:(NSString * _Nonnull)sourceFile
                         source:(NSString * _Nonnull)source {
    if (!injectionClient)
        NSLog(@"swiftTraceInjectionTest: Too early.");
    [injectionClient writeCommand:InjectionTestInjection
                           withString:sourceFile];
    [injectionClient writeString:source];
}
@end
#endif

@interface NSObject(QuickSpecs)
+ (id)sharedWorld;
+ (XCTestSuite *)defaultTestSuite;
- (void)setCurrentExampleMetadata:(id)md;
@end

@implementation NSObject (RunXCTestCase)
+ (void)runXCTestCase:(Class)aTestCase {
    Class _XCTestSuite = objc_getClass("XCTestSuite");
    XCTestSuite *suite0 = [_XCTestSuite testSuiteWithName: @"InjectedTest"];
    XCTestSuite *suite = aTestCase.defaultTestSuite;
    Class _XCTestSuiteRun = objc_getClass("XCTestSuiteRun");
    XCTestSuiteRun *tr = [_XCTestSuiteRun testRunWithTest: suite];
    [suite0 addTest:suite];
    [suite0 performTest:tr];
    if (NSUInteger failed = tr.totalFailureCount)
        printf("\n" APP_PREFIX"*** %lu/%lu tests have FAILED ***\n",
               failed, tr.testCaseCount);
//    Class _QuickSpec = objc_getClass("QuickSpec");
//    Class _QuickWorld = objc_getClass("_TtC5Quick5World");
//    if (_QuickSpec && [[aTestCase class] isSubclassOfClass:_QuickSpec] &&
//        [_QuickWorld respondsToSelector:@selector(sharedWorld)] &&
//        [_QuickWorld instancesRespondToSelector:@selector(setCurrentExampleMetadata:)])
//        [[_QuickWorld sharedWorld] setCurrentExampleMetadata:nil];
    printf("\n");
}
@end
#endif

#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
@interface UIViewController (StoryboardInjection)
- (void)_loadViewFromNibNamed:(NSString *)a0 bundle:(NSBundle *)a1;
@end
@implementation UIViewController (iOS14StoryboardInjection)
- (void)iOS14LoadViewFromNibNamed:(NSString *)nibName bundle:(NSBundle *)bundle {
    if ([self respondsToSelector:@selector(_loadViewFromNibNamed:bundle:)])
        [self _loadViewFromNibNamed:nibName bundle:bundle];
    else {
        size_t vcSize = class_getInstanceSize([UIViewController class]);
        size_t mySize = class_getInstanceSize([self class]);
        char *extra = (char *)(__bridge void *)self + vcSize;
        NSData *ivars = [NSData dataWithBytes:extra length:mySize-vcSize];
        (void)[self initWithNibName:nibName bundle:bundle];
        memcpy(extra, ivars.bytes, ivars.length);
        [self loadView];
    }
}
@end

@interface NSObject (Remapped)
+ (void)addMappingFromIdentifier:(NSString *)identifier toObject:(id)object forCoder:(id)coder;
+ (id)mappedObjectForCoder:(id)decoder withIdentifier:(NSString *)identifier;
@end

@implementation NSObject (Remapper)

static struct {
    NSMutableDictionary *inputIndexes;
    NSMutableArray *output, *order;
    int orderIndex;
} remapper;

+ (void)my_addMappingFromIdentifier:(NSString *)identifier toObject:(id)object forCoder:(id)coder {
    //NSLog(@"Map %@ = %@", identifier, object);
    if(remapper.output && [identifier hasPrefix:@"UpstreamPlaceholder-"]) {
        if (remapper.inputIndexes)
            remapper.inputIndexes[identifier] = @([remapper.inputIndexes count]);
        else
            [remapper.output addObject:object];
    }
    [self my_addMappingFromIdentifier:identifier toObject:object forCoder:coder];
}

+ (id)my_mappedObjectForCoder:(id)decoder withIdentifier:(NSString *)identifier {
    //NSLog(@"Mapped? %@", identifier);
    if(remapper.output && [identifier hasPrefix:@"UpstreamPlaceholder-"]) {
        if (remapper.inputIndexes)
            [remapper.order addObject:remapper.inputIndexes[identifier] ?: @""];
        else
            return remapper.output[[remapper.order[remapper.orderIndex++] intValue]];
    }
    return [self my_mappedObjectForCoder:decoder withIdentifier:identifier];
}

+ (BOOL)injectUI:(NSString *)changed {
    static NSMutableDictionary *allOrder;
    static dispatch_once_t once;
    printf(APP_PREFIX"Waiting for rebuild of %s\n", changed.UTF8String);

    dispatch_once(&once, ^{
        Class proxyClass = objc_getClass("UIProxyObject");
        method_exchangeImplementations(
           class_getClassMethod(proxyClass,
                                @selector(my_addMappingFromIdentifier:toObject:forCoder:)),
           class_getClassMethod(proxyClass,
                                @selector(addMappingFromIdentifier:toObject:forCoder:)));
        method_exchangeImplementations(
           class_getClassMethod(proxyClass,
                                @selector(my_mappedObjectForCoder:withIdentifier:)),
           class_getClassMethod(proxyClass,
                                @selector(mappedObjectForCoder:withIdentifier:)));
        allOrder = [NSMutableDictionary new];
    });

    @try {
        UIViewController *rootViewController = [UIApplication sharedApplication].windows.firstObject.rootViewController;
        UINavigationController *navigationController = (UINavigationController*)rootViewController;
        UIViewController *visibleVC = rootViewController;

        if (UIViewController *child =
            visibleVC.childViewControllers.firstObject)
            visibleVC = child;
        if ([visibleVC respondsToSelector:@selector(viewControllers)])
            visibleVC = [(UISplitViewController *)visibleVC
                         viewControllers].lastObject;

        if ([visibleVC respondsToSelector:@selector(visibleViewController)])
            visibleVC = [(UINavigationController *)visibleVC
                         visibleViewController];
        if (!visibleVC.nibName && [navigationController respondsToSelector:@selector(topViewController)]) {
          visibleVC = [navigationController topViewController];
        }

        NSString *nibName = visibleVC.nibName;

        if (!(remapper.order = allOrder[nibName])) {
            remapper.inputIndexes = [NSMutableDictionary new];
            remapper.output = [NSMutableArray new];
            allOrder[nibName] = remapper.order = [NSMutableArray new];

            [visibleVC iOS14LoadViewFromNibNamed:visibleVC.nibName
                                          bundle:visibleVC.nibBundle];

            remapper.inputIndexes = nil;
            remapper.output = nil;
        }

        Class SwiftEval = objc_getClass("SwiftEval"),
         SwiftInjection = objc_getClass("SwiftInjection");

        NSError *err = nil;
        [[SwiftEval sharedInstance] rebuildWithStoryboard:changed error:&err];
        if (err)
            return FALSE;

        void (^resetRemapper)(void) = ^{
            remapper.output = [NSMutableArray new];
            remapper.orderIndex = 0;
        };

        resetRemapper();

        [visibleVC iOS14LoadViewFromNibNamed:visibleVC.nibName
                                      bundle:visibleVC.nibBundle];

        if ([[SwiftEval sharedInstance] vaccineEnabled] == YES) {
            resetRemapper();
            [SwiftInjection vaccine:visibleVC];
        } else {
            [visibleVC viewDidLoad];
            [visibleVC viewWillAppear:NO];
            [visibleVC viewDidAppear:NO];

            [SwiftInjection flash:visibleVC];
        }
    }
    @catch(NSException *e) {
        printf("Problem reloading nib: %s\n", e.reason.UTF8String);
    }

    remapper.output = nil;
    return true;
}
@end
#endif
#endif
