//
//  XprobePluginMenuController.m
//  XprobePlugin
//
//  Created by John Holdsworth on 01/05/2014.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//

#import "XprobePluginMenuController.h"

#import "XprobeConsole.h"
#import "Xprobe.h"

#import <WebKit/WebKit.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static NSString *DOT_PATH = @"/usr/local/bin/dot";

XprobePluginMenuController *xprobePlugin;

typedef NS_ENUM(int, DBGState) {
    DBGStateIdle,
    DBGStatePaused,
    DBGStateRunning
};

@interface DBGLLDBSession : NSObject
- (DBGState)state;
- (void)requestPause;
- (void)requestContinue;
- (void)evaluateExpression:(id)a0 threadID:(unsigned long)a1 stackFrameID:(unsigned long)a2 queue:(id)a3 completionHandler:(id)a4;
- (void)executeConsoleCommand:(id)a0 threadID:(unsigned long)a1 stackFrameID:(unsigned long)a2 ;
@end

@interface XprobePluginMenuController()

@property IBOutlet NSMenuItem *xprobeMenu;
@property IBOutlet NSWindow *webWindow;
@property IBOutlet WebView *webView;

@property NSButton *pauseResume;
@property NSTextView *debugger;
@property int continues;

@end

@implementation XprobePluginMenuController

+ (void)pluginDidLoad:(NSBundle *)plugin {
	static dispatch_once_t onceToken;
    NSString *currentApplicationName = [NSBundle mainBundle].infoDictionary[@"CFBundleName"];

    if ([currentApplicationName isEqual:@"Xcode"])
        dispatch_once(&onceToken, ^{
            xprobePlugin = [[self alloc] init];
            dispatch_async( dispatch_get_main_queue(), ^{
                #pragma clang diagnostic ignored "-Wnonnull"
                [xprobePlugin applicationDidFinishLaunching:nil];
            } );
        });
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    if ( ![[NSBundle bundleForClass:[self class]] loadNibNamed:@"XprobePluginMenuController" owner:self topLevelObjects:NULL] ) {
        if ( [[NSAlert alertWithMessageText:@"Xprobe Plugin:"
                              defaultButton:@"OK" alternateButton:@"Goto GitHub" otherButton:nil
                  informativeTextWithFormat:@"Could not load interface nib. This is a problem when using Alcatraz since Xcode6. Please download and build from the sources on GitHub."]
              runModal] == NSAlertAlternateReturn )
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/johnno1962/XprobePlugin"]];
        return;
    }

    [self.webWindow setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];

	NSMenu *productMenu = [[[NSApp mainMenu] itemWithTitle:@"Product"] submenu];
    [productMenu addItem:[NSMenuItem separatorItem]];
    [productMenu addItem:self.xprobeMenu];

    [XprobeConsole backgroundConnectionService];
}

- (NSString *)resourcePath {
    return [[NSBundle bundleForClass:[self class]] resourcePath];
}

static id lastKeyWindow;

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if ( [menuItem action] == @selector(graph:) )
        return dotConsole != nil;
    else
        return (lastKeyWindow = [NSApp keyWindow]) != nil &&
            [[lastKeyWindow delegate] respondsToSelector:@selector(document)];
}

- (IBAction)load:sender {
    Class injectorPlugin = NSClassFromString(@"InjectorPluginController");
    Class injectionPlugin = NSClassFromString(@"INPluginMenuController");

    if ( [injectorPlugin respondsToSelector:@selector(loadBundleForPlugin:)] &&
        [injectorPlugin loadBundleForPlugin:[self resourcePath]] ) {
        self.injectionPlugin = injectorPlugin;
        return;
    }
    else if ( [injectionPlugin respondsToSelector:@selector(loadXprobe:)] &&
        [injectionPlugin loadXprobe:[self resourcePath]] ) {
        self.injectionPlugin = injectionPlugin;
        return;
    }
    else
        self.injectionPlugin = [injectorPlugin respondsToSelector:@selector(evalCode:)] ? injectorPlugin : injectionPlugin;

    DBGLLDBSession *session = [lastKeyWindow valueForKeyPath:@"windowController.workspace"
                               ".executionEnvironment.selectedLaunchSession.currentDebugSession"];

    NSString *bundlePath = [NSString stringWithFormat:@"%@/SimBundle.loader", [self resourcePath]];
    NSString *MacOS = [[lastKeyWindow valueForKeyPath:@"windowController.workspace.executionEnvironment.currentLaunchSession"
                        ".launchParameters.filePathToBinary.pathString"] stringByDeletingLastPathComponent];
    if ( [MacOS hasSuffix:@"/Contents/MacOS"] ) {
        bundlePath = [NSString stringWithFormat:@"%@/OSXBundle.loader", [self resourcePath]];
        NSString *newLocation = [[MacOS stringByAppendingPathComponent:@"../Resources"]
                                 stringByAppendingPathComponent:bundlePath.lastPathComponent];
        [[NSFileManager defaultManager] removeItemAtPath:newLocation error:nil];
        [[NSFileManager defaultManager] copyItemAtPath:bundlePath toPath:newLocation error:nil];
        bundlePath = newLocation;
    }

    if ( !session )
        [[NSAlert alertWithMessageText:@"Xprobe Plugin:"
                        defaultButton:@"OK" alternateButton:nil otherButton:nil
             informativeTextWithFormat:@"Program is not running."] runModal];
    else {
        if ( session.state != DBGStatePaused )
            [session requestPause];
        [self performSelector:@selector(loadBundle:) withObject:bundlePath afterDelay:.1];
    }
}

