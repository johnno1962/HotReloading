//
//  SignerService.m
//  InjectionIII
//
//  Created by John Holdsworth on 06/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/injectiondGuts/SignerService.m#15 $
//

#import "SignerService.h"

@implementation SignerService

+ (BOOL)codesignDylib:(NSString *)dylib identity:(NSString *)identity {
    static NSString *adhocSign = @"-";
    const char *envIdentity = getenv("EXPANDED_CODE_SIGN_IDENTITY")
                            ?: getenv("CODE_SIGN_IDENTITY");
    const char *toolchainDir = getenv("TOOLCHAIN_DIR") ?:
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain";
    if (envIdentity && strlen(envIdentity)) {
        identity = [NSString stringWithFormat:@"\"%s\"", envIdentity];
        NSLog(@"Signing identity from environment: %@", identity);
    }
    NSString *command = [NSString stringWithFormat:@""
                         "(export CODESIGN_ALLOCATE=\"%s/usr/bin/codesign_allocate\"; "
                         "if /usr/bin/file \"%@\" | /usr/bin/grep ' shared library ' >/dev/null;"
                         "then /usr/bin/codesign --force -s %@ \"%@\";"
                         "else exit 1; fi)",
                         toolchainDir, dylib, identity ?: adhocSign, dylib];
    if (system(command.UTF8String) >> 8 == EXIT_SUCCESS)
        return TRUE;
    NSLog(@"Codesigning failed with command: %@", command);
    return FALSE;
}

#if 0 // no longer used
- (void)runInBackground {
    char __unused skip, buffer[1000];
    buffer[read(clientSocket, buffer, sizeof buffer-1)] = '\000';
    NSString *path = [[NSString stringWithUTF8String:buffer] componentsSeparatedByString:@" "][1];

    if ([[self class] codesignDylib:path identity:nil]) {
        snprintf(buffer, sizeof buffer, "HTTP/1.0 200 OK\r\n\r\n");
        write(clientSocket, buffer, strlen(buffer));
    }
}
#endif

@end
