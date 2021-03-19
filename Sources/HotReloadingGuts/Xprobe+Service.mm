//
//  Xprobe+Service.m
//  XprobePlugin
//
//  Created by John Holdsworth on 15/05/2015.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//
//  This is the implementation of most of the methods to run an
//  Xprobe service in an application providing HTML to the
//  object browser inside Xcode.
//
//  $Id: //depot/HotReloading/Sources/HotReloadingGuts/Xprobe+Service.mm#3 $
//

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wold-style-cast"
#pragma clang diagnostic ignored "-Wnullable-to-nonnull-conversion"
#pragma clang diagnostic ignored "-Wcstring-format-directive"
#pragma clang diagnostic ignored "-Wc++98-compat-pedantic"
#pragma clang diagnostic ignored "-Wc++98-compat"
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wpadded"

#import "Xprobe.h"

#import <netinet/tcp.h>
#import <sys/socket.h>
#import <arpa/inet.h>
#import <dlfcn.h>

#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
#import <UIKit/UIKit.h>
#else
#import <Cocoa/Cocoa.h>
#endif

#pragma mark external references

@interface NSObject(InjectionReferences)
+ (const char *)connectedAddress;
- (void)onXprobeEval;
- (void)injected;
@end

@interface XprobeSwift2 : NSObject
//+ (NSString *)string:(void *)stringPtr;
//+ (NSString *)stringOpt:(void *)stringPtr;
//+ (NSString *)array:(void *)arrayPtr;
//+ (NSString *)arrayOpt:(void *)arrayPtr;
+ (NSString *)demangle:(NSString *)name;
+ (NSArray<NSString *> *)listMembers:(id)instance;
+ (void)dumpMethods:(Class)aClass into:(NSMutableString *)into;
//+ (void)dumpIvars:(id)instance into:(NSMutableString *)into;
//+ (void)traceBundle:(NSBundle *)bundle;
//+ (void)traceClass:(Class)aClass;
//+ (void)traceInstance:(id)instance;
@end

extern Class xloadXprobeSwift( const char *ivarName );

@implementation Xprobe(Service)

static int clientSocket;

+ (void)connectTo:(const char *)ipAddress retainObjects:(BOOL)shouldRetain {

    if ( !ipAddress ) {
        Class injectionLoader = NSClassFromString(@"BundleInjection");
        if ( [injectionLoader respondsToSelector:@selector(connectedAddress)] )
            ipAddress = [injectionLoader connectedAddress];

        if ( !ipAddress )
            ipAddress = "127.0.0.1";
    }

    xprobeRetainObjects = shouldRetain;

    NSLog( @"Xprobe: Connecting to %s", ipAddress );

    if ( clientSocket ) {
        close( clientSocket );
        [NSThread sleepForTimeInterval:.5];
    }

    struct sockaddr_in loaderAddr;

    loaderAddr.sin_family = AF_INET;
    inet_aton( ipAddress, &loaderAddr.sin_addr );
    loaderAddr.sin_port = htons(XPROBE_PORT);

    int optval = 1;
    if ( (clientSocket = socket(loaderAddr.sin_family, SOCK_STREAM, 0)) < 0 )
        NSLog( @"Xprobe: Could not open socket for injection: %s", strerror( errno ) );
    else if ( connect( clientSocket, (struct sockaddr *)&loaderAddr, sizeof loaderAddr ) < 0 )
        NSLog( @"Xprobe: Could not connect: %s", strerror( errno ) );
    else if ( setsockopt( clientSocket, IPPROTO_TCP, TCP_NODELAY, (void *)&optval, sizeof(optval)) < 0 )
        NSLog( @"Xprobe: Could not set TCP_NODELAY: %s", strerror( errno ) );
    else if ( setsockopt( clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &optval, sizeof(optval) ) < 0 )
        NSLog( @"Xprobe: Could not set SO_NOSIGPIPE: %s", strerror( errno ) );
    else {
        uint32_t magic = XPROBE_MAGIC;
        if ( write(clientSocket, &magic, sizeof magic ) != sizeof magic ) {
            close( clientSocket );
            return;
        }

        [self writeString:[[NSBundle mainBundle] bundleIdentifier]];
        [self performSelectorInBackground:@selector(service) withObject:nil];
    }

    [self hackSwiftObject];
}

