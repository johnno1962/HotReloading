//
//  XprobeConsole.h
//  XprobePlugin
//
//  Created by John Holdsworth on 18/05/2014.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface XprobeConsole : NSObject <NSWindowDelegate,NSTextViewDelegate>

@property (nonatomic,strong) IBOutlet NSWindow *window;
@property (strong) NSString *package;

+ (void)backgroundConnectionService;
- (void)writeString:(NSString *)str;
- (void)execJS:(NSString *)js;

@end

extern __weak XprobeConsole *dotConsole;

