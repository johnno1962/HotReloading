//
//  XprobeConsole.m
//  XprobePlugin
//
//  Created by John Holdsworth on 18/05/2014.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//

#import "XprobePluginMenuController.h"
#import "XprobeConsole.h"
#import "Xprobe.h"

#import <netinet/tcp.h>
#import <sys/socket.h>
#import <arpa/inet.h>
#import <sys/stat.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

__weak XprobeConsole *dotConsole;

static NSMutableDictionary *packagesOpen;

@interface XprobeConsole() <WebFrameLoadDelegate>

@property (nonatomic,strong) IBOutlet NSMenuItem *separator;
@property (nonatomic,strong) IBOutlet NSMenuItem *menuItem;

@property (nonatomic,assign) IBOutlet WebView *webView;
@property (nonatomic,assign) IBOutlet NSTextView *console;
@property (nonatomic,strong) IBOutlet NSSearchField *search;
@property (nonatomic,strong) IBOutlet NSSearchField *filter;
@property (nonatomic,strong) IBOutlet NSButton *snapshot;
@property (nonatomic,strong) IBOutlet NSButton *paused;
@property (nonatomic,strong) IBOutlet NSButton *graph;
@property (nonatomic,strong) IBOutlet NSButton *print;

@property (strong) NSMutableArray *lineBuffer;
@property (strong) NSMutableString *incoming;
@property (strong) NSLock *lock;
@property int clientSocket;

@end

@implementation XprobeConsole

static int serverSocket;

+ (void)backgroundConnectionService {

    struct sockaddr_in serverAddr;

#ifndef INJECTION_ADDR
#define INJECTION_ADDR INADDR_ANY
#endif

    serverAddr.sin_family = AF_INET;
    serverAddr.sin_addr.s_addr = htonl(INJECTION_ADDR);
    serverAddr.sin_port = htons(XPROBE_PORT);

    int optval = 1;
    if ( (serverSocket = socket(AF_INET, SOCK_STREAM, 0)) < 0 )
        NSLog(@"XprobeConsole: Could not open service socket: %s", strerror( errno ));
    else if ( fcntl(serverSocket, F_SETFD, FD_CLOEXEC) < 0 )
        NSLog(@"XprobeConsole: Could not set close exec: %s", strerror( errno ));
    else if ( setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof optval) < 0 )
        NSLog(@"XprobeConsole: Could not set socket option: %s", strerror( errno ));
    else if ( setsockopt( serverSocket, IPPROTO_TCP, TCP_NODELAY, (void *)&optval, sizeof(optval)) < 0 )
        NSLog(@"XprobeConsole: Could not set socket option: %s", strerror( errno ));
    else if ( bind( serverSocket, (struct sockaddr *)&serverAddr, sizeof serverAddr ) < 0 )
        NSLog(@"XprobeConsole: Could not bind service socket: %s. "
              "Kill any \"ibtoold\" processes and restart.", strerror( errno ));
    else if ( listen( serverSocket, 5 ) < 0 )
        NSLog(@"XprobeConsole: Service socket would not listen: %s", strerror( errno ));
    else
        [self performSelectorInBackground:@selector(service) withObject:nil];
}

+ (void)service {

    NSLog(@"XprobeConsole: Waiting for connections...");

    while ( serverSocket ) {
        struct sockaddr_in clientAddr;
        socklen_t addrLen = sizeof clientAddr;

        int clientSocket = accept( serverSocket, (struct sockaddr *)&clientAddr, &addrLen );
        uint32_t magic;

        NSLog(@"XprobeConsole: Connection from %s:%d", inet_ntoa(clientAddr.sin_addr), ntohs(clientAddr.sin_port));

        int optval = 1;
        if ( setsockopt( clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &optval, sizeof(optval) ) < 0 )
            NSLog( @"XprobeConsole: Could not set SO_NOSIGPIPE: %s", strerror( errno ) );

        if ( clientSocket > 0 &&
                read(clientSocket, &magic, sizeof magic)==sizeof magic && magic == XPROBE_MAGIC )
            (void)[[XprobeConsole alloc] initClient:clientSocket];
        else {
            close( clientSocket );
            [NSThread sleepForTimeInterval:.5];
        }
    }
}