+ (void)hackSwiftObject {
    // Add xprobe NSObject methods to SwiftObject!
    Class swiftRoot = (__bridge Class)dlsym(RTLD_DEFAULT, "OBJC_CLASS_$__TtCs12_SwiftObject");
    if ( swiftRoot ) {
        unsigned mc;
        Method *methods = class_copyMethodList( [NSObject class], &mc );
        for ( unsigned i=0 ; i<mc ; i++ ) {
            Method method = methods[i];
            SEL methodSEL = method_getName( method );
            const char *methodName = sel_getName( methodSEL );
            if ( (methodName[0] == 'x' || strncmp( methodName, "method", 6 ) == 0) &&
                !class_getInstanceMethod( swiftRoot, methodSEL ) ) {
                if ( !class_addMethod( swiftRoot, methodSEL,
                                      method_getImplementation( method ),
                                      method_getTypeEncoding( method ) ) )
                    NSLog( @"Xprobe: Could not add SwiftObject method: %s %p %s", methodName,
                          (void *)method_getImplementation( method ), method_getTypeEncoding( method ) );
            }
        }
        free( methods );
    }
}

+ (void)service {
    while ( clientSocket ) {
        NSString *command = [self readString];
        if ( !command )
            break;
        NSString *argument = [self readString];
        if ( !argument )
            break;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self performSelector:NSSelectorFromString( command ) withObject:argument];
#pragma clang diagnostic pop
    }

    NSLog( @"Xprobe: Service loop exits" );
    close( clientSocket );
}

+ (NSString *)readString {
    uint32_t length;

    if ( read( clientSocket, &length, sizeof length ) != sizeof length ) {
        NSLog( @"Xprobe: Socket read error %s", strerror(errno) );
        return nil;
    }

    ssize_t sofar = 0, bytes;
    char *buff = (char *)malloc(length+1);

    while ( buff && sofar < length && (bytes = read( clientSocket, buff+sofar, length-sofar )) > 0 )
        sofar += bytes;

    if ( sofar < length ) {
        NSLog( @"Xprobe: Socket read error %d/%d: %s", (int)sofar, length, strerror(errno) );
        free( buff );
        return nil;
    }

    if ( buff )
        buff[sofar] = '\000';

    NSString *str = utf8String( buff );
    free( buff );
    return str;
}

+ (void)writeString:(NSString *)str {
    static dispatch_queue_t writeQueue;
    if ( !writeQueue )
        writeQueue = dispatch_queue_create("XprobeWrite", DISPATCH_QUEUE_SERIAL);

    dispatch_async(writeQueue, ^{
        @autoreleasepool {
            const char *data = [str UTF8String]?:" ";
            uint32_t length = (uint32_t)strlen(data);

            if ( !clientSocket )
                NSLog( @"Xprobe: Write to closed" );
            else if ( write( clientSocket, &length, sizeof length ) != sizeof length ||
                     write( clientSocket, data, length ) != length )
                NSLog( @"Xprobe: Socket write error %s", strerror(errno) );
        }
    });
}

+ (void)search:(NSString *)pattern {
    [self performSelectorOnMainThread:@selector(_search:) withObject:pattern waitUntilDone:NO];
}

static int lastPathID;

+ (void)open:(NSString *)input {
    lastPathID = [input intValue];
    XprobePath *path = xprobePaths[lastPathID];
    id obj = [path object];
    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('%d').outerHTML = '", lastPathID];
    if ( obj == nil ) {
        NSLog( @"Weakly held object #%d no londer exists", lastPathID );
        [html appendString:@"nil /* dealloced */"];
    }
    else {
        [obj xlinkForCommand:@"close" withPathID:lastPathID into:html];
        [html appendString:@"<br/>"];
        [self xopen:obj withPathID:lastPathID into:html];
    }

    [html appendString:@"';"];
//    NSLog( @"HTML: %@", html );
    [self writeString:html];

    if ( ![path isKindOfClass:[XprobeSuper class]] )
        [self writeString:[path xpath]];
}

