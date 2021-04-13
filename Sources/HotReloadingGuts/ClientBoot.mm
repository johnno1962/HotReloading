//
//  ClientBoot.mm
//  InjectionIII
//
//  Created by John Holdsworth on 02/24/2021.
//  Copyright © 2021 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloadingGuts/ClientBoot.mm#23 $
//
//  Initiate connection to server side of InjectionIII/HotReloading.
//

#import "InjectionClient.h"
#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "SimpleSocket.h"

#ifndef INJECTION_III_APP
NSString *INJECTION_KEY = @__FILE__;
#endif

#if defined(DEBUG) || defined(INJECTION_III_APP)
@interface BundleInjection: NSObject
@end
@implementation BundleInjection

+ (void)load {
    NSLog(@"JHJHGJG");
    if (Class clientClass = objc_getClass("InjectionClient"))
        [self performSelectorInBackground:@selector(tryConnect:)
                               withObject:clientClass];
}

+ (void)tryConnect:(Class)clientClass {
    for (int i=0, retrys=3; i<retrys; i++)
        if (SimpleSocket *client = [clientClass connectTo:@INJECTION_ADDRESS]) {
            [client run];
            return;
        }
        else
            [NSThread sleepForTimeInterval:1.0];

#ifdef INJECTION_III_APP
    printf(APP_PREFIX"⚠️ Injection bundle loaded but could not connect. Is InjectionIII.app running?\n");
#else
    printf(APP_PREFIX"⚠️ HotReloading loaded but could not connect. Is injectiond running? ⚠️\n"
       APP_PREFIX"Have you added the following \"Run Script\" build phase to your project to start injectiond?\n"
        "if [ -d $SYMROOT/../../SourcePackages ]; then\n"
        "    $SYMROOT/../../SourcePackages/checkouts/HotReloading/start_daemon.sh\n"
        "elif [ -d \"$SYMROOT\"/../../../../../SourcePackages ]; then\n"
        "    \"$SYMROOT\"/../../../../../SourcePackages/checkouts/HotReloading/fix_previews.sh\n"
        "fi\n");
#endif
#ifndef __IPHONE_OS_VERSION_MIN_REQUIRED
    printf(APP_PREFIX"⚠️ For a macOS app you need to turn off the sandbox to connect. ⚠️\n");
#endif
}

+ (const char *)connectedAddress {
    return "127.0.0.1";
}
@end

@implementation NSObject (RunXCTestCase)
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

        if ([SwiftEval sharedInstance].vaccineEnabled == YES) {
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

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/arch.h>
#import <mach-o/getsect.h>
#import <mach-o/nlist.h>
#import <mach/vm_prot.h>
#import <mach/mach.h>
#import <sys/mman.h>

#ifdef __LP64__
typedef struct mach_header_64 mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct nlist_64 nlist_t;
typedef uint64_t sectsize_t;
#define getsectdatafromheader_f getsectdatafromheader_64
#else
typedef struct mach_header mach_header_t;
typedef struct segment_command segment_command_t;
typedef struct nlist nlist_t;
typedef uint32_t sectsize_t;
#define getsectdatafromheader_f getsectdatafromheader
#endif

static char includeObjcClasses[] = {"CN"};
static char objcClassPrefix[] = {"_OBJC_CLASS_$_"};

const char *classesIncludingObjc() {
    return includeObjcClasses;
}

typedef mach_port_t     memory_object_name_t;
/* Used to describe the memory ... */
/*  object in vm_regions() calls */

typedef mach_port_t     memory_object_default_t;

static vm_prot_t get_protection(void *sectionStart) {
  mach_port_t task = mach_task_self();
  vm_size_t size = 0;
  vm_address_t address = (vm_address_t)sectionStart;
  memory_object_name_t object;
#if __LP64__
  mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
  vm_region_basic_info_data_64_t info;
  kern_return_t info_ret = vm_region_64(
      task, &address, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_64_t)&info, &count, &object);
#else
  mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT;
  vm_region_basic_info_data_t info;
  kern_return_t info_ret = vm_region(task, &address, &size, VM_REGION_BASIC_INFO, (vm_region_info_t)&info, &count, &object);
#endif
  if (info_ret == KERN_SUCCESS) {
    return info.protection;
  } else {
    return VM_PROT_READ;
  }
}

