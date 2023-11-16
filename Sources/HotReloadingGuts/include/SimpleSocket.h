//
//  SimpleSocket.h
//  InjectionIII
//
//  Created by John Holdsworth on 06/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloadingGuts/include/SimpleSocket.h#16 $
//

#import <Foundation/Foundation.h>
#import <arpa/inet.h>

@interface SimpleSocket : NSObject {
@protected
    int clientSocket;
}

@property BOOL isLocalClient;

+ (void)startServer:(NSString *_Nonnull)address;
+ (void)runServer:(NSString *_Nonnull)address;
+ (int)error:(NSString *_Nonnull)message;

+ (instancetype _Nullable)connectTo:(NSString *_Nonnull)address;
+ (BOOL)parseV4Address:(NSString *_Nonnull)address into:(struct sockaddr_storage *_Nonnull)serverAddr;

+ (void)multicastServe:(const char *_Nonnull)multicast port:(const char *_Nonnull)port;
+ (NSString *_Nonnull)getMulticastService:(const char *_Nonnull)multicast
                                     port:(const char *_Nonnull)port
                                  message:(const char *_Nonnull)format;

- (instancetype _Nonnull)initSocket:(int)socket;

- (void)run;
- (void)runInBackground;

- (int)readInt;
- (void * _Nullable)readPointer;
- (NSData *_Nullable)readData;
- (NSString *_Nullable)readString;
- (BOOL)readBytes:(void * _Nonnull)buffer length:(size_t)length cmd:(SEL _Nonnull)cmd;

- (BOOL)writeInt:(int)length;
- (BOOL)writePointer:(void * _Nullable)pointer;
- (BOOL)writeData:(NSData *_Nonnull)data;
- (BOOL)writeString:(NSString *_Nonnull)string;
- (BOOL)writeCommand:(int)command withString:(NSString *_Nullable)string;

@end