+ (void)eval:(NSString *)input {
    lastPathID = [input intValue];
}

- (void)onXprobeEval {
}

+ (void)injectedClass:(Class)aClass {
    id lastObject = lastPathID < xprobePaths.count ? [xprobePaths[lastPathID] object] : nil;

    if ( (!aClass || [lastObject isKindOfClass:aClass]) ) {
        SEL onXprobeEval = @selector(onXprobeEval);
        if ( [lastObject respondsToSelector:onXprobeEval] ) {
            [lastObject onXprobeEval];
            Method nullMethod = class_getInstanceMethod([Xprobe class], onXprobeEval);
            class_replaceMethod(aClass, onXprobeEval,
                                method_getImplementation(nullMethod),
                                method_getTypeEncoding(nullMethod));
        }
        else if ([lastObject respondsToSelector:@selector(injected)] )
            [lastObject injected];
    }

    if ( aClass && clientSocket )
        [self writeString:[NSString stringWithFormat:@"$('BUSY%d').hidden = true; "
                           "$('SOURCE%d').disabled = sendClient('known:','%@') ? false : true;",
                           lastPathID, lastPathID, NSStringFromClass(aClass)]];
}

+ (void)xlog:(NSString *)message {
    NSString *output = [[message xhtmlEscape] stringByReplacingOccurrencesOfString:@"  " withString:@" \\&#160;"];
    [self writeString:[NSString stringWithFormat:@"$('OUTPUT%d').innerHTML += '%@<br/>';", lastPathID, output]];
}

+ (void)complete:(NSString *)input {
    XprobePath *path = xprobePaths[[input intValue]];
    NSMutableString *html = [NSMutableString new];

    [html appendString:@"$(); window.properties = '"];

    if (NSArray *members = [xloadXprobeSwift("") listMembers:[path object]])
        for ( int i=0 ; i<members.count ; i++ )
            [html appendFormat:@"%s%@", i ? "," : "", members[i]];
    else {
        Class aClass = [path aClass];
        unsigned pc;
        objc_property_t *props = NULL;
        do {
            props = class_copyPropertyList(aClass, &pc);
            aClass = class_getSuperclass(aClass);
        } while ( pc == 0 && aClass != [NSObject class] );

        for ( unsigned i=0 ; i<pc ; i++ )
            [html appendFormat:@"%s%@", i ? "," : "",
             utf8String( property_getName(props[i]) )];
        free(props);
    }

    [html appendString:@"'.split(',');"];
    [self writeString:html];
}

+ (void)close:(NSString *)input {
    int pathID = [input intValue];
    id obj = [xprobePaths[pathID] object];

    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('%d').outerHTML = '", pathID];
    [obj xlinkForCommand:@"open" withPathID:pathID into:html];

    [html appendString:@"';"];
    [self writeString:html];
}

+ (void)properties:(NSString *)input {
    int pathID = [input intValue];
    Class aClass = [xprobePaths[pathID] aClass];

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('P%d').outerHTML = '<span class=\\'propsStyle\\'><br/><br/>", pathID];

    unsigned pc;
    objc_property_t *props = class_copyPropertyList(aClass, &pc);
    for ( unsigned i=0 ; i<pc ; i++ ) {
        const char *attrs = property_getAttributes(props[i]);
        const char *name = property_getName(props[i]);
        NSString *utf8Name = utf8String( name );

        [html appendFormat:@"@property () %@ <span onclick=\\'this.id =\"P%d\"; "
         "sendClient( \"property:\", \"%d,%@\" ); event.cancelBubble = true;\\'>%@</span>; // %@<br/>",
         xtype( attrs+1 ), pathID, pathID, utf8Name, utf8Name,
         utf8String( attrs )];
    }

    free( props );

    [html appendString:@"</span>';"];
    [self writeString:html];
}