- (void)loadBundle:(NSString *)bundlePath {
    DBGLLDBSession *session = [lastKeyWindow valueForKeyPath:@"windowController.workspace"
                               ".executionEnvironment.selectedLaunchSession.currentDebugSession"];

    if ( session.state != DBGStatePaused )
        [self performSelector:@selector(loadBundle:) withObject:bundlePath afterDelay:.1];
    else
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND,0), ^{
            NSString *loader = [NSString stringWithFormat:@"expr -l objc++ -- (void)[[NSBundle bundleWithPath:"
                                "@\"%@\"] load]\r", bundlePath];
            [session executeConsoleCommand:loader threadID:1 stackFrameID:0];
            dispatch_async(dispatch_get_main_queue(), ^{
                [session requestContinue];
            });
        });
}

- (IBAction)xcode:(id)sender {
    lastKeyWindow = [NSApp keyWindow];
    [Xprobe connectTo:"127.0.0.1" retainObjects:YES];
    [Xprobe search:@""];
}

- (IBAction)graph:(id)sender {

    if ( !dotConsole ) {
        [self load:self];
        [self.webWindow performSelector:@selector(makeKeyAndOrderFront:) withObject:self afterDelay:10.];
    }
    else if ( sender )
        [self.webWindow makeKeyAndOrderFront:self];
    else if ( ![self.webWindow isVisible] )
        return;

    if ( ![[NSFileManager defaultManager] fileExistsAtPath:DOT_PATH] ) {
        if ( [[NSAlert alertWithMessageText:@"XprobePlugin" defaultButton:@"OK" alternateButton:@"Go to site"
                                otherButton:nil informativeTextWithFormat:@"Object Graphs of your application "
               "can be displayed if you install \"dot\" from http://www.graphviz.org/."] runModal] == NSAlertAlternateReturn )
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://www.graphviz.org/download/"]];
    }
    else {
        [self runDot:@[@"graph.gv", @"-Txdot", @"-o/tmp/canviz.gv"]];
    }

    self.webWindow.title = [NSString stringWithFormat:@"%@ Object Graph", dotConsole ? dotConsole.package : @"Last"];
    NSURL *url = [NSURL fileURLWithPath:[[self resourcePath] stringByAppendingPathComponent:@"canviz.html"]];
    [[self.webView mainFrame] loadRequest:[NSURLRequest requestWithURL:url]];
    //[self.webView.mainFrame.frameView.documentView setWantsLayer:YES];
}

- (int)runDot:(NSArray *)args {
    NSTask *task = [NSTask new];
    task.launchPath = DOT_PATH;
    task.currentDirectoryPath = [self resourcePath];
    task.arguments = args;

    [task launch];
    [task waitUntilExit];
    return [task terminationStatus];
}

- (void)execJS:(NSString *)js {
    [[self.webView windowScriptObject] evaluateWebScript:js];
}

- (IBAction)graphviz:(id)sender {
    [self openResourceFile:@"graph.gv"];
}

- (void)openResourceFile:(NSString *)resource {
    NSString *file = [[self resourcePath] stringByAppendingPathComponent:resource];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:file]];
}

- (IBAction)graphpng:(id)sender {
    [self execJS:@"$('menus').style.display = 'none';"];
    NSView *view = self.webView.mainFrame.frameView.documentView;
    NSString *graph = [[self resourcePath] stringByAppendingPathComponent:@"graph.png"];

    NSBitmapImageRep *bir = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bir];
    NSData *data = [bir representationUsingType:NSPNGFileType properties:@{}];

    [data writeToFile:graph atomically:NO];
    [self openResourceFile:@"graph.png"];
    [self execJS:@"$('menus').style.display = 'block';"];
}

- (IBAction)graphpdf:(id)sender {
    [self runDot:@[@"-Tpdf", @"graph.gv", @"-o", @"graph.pdf"]];
    [self openResourceFile:@"graph.pdf"];
}

- (NSString *)webView:(WebView *)sender runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)defaultText initiatedByFrame:(WebFrame *)frame {
    [dotConsole writeString:prompt];
    [dotConsole writeString:defaultText];
    if ( [prompt isEqualToString:@"open:"] )
        dispatch_after(.1, dispatch_get_main_queue(), ^{
            NSString *scrollToVisble = [NSString stringWithFormat:@"window.scrollTo( 0, $('%@').offsetTop );", defaultText];
            [dotConsole.window makeKeyAndOrderFront:self];
            [dotConsole execJS:scrollToVisble];
        });
    return nil;
}

- (void)webView:(WebView *)sender runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WebFrame *)frame {
    [[NSAlert alertWithMessageText:@"XprobeConsole" defaultButton:@"OK" alternateButton:nil otherButton:nil
         informativeTextWithFormat:@"JavaScript Alert: %@", message] runModal];
}

- (IBAction)print:sender {
    NSPrintOperation *po=[NSPrintOperation printOperationWithView:self.webView.mainFrame.frameView.documentView];
    [[po printInfo] setOrientation:NSPaperOrientationLandscape];
    //[po setShowPanels:flags];
    [po runOperation];
}

@end

@implementation Xprobe(Seeding)

+ (NSArray *)xprobeSeeds {
    return lastKeyWindow ? @[lastKeyWindow] : @[];
}

@end