- (NSString *)readString {
    uint32_t length;

    if ( read(self.clientSocket, &length, sizeof length) != sizeof length ) {
        NSLog( @"XprobeConsole: Socket read error %s", strerror(errno) );
        return nil;
    }

    ssize_t sofar = 0, bytes;
    char *buff = (char *)malloc(length+1);

    while ( buff && sofar < length && (bytes = read(self.clientSocket, buff+sofar, length-sofar )) > 0 )
        sofar += bytes;

    if ( sofar < length ) {
        NSLog( @"XprobeConsole: Socket read error %d/%d: %s", (int)sofar, length, strerror(errno) );
        return nil;
    }

    if ( buff )
        buff[sofar] = '\000';

    NSString *str = [NSString stringWithUTF8String:buff];
    free( buff );
    return str;
}

- (void)writeString:(NSString *)str {
    const char *data = [str UTF8String];
    uint32_t length = (uint32_t)strlen(data);

    if ( !self.clientSocket )
        NSLog( @"XprobeConsole: Write to closed" );
    else if ( write(self.clientSocket, &length, sizeof length ) != sizeof length ||
                write(self.clientSocket, data, length ) != length )
        NSLog( @"XprobeConsole: Socket write error %s", strerror(errno) );
}

- (void)execJS:(NSString *)js {
    [[self.webView windowScriptObject] evaluateWebScript:js];
}

- (void)serviceClient {
    NSString *dhtmlOrDotOrTrace;

    while ( (dhtmlOrDotOrTrace = [self readString]) ) {
        //NSLog( @"%@", dhtmlOrDotOrTrace );

        if ( [dhtmlOrDotOrTrace hasPrefix:@"$("] )
            dispatch_async(dispatch_get_main_queue(), ^{
                [self execJS:dhtmlOrDotOrTrace];
            });
        else if ( [dhtmlOrDotOrTrace hasPrefix:@"digraph "] ) {
            NSString *saveTo = [[[NSBundle bundleForClass:[self class]] resourcePath]
                                stringByAppendingPathComponent:@"graph.gv"];
            [dhtmlOrDotOrTrace writeToFile:saveTo atomically:NO encoding:NSUTF8StringEncoding error:NULL];
            dotConsole = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                [xprobePlugin graph:nil];
            });
        }
        else if ( [dhtmlOrDotOrTrace hasPrefix:@"updates: "] )
            dispatch_async(dispatch_get_main_queue(), ^{
                [xprobePlugin execJS:[dhtmlOrDotOrTrace substringFromIndex:9]];
            });
        else if ( [dhtmlOrDotOrTrace hasPrefix:@"open: "] )
            [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[dhtmlOrDotOrTrace substringFromIndex:6]]];
        else if ( [dhtmlOrDotOrTrace hasPrefix:@"snapshot: "] ) {
            NSData *data = [[NSData alloc] initWithBase64EncodedString:[dhtmlOrDotOrTrace substringFromIndex:10] options:0];
            NSString *snapfile = [NSTemporaryDirectory() stringByAppendingPathComponent:@"snapshot.html.gz"];
            [data writeToFile:snapfile atomically:NO];
            system([NSString stringWithFormat:@"gunzip -f %@", snapfile].UTF8String);
            NSString *snaphtml = [NSTemporaryDirectory() stringByAppendingPathComponent:@"snapshot.html"];
            [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:snaphtml]];
        }
        else {
            [self insertText:dhtmlOrDotOrTrace];
            [self insertText:@"\n"];
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.window.title = [NSString stringWithFormat:@"Disconnected from: %@", self.package];
    });
    self.clientSocket = 0;
}