#ifndef _IvarAccess_h
struct _swift_class {
    union {
        Class meta;
        unsigned long flags;
    };
    Class supr;
    void *buckets, *vtable, *pdata;
    int f1, f2; // added for Beta5
    int size, tos, mdsize, eight;
    struct _swift_data *swiftData;
    IMP dispatch[1];
};

static struct _swift_class *isSwift( Class aClass ) {
    struct _swift_class *swiftClass = (__bridge struct _swift_class *)aClass;
    return (uintptr_t)swiftClass->pdata & 0x3 ? swiftClass : NULL;
}
#endif

+ (void)methods:(NSString *)input {
    int pathID = [input intValue];
    Class aClass = [xprobePaths[pathID] aClass];

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('M%d').outerHTML = '<br/><span class=\\'methodStyle\\'>"
     "Method Filter: <input type=textfield size=10 onchange=\\'methodFilter(this);\\'>", pathID];

    Class stopClass = aClass == [NSObject class] ? Nil : [NSObject class];
    for ( Class bClass = aClass ; bClass && bClass != stopClass ; bClass = [bClass superclass] )
        [self dumpMethodType:"+" forClass:object_getClass(bClass) original:object_getClass(aClass) pathID:pathID into:html];

    for ( Class bClass = aClass ; bClass && bClass != stopClass ; bClass = [bClass superclass] )
        [self dumpMethodType:"-" forClass:bClass original:aClass pathID:pathID into:html];

    if ( isSwift( aClass ) )
        [xloadXprobeSwift("methods:") dumpMethods:aClass into:html];

    [html appendString:@"</span>';"];
    [self writeString:html];
}

+ (void)dumpMethodType:(const char *)mtype forClass:(Class)aClass original:(Class)original
                pathID:(int)pathID into:(NSMutableString *)html {
    unsigned mc;
    Method *methods = class_copyMethodList(aClass, &mc);
    NSString *hide = aClass == original ? @"" :
    [NSString stringWithFormat:@" style=\\'display:none;\\' title=\\'%@\\'",
     NSStringFromClass(aClass)];

    if ( mc && ![hide length] )
        [html appendString:@"<br/>"];

    for ( unsigned i=0 ; i<mc ; i++ ) {
        const char *name = sel_getName(method_getName(methods[i]));
        const char *type = method_getTypeEncoding(methods[i]);
        NSString *utf8Name = utf8String( name );

        NSMethodSignature *sig = nil;
        @try {
            sig = [NSMethodSignature signatureWithObjCTypes:type];
        }
        @catch ( NSException *e ) {
            NSLog( @"Xprobe: Unable to parse signature for %@, '%s': %@", utf8Name, type, e );
        }

        NSArray *bits = [utf8Name componentsSeparatedByString:@":"];
        [html appendFormat:@"<div sel=\\'%@\\'%@>%s (%@)",
         utf8Name, hide, mtype, xtype( [sig methodReturnType] )];

        if ( [sig numberOfArguments] > 2 )
            for ( int a=2 ; a<[sig numberOfArguments] ; a++ )
                [html appendFormat:@"%@:(%@)a%d ", bits[a-2], xtype( [sig getArgumentTypeAtIndex:a] ), a-2];
        else
            [html appendFormat:@"<span onclick=\\'this.id =\"M%d\"; sendClient( \"method:\", \"%d,%@\" );"
             "event.cancelBubble = true;\\'>%@</span> ", pathID, pathID, utf8Name, utf8Name];

        [html appendString:@";</div>"];
    }

    free( methods );
}