void unhideSwiftSymbols(const char *bundlePath, const char *suffix) {
    for (int32_t i = _dyld_image_count(); i >= 0 ; i--) {
        const char *imageName = _dyld_get_image_name(i);
        if (!(imageName && (!bundlePath || imageName == bundlePath ||
                            strcmp(imageName, bundlePath) == 0)))
            continue;

        const mach_header_t *header =
            (const mach_header_t *)_dyld_get_image_header(i);
        segment_command_t *seg_linkedit = nullptr;
        segment_command_t *seg_text = nullptr;
        struct symtab_command *symtab = nullptr;
        // to filter associated type witness entries
        sectsize_t typeref_size = 0;
        char *typeref_start = getsectdatafromheader_f(header, SEG_TEXT,
                                            "__swift5_typeref", &typeref_size);

        struct load_command *cmd =
            (struct load_command *)((intptr_t)header + sizeof(mach_header_t));
        for (uint32_t i = 0; i < header->ncmds; i++,
             cmd = (struct load_command *)((intptr_t)cmd + cmd->cmdsize)) {
            switch(cmd->cmd) {
                case LC_SEGMENT:
                case LC_SEGMENT_64:
                    if (!strcmp(((segment_command_t *)cmd)->segname, SEG_TEXT))
                        seg_text = (segment_command_t *)cmd;
                    else if (!strcmp(((segment_command_t *)cmd)->segname, SEG_LINKEDIT))
                        seg_linkedit = (segment_command_t *)cmd;
                    break;

                case LC_SYMTAB: {
                    symtab = (struct symtab_command *)cmd;
                    intptr_t file_slide = ((intptr_t)seg_linkedit->vmaddr - (intptr_t)seg_text->vmaddr) - seg_linkedit->fileoff;
                    const char *strings = (const char *)header +
                                               (symtab->stroff + file_slide);
                    nlist_t *sym = (nlist_t *)((intptr_t)header +
                                               (symtab->symoff + file_slide));
                    size_t sufflen = strlen(suffix);
                    BOOL witnessFuncSearch = strcmp(suffix+sufflen-2, "Wl") == 0 ||
                                             strcmp(suffix+sufflen-5, "pACTK") == 0;
                    uint8_t symbolVisibility = witnessFuncSearch ? 0x1e : 0xf;

                    for (uint32_t i = 0; i < symtab->nsyms; i++, sym++) {
                        const char *symname = strings + sym->n_un.n_strx;
                        void *address;

                        if (//sym->n_type == symbolVisibility &&
                            ((strncmp(symname, "_$s", 3) == 0 &&
                              strcmp(symname+strlen(symname)-sufflen, suffix) == 0) ||
                             (suffix == includeObjcClasses && strncmp(symname,
                              objcClassPrefix, sizeof objcClassPrefix-1) == 0)) &&
                            (address = (void *)(sym->n_value +
                             (intptr_t)header - (intptr_t)seg_text->vmaddr))) {
                            NSLog(@"HERE %s, %d", symname, sym->n_type);
                            if (sym->n_type == 14) {
                                vm_prot_t oldProtection = get_protection((void *)((uintptr_t)sym & ~((1<<14)-1)));
                                int protection = 0;
                                NSLog(@"%d", oldProtection);
                                if (oldProtection & VM_PROT_READ) {
                                  protection |= PROT_READ;
                                }
                                if (oldProtection & VM_PROT_WRITE || 1) {
                                  protection |= PROT_WRITE;
                                }
//                                if (oldProtection & VM_PROT_EXECUTE) {
//                                  protection |= PROT_EXEC;
//                                }
                                NSLog(@"%d %s", mprotect((void *)((uintptr_t)sym & ~((1<<14)-1)), (1<<14), protection), strerror(errno));
                                sym->n_type = 15;

                            }
                        }
                    }

                    if (bundlePath)
                        return;
                }
            }
        }
    }
}

@implementation NSObject(Unhide)
+ (void)load {
//    unhideSwiftSymbols([NSBundle mainBundle].executablePath.UTF8String, "");
}
@end