- (id)initClient:(int)clientSocket {

    if ( self.clientSocket ) {
        close( self.clientSocket );
        [NSThread sleepForTimeInterval:.5];
    }

    self.clientSocket = clientSocket;
    self.package = [self readString];
    if  ( !self.package )
        return nil;

    if ( !packagesOpen )
        packagesOpen = [NSMutableDictionary new];
    
    if ( !packagesOpen[self.package] ) {
        packagesOpen[self.package] = self = [super init];

        dispatch_sync(dispatch_get_main_queue(), ^{
            if ( ![[NSBundle bundleForClass:[self class]] loadNibNamed:@"XprobeConsole" owner:self topLevelObjects:NULL] )
                if ( [[NSAlert alertWithMessageText:@"Xprobe Plugin:"
                                      defaultButton:@"OK" alternateButton:@"Goto GitHub" otherButton:nil
                          informativeTextWithFormat:@"Could not load interface nib. If problems persist, please download and build from the sources on GitHub."]
                      runModal] == NSAlertAlternateReturn )
                    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/johnno1962/XprobePlugin"]];

            [self.window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];

            self.menuItem.title = [NSString stringWithFormat:@"Xprobe: %@", self.package];
            NSMenu *windowMenu = [self windowMenu];
            NSInteger where = [windowMenu indexOfItemWithTitle:@"Bring All to Front"];
            if ( where <= 0 )
                NSLog( @"XprobeConsole: Could not locate Window menu item" );
            else {
                [windowMenu insertItem:self.separator atIndex:where+1];
                [windowMenu insertItem:self.menuItem atIndex:where+2];
            }

            self.webView.wantsLayer = YES;

            NSRect frame = self.webView.frame;
            NSSize size = self.search.frame.size;
            frame.origin.x = frame.size.width - size.width - 30;
            frame.origin.y = frame.size.height - size.height - 20;
            frame.size = size;
            self.search.frame = frame;
            [self.webView addSubview:self.search];

            frame = self.webView.frame;
            size = self.print.frame.size;
            frame.origin.x = frame.size.width - size.width - 20;
            frame.origin.y = 4;
            frame.size = size;
            self.print.frame = frame;
            [self.webView addSubview:self.print];
            frame.origin.x -= size.width;
            self.graph.frame = frame;
            [self.webView addSubview:self.graph];

            frame.origin.x -= frame.size.width = self.snapshot.frame.size.width;
            self.snapshot.frame = frame;
            [self.webView addSubview:self.snapshot];
        });
    }
    else {
        self = packagesOpen[self.package];
        self.clientSocket = clientSocket; ////
    }

    dispatch_sync(dispatch_get_main_queue(), ^{
        self.window.title = [NSString stringWithFormat:@"Connected to: %@", self.package];

        NSURL *pageURL = [[NSBundle bundleForClass:[self class]] URLForResource:@"xprobe" withExtension:@"html"];
        if ( [self.console.string length] )
            [self insertText:[NSString stringWithFormat:@"\n\n"]];
        [self insertText:[NSString stringWithFormat:@"Method Trace output from %@ ...\n", self.package]];

        self.webView.frameLoadDelegate = self;
        [[self.webView mainFrame] loadRequest:[NSURLRequest requestWithURL:pageURL]];

        [self.window makeFirstResponder:self.search];
        [self.window makeKeyAndOrderFront:self];
        self.lineBuffer = [NSMutableArray new];
        [NSApp activateIgnoringOtherApps:YES];
    });

    return self;
}

- (NSMenu *)windowMenu {
    return [[[NSApp mainMenu] itemWithTitle:@"Window"] submenu];
}

- (void)webView:(WebView *)aWebView didFinishLoadForFrame:(WebFrame *)frame {
    self.webView.frameLoadDelegate = nil;
    [self performSelectorInBackground:@selector(serviceClient) withObject:nil];
}

- (void)webView:(WebView *)webView addMessageToConsole:(NSDictionary *)message; {
    [[NSAlert alertWithMessageText:@"XprobeConsole" defaultButton:@"OK" alternateButton:nil otherButton:nil
         informativeTextWithFormat:@"JavaScript Error: %@", message] runModal];
}

- (void)webView:(WebView *)sender runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WebFrame *)frame {
    [[NSAlert alertWithMessageText:@"XprobeConsole" defaultButton:@"OK" alternateButton:nil otherButton:nil
         informativeTextWithFormat:@"JavaScript Alert: %@", message] runModal];
}

- (void)webView:(WebView *)aWebView decidePolicyForNavigationAction:(NSDictionary *)actionInformation
		request:(NSURLRequest *)request frame:(WebFrame *)frame decisionListener:(id < WebPolicyDecisionListener >)listener {
    if ( [request.URL isFileURL] )
        [listener use];
    else {
        [[NSWorkspace sharedWorkspace] openURL:request.URL];
        [listener ignore];
    }
}

- (NSString *)webView:(WebView *)sender runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)defaultText initiatedByFrame:(WebFrame *)frame {

    if ( !self.clientSocket ) {
        [[NSAlert alertWithMessageText:@"XprobeConsole" defaultButton:@"OK" alternateButton:nil otherButton:nil
             informativeTextWithFormat:@"No longer connected to %@", self.package] runModal];
        return nil;
    }

    Class injectionPlugin = xprobePlugin.injectionPlugin;
    BOOL findsSource = [injectionPlugin respondsToSelector:@selector(sourceForClass:)];
    if ( [prompt isEqualToString:@"known:"] )
        return findsSource ? [injectionPlugin sourceForClass:defaultText] : nil;
    else if ( [prompt isEqualToString:@"source:"] ) {
        if ( findsSource ) {
            NSString *file = [injectionPlugin sourceForClass:defaultText];
            if ( file )
                [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:file]];
        }
        return nil;
    }
    else if ( [prompt isEqualToString:@"params:"] ) {
        if ( [injectionPlugin respondsToSelector:@selector(showParams)] )
            [injectionPlugin showParams];
        return nil;
    }

    [self writeString:prompt];
    [self writeString:defaultText];

    if ( [prompt isEqualToString:@"eval:"] ) {
        if ( !injectionPlugin || ![injectionPlugin respondsToSelector:@selector(evalCode:)] )
            [[NSAlert alertWithMessageText:@"XprobeConsole" defaultButton:@"OK" alternateButton:nil otherButton:nil
                 informativeTextWithFormat:@"Code eval requires recent injectionforxcode plugin"] runModal];
        else
            [injectionPlugin evalCode:defaultText];
    }

    return nil;
}