+ (void)protocol:(NSString *)protoName {
    Protocol *protocol = NSProtocolFromString( protoName );
    NSString *protocolName = NSStringFromProtocol( protocol );
    if ( [protocolName isEqualToString:@"nil"] )
        protocolName = protoName;

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('%@').outerHTML = '<span id=\\'%@\\'><a href=\\'#\\' onclick=\\'sendClient( \"_protocol:\", \"%@\"); "
        "event.cancelBubble = true; return false;\\'>%@</a><p/><table><tr><td/><td class=\\'indent\\'/><td>"
        "<span class=\\'protoStyle\\'>@protocol %@", protoName, protoName, protoName, protocolName, protocolName];

    unsigned pc;
    Protocol *__unsafe_unretained *protos = protocol_copyProtocolList(protocol, &pc);
    if ( pc ) {
        [html appendString:@" &lt;"];

        for ( unsigned i=0 ; i<pc ; i++ ) {
            if ( i )
                [html appendString:@", "];
            NSString *protocolName = NSStringFromProtocol(protos[i]);
            [html appendString:xlinkForProtocol( protocolName )];
        }

        [html appendString:@"&gt;"];
        free( protos );
    }

    [html appendString:@"<br/>"];

    objc_property_t *props = protocol_copyPropertyList(protocol, &pc);

    for ( unsigned i=0 ; i<pc ; i++ ) {
        const char *attrs = property_getAttributes(props[i]);
        const char *name = property_getName(props[i]);
        [html appendFormat:@"@property () %@ %@; // %@<br/>", xtype( attrs+1 ),
         utf8String( name ), utf8String( attrs )];
    }

    free( props );

    [self dumpMethodsForProtocol:protocol required:YES instance:NO into:html];
    [self dumpMethodsForProtocol:protocol required:NO instance:NO into:html];

    [self dumpMethodsForProtocol:protocol required:YES instance:YES into:html];
    [self dumpMethodsForProtocol:protocol required:NO instance:YES into:html];

    [html appendString:@"<br/>@end<p/></span></td></tr></table></span>';"];
    [self writeString:html];
}

// Thanks to http://bou.io/ExtendedTypeInfoInObjC.html !
extern "C" const char *_protocol_getMethodTypeEncoding(Protocol *,SEL,BOOL,BOOL);

+ (void)dumpMethodsForProtocol:(Protocol *)protocol required:(BOOL)required instance:(BOOL)instance into:(NSMutableString *)html {

    unsigned mc;
    objc_method_description *methods = protocol_copyMethodDescriptionList( protocol, required, instance, &mc );
    if ( !mc )
        return;

    [html appendFormat:@"<br/>@%@<br/>", required ? @"required" : @"optional"];

    for ( unsigned i=0 ; i<mc ; i++ ) {
        const char *name = sel_getName(methods[i].name);
        const char *type;// = methods[i].types;
        NSString *utf8Name = utf8String( name );

        type = _protocol_getMethodTypeEncoding(protocol, methods[i].name, required,instance);
        NSMethodSignature *sig = nil;
        @try {
            sig = [NSMethodSignature signatureWithObjCTypes:type];
        }
        @catch ( NSException *e ) {
            NSLog( @"Xprobe: Unable to parse protocol signature for %@, '%@': %@",
                  utf8Name, utf8String( type ), e );
        }

        NSArray *parts = [utf8Name componentsSeparatedByString:@":"];
        [html appendFormat:@"%s (%@)", instance ? "-" : "+", xtype( [sig methodReturnType] )];

        if ( [sig numberOfArguments] > 2 )
            for ( int a=2 ; a<[sig numberOfArguments] ; a++ )
                [html appendFormat:@"%@:(%@)a%d ", a-2 < [parts count] ? parts[a-2] : @"?",
                 xtype( [sig getArgumentTypeAtIndex:a] ), a-2];
        else
            [html appendFormat:@"%@", utf8Name];

        [html appendString:@" ;<br/>"];
    }

    free( methods );
}

+ (void)_protocol:(NSString *)protocolName {
    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('%@').outerHTML = '%@';",
     protocolName, xlinkForProtocol( protocolName )];
    [self writeString:html];
}

