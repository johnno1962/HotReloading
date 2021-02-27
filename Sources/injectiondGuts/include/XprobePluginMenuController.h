//
//  XprobePluginMenuController.h
//  XprobePlugin
//
//  Created by John Holdsworth on 01/05/2014.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@interface XprobePluginMenuController : NSObject <NSApplicationDelegate>

@property Class injectionPlugin;

- (IBAction)graph:(id)sender;
- (void)execJS:(NSString *)js;

@end

extern XprobePluginMenuController *xprobePlugin;

#import "BundleProtocol.h"