- (NSString *)filterLinesByCurrentRegularExpression:(NSArray *)lines {
    NSMutableString *out = [[NSMutableString alloc] init];
    NSRegularExpression *filterRegexp = [NSRegularExpression regularExpressionWithPattern:self.filter.stringValue
                                                            options:NSRegularExpressionCaseInsensitive error:NULL];
    for ( NSString *line in lines ) {
        if ( !filterRegexp ||
            [filterRegexp rangeOfFirstMatchInString:line options:0
                                              range:NSMakeRange(0, [line length])].location != NSNotFound ) {
                [out appendString:line];
                [out appendString:@"\n"];
            }
    }

    return out;
}

- (IBAction)search:(NSSearchField *)sender {
    [self writeString:@"search:"];
    [self writeString:sender.stringValue];
}

- (IBAction)filterChange:sender {
    self.console.string = [self filterLinesByCurrentRegularExpression:self.lineBuffer];
}

- (void)insertText:(NSString *)output {
    if ( !self.lock )
        self.lock = [[NSLock alloc] init];

    [self.lock lock];
    if ( !self.incoming )
        self.incoming = [[NSMutableString alloc] init];
    [self.incoming appendString:output];
    [self.lock unlock];

    [self performSelectorOnMainThread:@selector(insertIncoming) withObject:nil waitUntilDone:NO];
}

- (void)insertIncoming {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];

    if ( !self.incoming )
        return;

    [self.lock lock];
    NSMutableArray *newLlines = [[self.incoming componentsSeparatedByString:@"\n"] mutableCopy];
    [self.incoming setString:@""];
    [self.lock unlock];

    NSUInteger lineCount = [newLlines count];
    if ( lineCount && [newLlines[lineCount-1] length] == 0 )
        [newLlines removeObjectAtIndex:lineCount-1];

    [self.lineBuffer addObjectsFromArray:newLlines];

    if ( ![self.paused state] ) {
        NSString *filtered = [self filterLinesByCurrentRegularExpression:newLlines];
        if ( [filtered length] ) {
            [self.console setSelectedRange:NSMakeRange([self.console.string length], 0)];
            [self.console insertText:filtered];
        }
    }
}

- (IBAction)pausePlay:sender {
    if ( [self.paused state] ) {
        [self.paused setImage:[self imageNamed:@"play"]];
    }
    else {
        [self.paused setImage:[self imageNamed:@"pause"]];
        [self filterChange:self];
    }
}

- (NSImage *)imageNamed:(NSString *)name {
    return [[NSImage alloc] initWithContentsOfFile:[[NSBundle bundleForClass:[self class]]
                                                    pathForResource:name ofType:@"png"]];
}

- (IBAction)graph:sender {
    [xprobePlugin graph:sender];
}

- (IBAction)print:sender {
    NSPrintInfo *pi = [NSPrintInfo sharedPrintInfo];
    pi.topMargin = 50;
    pi.leftMargin = 25;
    pi.rightMargin = 25;
    pi.bottomMargin = 50;
    pi.horizontallyCentered = FALSE;
    [[NSPrintOperation printOperationWithView:self.webView.mainFrame.frameView.documentView
                                    printInfo:pi] runOperation];
}

- (IBAction)snapshot:(id)sender  {
    [self writeString:@"snapshot:"];
    [self writeString:@"snapshot.html.gz"];
}

- (void)windowWillClose:(NSNotification *)notification {
    return; // better to leave available for graphing

//    close( self.clientSocket );
//    self.clientSocket = 0;
//    self.webView.UIDelegate = nil;
//    [self.webView close];
//
//    NSMenu *windowMenu = [self windowMenu];
//    if ( [windowMenu indexOfItem:self.separator] != -1 )
//        [windowMenu removeItem:self.separator];
//    if ( [windowMenu indexOfItem:self.menuItem] != -1 )
//        [windowMenu removeItem:self.menuItem];
//
//    [packagesOpen removeObjectForKey:[NSString stringWithFormat:@"Xprobe: %@", self.package]];
}

@end