+ (void)views:(NSString *)input {
    int pathID = [input intValue];
    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('V%d').outerHTML = '<br/>", pathID];
    [self subviewswithPathID:pathID indent:0 into:html];

    [html appendString:@"';"];
    [self writeString:html];
}

+ (void)subviewswithPathID:(int)pathID indent:(int)indent into:(NSMutableString *)html {
    id obj = [xprobePaths[pathID] object];
    for ( int i=0 ; i<indent ; i++ )
        [html appendString:@"&#160; &#160; "];

    [obj xlinkForCommand:@"open" withPathID:pathID into:html];
    [html appendString:@"<br/>"];

    NSArray *subviews = [obj subviews];
    for ( int i=0 ; i<[subviews count] ; i++ ) {
        XprobeView *path = [XprobeView withPathID:pathID];
        path.sub = i;
        [self subviewswithPathID:[path xadd] indent:indent+1 into:html];
    }
}

struct _xinfo {
    int pathID;
    id obj;
    Class aClass;
    NSString *name, *value;
};

+ (struct _xinfo)parseInput:(NSString *)input {
    NSArray *parts = [input componentsSeparatedByString:@","];
    struct _xinfo info;

    info.pathID = [parts[0] intValue];
    info.obj = [xprobePaths[info.pathID] object];
    info.aClass = [xprobePaths[info.pathID] aClass];
    info.name = parts[1];

    if ( [parts count] >= 3 )
        info.value = parts[2];

    return info;
}

+ (void)ivar:(NSString *)input {
    struct _xinfo info = [self parseInput:input];
    Ivar ivar = class_getInstanceVariable( info.aClass, [info.name UTF8String] );
    const char *type = ivar_getTypeEncodingSwift( ivar, info.aClass );

    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('I%d').outerHTML = '", info.pathID];
    [info.obj xspanForPathID:info.pathID ivar:ivar type:type into:html];

    [html appendString:@"';"];
    [self writeString:html];
}

+ (void)edit:(NSString *)input {
    struct _xinfo info = [self parseInput:input];
    Ivar ivar = class_getInstanceVariable( info.aClass, [info.name UTF8String] );

    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('E%d').outerHTML = '"
     "<span id=E%d><input type=textfield size=10 value=\\'%@\\' "
     "onchange=\\'sendClient(\"save:\", \"%d,%@,\"+this.value );\\'></span>';",
     info.pathID, info.pathID, xvalueForIvar( info.obj, ivar, info.aClass ),
     info.pathID, info.name];

    [self writeString:html];
}

+ (void)save:(NSString *)input {
    struct _xinfo info = [self parseInput:input];
    Ivar ivar = class_getInstanceVariable( info.aClass, [info.name UTF8String] );

    if ( !ivar )
        NSLog( @"Xprobe: could not find ivar \"%@\" in %@", info.name, info.obj);
    else
        if ( !xvalueUpdateIvar( info.obj, ivar, info.value ) )
            NSLog( @"Xprobe: unable to update ivar \"%@\" in %@", info.name, info.obj);

    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('E%d').outerHTML = '<span onclick=\\'this.id =\"E%d\"; "
     "sendClient( \"edit:\", \"%d,%@\" ); event.cancelBubble = true;\\'><i>%@</i></span>';",
     info.pathID, info.pathID, info.pathID, info.name, xvalueForIvar( info.obj, ivar, info.aClass )];

    [self writeString:html];
}

+ (void)property:(NSString *)input {
    struct _xinfo info = [self parseInput:input];

    objc_property_t prop = class_getProperty(info.aClass, [info.name UTF8String]);
    char *getter = property_copyAttributeValue(prop, "G");

    SEL sel = sel_registerName( getter ? getter : [info.name UTF8String] );
    if ( getter )
        free( getter );

    Method method = class_getInstanceMethod(info.aClass, sel);
    [self methodLinkFor:info method:method prefix:"P" command:"property:"];
}

