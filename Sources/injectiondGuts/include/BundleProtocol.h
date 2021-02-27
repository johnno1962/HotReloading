//
//  $Id: //depot/InjectionPluginLite/Classes/BundleProtocol.h#4 $
//  InjectionPlugin
//
//  Created by John Holdsworth on 11/11/2014.
//
//

#ifndef InjectionPlugin_BundleProtocol_h
#define InjectionPlugin_BundleProtocol_h

#define INSTATUS_SERVICE @"injectionStatus"

typedef NS_ENUM(int,INBundleState) {
    INBundleStateIdle,
    INBundleStateConnected,
    INBundleStateBuilding,
    INBundleStateInjected,
    INBundleStateCompileError,
    INBundleStateLoadingError
};

@protocol INBundleChanged
- (oneway void)fileChanged:(NSString *)filePath;
@end

@protocol INBundleProtocol

- (oneway void)watchWorkspace:(NSString *)workspacePath notifying:(id<INBundleChanged>)plugin;
- (oneway void)unwatchWorkspace:(NSString *)workspacePath;
- (oneway void)injectionState:(INBundleState)newState;

@end

@protocol INInjectionPlugin
+ (BOOL)loadBundleForPlugin:(NSString *)resourcePath;
+ (NSString *)sourceForClass:(NSString *)className;
+ (BOOL)loadXprobe:(NSString *)resourcePath;
+ (void)evalCode:(NSString *)code;
+ (void)showParams;
@end


#endif
