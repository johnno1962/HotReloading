
#import "InjectionClient.h"
#import <XCTest/XCTest.h>
#import <objc/runtime.h>

@interface ClientBoot: NSObject
@end

@implementation ClientBoot

+ (void)load {
    if (Class clientClass = objc_getClass("HotReloading")) {
        if (InjectionClient *client = [clientClass connectTo:INJECTION_ADDRESS])
            [client run];
        else {
            printf("🔥 ⚠️ HotReloading loaded but could not connect. Is injectiond running? ⚠️\n"
                   "🔥 Have you added the following \"Run Script\" build phase?\n"
                   "$SYMROOT/../../SourcePackages/checkouts/HotReloading/start_daemon.sh\n");
#ifndef __IPHONE_OS_VERSION_MIN_REQUIRED
            printf("⚠️ For a macOS app you need to turn off the sandbox to connect. ⚠️\n");
#endif
        }
    }
}

@end

@implementation NSObject(RunXCTestCase)
+ (void)runXCTestCase:(Class)aTestCase {
    Class _XCTestSuite = objc_getClass("XCTestSuite");
    XCTestSuite *suite0 = [_XCTestSuite testSuiteWithName: @"InjectedTest"];
    XCTestSuite *suite = [_XCTestSuite testSuiteForTestCaseClass: aTestCase];
    Class _XCTestSuiteRun = objc_getClass("XCTestSuiteRun");
    XCTestSuiteRun *tr = [_XCTestSuiteRun testRunWithTest: suite];
    [suite0 addTest:suite];
    [suite0 performTest:tr];
}
@end