+ (void)method:(NSString *)input {
    struct _xinfo info = [self parseInput:input];
    Method method = class_getInstanceMethod(info.aClass, NSSelectorFromString(info.name));
    if ( !method ) {
        method = class_getClassMethod(info.aClass, NSSelectorFromString(info.name));
        info.obj = info.aClass;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self methodLinkFor:info method:method prefix:"M" command:"method:"];
    });
}

+ (void)methodLinkFor:(struct _xinfo)info method:(Method)method
               prefix:(const char *)prefix command:(const char *)command {
    id result = method ? xvalueForMethod( info.obj, method ) : @"nomethod";

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('%s%d').outerHTML = '<span onclick=\\'"
     "this.id =\"%s%d\"; sendClient( \"%s\", \"%d,%@\" ); event.cancelBubble = true;\\'>%@ = ",
     prefix, info.pathID, prefix, info.pathID, command, info.pathID, info.name, info.name];

    if ( result && method && method_getTypeEncoding(method)[0] == '@' ) {
        XprobeMethod *subpath = [XprobeMethod withPathID:info.pathID];
        subpath.name = sel_getName(method_getName(method));
        [result xlinkForCommand:@"open" withPathID:[subpath xadd] into:html];
    }
    else
        [html appendFormat:@"%@", result ?: @"nil"];

    [html appendString:@"</span>';"];
    [self writeString:html];
}

+ (void)render:(NSString *)input {
    int pathID = [input intValue];
    __block NSData *data = nil;

    dispatch_sync(dispatch_get_main_queue(), ^{
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
        UIView *view = [xprobePaths[pathID] object];
        if ( ![view respondsToSelector:@selector(layer)] )
            return;

        UIGraphicsBeginImageContext(view.frame.size);
        [view.layer renderInContext:UIGraphicsGetCurrentContext()];
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        data = UIImagePNGRepresentation(image);
        UIGraphicsEndImageContext();
#else
        NSView *view = [xprobePaths[pathID] object];
        NSSize imageSize = view.bounds.size;
        if ( !imageSize.width || !imageSize.height )
            return;

        NSBitmapImageRep *bir = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:bir];
        data = [bir representationUsingType:NSPNGFileType properties:@{}];
#endif
    });

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('R%d').outerHTML = '<span id=\\'R%d\\'><p/>"
     "<img src=\\'data:image/png;base64,%@\\' onclick=\\'sendClient(\"_render:\", \"%d\"); "
     "event.cancelBubble = true;\\'><p/></span>';", pathID, pathID,
     [data base64EncodedStringWithOptions:0], pathID];
    [self writeString:html];
}

+ (void)_render:(NSString *)input {
    int pathID = [input intValue];
    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('R%d').outerHTML = '", pathID];
    [html xlinkForCommand:@"render" withPathID:pathID into:html];
    [html appendString:@"';"];
    [self writeString:html];
}

+ (void)class:(NSString *)className {
    XprobeClass *path = [XprobeClass new];
    if ( !(path.aClass = NSClassFromString(className)) )
        return;
    
    int pathID = [path xadd];
    NSMutableString *html = [NSMutableString new];
    
    [html appendFormat:@"$('%@').outerHTML = '", className];
    [path xlinkForCommand:@"close" withPathID:pathID into:html];
    
    [html appendString:@"<br/><table><tr><td class=\\'indent\\'/><td class=\\'drilldown\\'>"];
    [path xopenPathID:pathID into:html];
    
    [html appendString:@"</td></tr></table></span>';"];
    [self writeString:html];
}

+ (void)lookup:(NSString *)sym {
    Dl_info info;
    if ( dladdr( (void *)[sym substringFromIndex:1].integerValue, &info ) != 0 && info.dli_sname )
        [self writeString:[NSString stringWithFormat:@"$('%@').title = '%@';", sym,
         [xloadXprobeSwift("lookup:") demangle:[NSString stringWithUTF8String:info.dli_sname]]]];
}

@end
#pragma clang diagnostic pop

