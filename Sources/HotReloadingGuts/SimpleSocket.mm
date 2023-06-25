//
//  SimpleSocket.mm
//  InjectionIII
//
//  Created by John Holdsworth on 06/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloadingGuts/SimpleSocket.mm#36 $
//
//  Server and client primitives for networking through sockets
//  more esailly written in Objective-C than Swift. Subclass to
//  implement service or client that runs on a background thread
//  implemented by overriding the "runInBackground" method.
//

#if DEBUG || !SWIFT_PACKAGE
#import "SimpleSocket.h"

#include <sys/socket.h>
#include <netinet/tcp.h>
#include <netdb.h>

#if 0
#define SLog NSLog
#else
#define SLog while(0) NSLog
#endif

@implementation SimpleSocket

+ (int)error:(NSString *)message {
    NSLog([@"%@/" stringByAppendingString:message],
          self, strerror(errno));
    return -1;
}

+ (void)startServer:(NSString *)address {
    [self performSelectorInBackground:@selector(runServer:) withObject:address];
}

+ (void)runServer:(NSString *)address {
    struct sockaddr_storage serverAddr;
    [self parseV4Address:address into:&serverAddr];

    int serverSocket = [self newSocket:serverAddr.ss_family];
    if (serverSocket < 0)
        return;

    if (bind(serverSocket, (struct sockaddr *)&serverAddr, serverAddr.ss_len) < 0)
        [self error:@"Could not bind service socket: %s"];
    else if (listen(serverSocket, 5) < 0)
        [self error:@"Service socket would not listen: %s"];
    else
        while (TRUE) {
            struct sockaddr_storage clientAddr;
            socklen_t addrLen = sizeof clientAddr;

            int clientSocket = accept(serverSocket, (struct sockaddr *)&clientAddr, &addrLen);
            if (clientSocket > 0) {
                @autoreleasepool {
                    struct sockaddr_in *v4Addr = (struct sockaddr_in *)&clientAddr;
                    NSLog(@"Connection from %s:%d\n",
                          inet_ntoa(v4Addr->sin_addr), ntohs(v4Addr->sin_port));
                    [[[self alloc] initSocket:clientSocket] run];
                }
            }
            else
                [NSThread sleepForTimeInterval:.5];
        }
}

+ (instancetype)connectTo:(NSString *)address {
    struct sockaddr_storage serverAddr;
    [self parseV4Address:address into:&serverAddr];

    int clientSocket = [self newSocket:serverAddr.ss_family];
    if (clientSocket < 0)
        return nil;

    if (connect(clientSocket, (struct sockaddr *)&serverAddr, serverAddr.ss_len) < 0) {
        [self error:@"Could not connect: %s"];
        return nil;
    }

    return [[self alloc] initSocket:clientSocket];
}

+ (int)newSocket:(sa_family_t)addressFamily {
    int optval = 1, newSocket;
    if ((newSocket = socket(addressFamily, SOCK_STREAM, 0)) < 0)
        [self error:@"Could not open service socket: %s"];
    else if (setsockopt(newSocket, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof optval) < 0)
        [self error:@"Could not set SO_REUSEADDR: %s"];
    else if (setsockopt(newSocket, SOL_SOCKET, SO_NOSIGPIPE, (void *)&optval, sizeof(optval)) < 0)
        [self error:@"Could not set SO_NOSIGPIPE: %s"];
    else if (setsockopt(newSocket, IPPROTO_TCP, TCP_NODELAY, (void *)&optval, sizeof(optval)) < 0)
        [self error:@"Could not set TCP_NODELAY: %s"];
    else if (fcntl(newSocket, F_SETFD, FD_CLOEXEC) < 0)
        [self error:@"Could not set FD_CLOEXEC: %s"];
    else
        return newSocket;
    return -1;
}

/**
 * Available formats
 * @"<host>[:<port>]"
 * where <host> can be NNN.NNN.NNN.NNN or hostname, empty for localhost or * for all interfaces
 * The default port is 80 or a specific number to bind or an empty string to allocate any port
 */
+ (BOOL)parseV4Address:(NSString *)address into:(struct sockaddr_storage *)serverAddr {
    NSArray<NSString *> *parts = [address componentsSeparatedByString:@":"];

    struct sockaddr_in *v4Addr = (struct sockaddr_in *)serverAddr;
    bzero(v4Addr, sizeof *v4Addr);

    v4Addr->sin_family = AF_INET;
    v4Addr->sin_len = sizeof *v4Addr;
    v4Addr->sin_port = htons(parts.count > 1 ? parts[1].intValue : 80);

    const char *host = parts[0].UTF8String;

    if (!host[0])
        v4Addr->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    else if (host[0] == '*')
        v4Addr->sin_addr.s_addr = htonl(INADDR_ANY);
    else if (isdigit(host[0]))
        v4Addr->sin_addr.s_addr = inet_addr(host);
    else if (struct hostent *hp = gethostbyname2(host, v4Addr->sin_family))
        memcpy((void *)&v4Addr->sin_addr, hp->h_addr, hp->h_length);
    else {
        [self error:[NSString stringWithFormat:@"Unable to look up host for %@", address]];
        return FALSE;
    }

    return TRUE;
}

- (instancetype)initSocket:(int)socket {
    if ((self = [super init])) {
        clientSocket = socket;
    }
    return self;
}

- (void)run {
    [self performSelectorInBackground:@selector(runInBackground) withObject:nil];
}

- (void)runInBackground {
    [[self class] error:@"-[SimpleSocket runInBackground] not implemented in subclass"];
}

- (BOOL)readBytes:(void *)buffer length:(size_t)length cmd:(SEL)cmd {
    size_t rd, ptr = 0;
    SLog(@"#%d <- %lu [%p] %s",
         clientSocket, length, buffer, sel_getName(cmd));
    while (ptr < length &&
       (rd = read(clientSocket, (char *)buffer+ptr, length-ptr)) > 0)
        ptr += rd;
    if (ptr < length) {
        NSLog(@"[%@ %s:%p length:%lu] error: %lu %s",
              self, sel_getName(cmd), buffer, length, ptr, strerror(errno));
        return FALSE;
    }
    return TRUE;
}

- (int)readInt {
    int32_t anint = ~0;
    if (![self readBytes:&anint length:sizeof anint cmd:_cmd])
        return ~0;
    SLog(@"#%d <- %d", clientSocket, anint);
    return anint;
}

- (void *)readPointer {
    void *aptr = (void *)~0;
    if (![self readBytes:&aptr length:sizeof aptr cmd:_cmd])
        return aptr;
    SLog(@"#%d <- %p", clientSocket, aptr);
    return aptr;
}

- (NSData *)readData {
    size_t length = [self readInt];
    void *bytes = malloc(length);
    if (!bytes || ![self readBytes:bytes length:length cmd:_cmd])
        return nil;
    return [NSData dataWithBytesNoCopy:bytes length:length freeWhenDone:YES];
}

- (NSString *)readString {
    NSString *str = [[NSString alloc] initWithData:[self readData]
                                          encoding:NSUTF8StringEncoding];
    SLog(@"#%d <- %d '%@'", clientSocket, (int)str.length, str);
    return str;
}

- (BOOL)writeBytes:(const void *)buffer length:(size_t)length cmd:(SEL)cmd {
    size_t wr, ptr = 0;
    SLog(@"#%d <- %lu [%p] %s",
         clientSocket, length, buffer, sel_getName(cmd));
    while (ptr < length &&
       (wr = write(clientSocket, (char *)buffer+ptr, length-ptr)) > 0)
        ptr += wr;
    if (ptr < length) {
        NSLog(@"[%@ %s:%p length:%lu] error: %lu %s",
              self, sel_getName(cmd), buffer, length, ptr, strerror(errno));
        return FALSE;
    }
    return TRUE;
}

- (BOOL)writeInt:(int)length {
    SLog(@"#%d %d ->", clientSocket, length);
    return [self writeBytes:&length length:sizeof length cmd:_cmd];
}

- (BOOL)writePointer:(void *)ptr {
    SLog(@"#%d %p ->", clientSocket, ptr);
    return [self writeBytes:&ptr length:sizeof ptr cmd:_cmd];
}

- (BOOL)writeData:(NSData *)data {
    uint32_t length = (uint32_t)data.length;
    SLog(@"#%d [%d] ->", clientSocket, length);
    return [self writeInt:length] &&
        [self writeBytes:data.bytes length:length cmd:_cmd];
}

- (BOOL)writeString:(NSString *)string {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    SLog(@"#%d %d '%@' ->", clientSocket, (int)data.length, string);
    return [self writeData:data];
}

- (BOOL)writeCommand:(int)command withString:(NSString *)string {
    return [self writeInt:command] &&
        (!string || [self writeString:string]);
}

- (void)dealloc {
    close(clientSocket);
}

/// Hash used to differentiate HotReloading users on network.
/// Derived from path to source file in project's DerivedData.
+ (int)multicastHash {
    #ifdef INJECTION_III_APP
    const char *key = NSHomeDirectory().UTF8String;
    #else
    NSString *file = [NSString stringWithUTF8String:__FILE__];
    const char *key = [file
       stringByReplacingOccurrencesOfString: @"(/Users/[^/]+).*"
           withString: @"$1" options: NSRegularExpressionSearch
               range: NSMakeRange(0, file.length)].UTF8String;
    #endif
    int hash = 0;
    for (size_t i=0, len = strlen(key); i<len; i++)
        hash += (i+3)%15*key[i];
    return hash;
}

struct multicast_socket_packet {
    int version, hash;
    char host[256];
};

/// Used for HotReloading clients to find their controlling Mac.
/// @param multicast MULTICAST address to use
/// @param port Port identifier of form ":NNNN"
+ (void)multicastServe:(const char *)multicast port:(const char *)port {
    #ifdef DEVELOPER_HOST
    if (isdigit(DEVELOPER_HOST[0]))
        return;
    #endif

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY); /* N.B.: differs from sender */
    if (const char *colon = index(port, ':'))
        port = colon+1;
    addr.sin_port = htons(atoi(port));

    u_int yes = 1;
//    u_char ttl = 3;

    /* use setsockopt() to request that the kernel join a multicast group */
    struct ip_mreq mreq;
    mreq.imr_multiaddr.s_addr = inet_addr(multicast);
    mreq.imr_interface.s_addr = htonl(INADDR_ANY);

    /* create what looks like an ordinary UDP socket */
    int multicastSocket;
    if ((multicastSocket = socket(AF_INET, SOCK_DGRAM, 0)) < 0)
        [self error:@"Could not get mutlicast socket: %s"];
    else if (fcntl(multicastSocket, F_SETFD, FD_CLOEXEC) < 0)
        [self error:@"Could not set close exec: %s"];
    else if (setsockopt(multicastSocket, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes)) < 0)
        [self error:@"Could not reuse mutlicast socket addr: %s"];
    else if (bind(multicastSocket, (struct sockaddr *)&addr, sizeof(addr)) < 0)
        [self error:@"Could not bind mutlicast socket addr: %s. "
         "Once this starts occuring, a reboot may be necessary. "
         "Or, you can hardcode the IP address of your Mac as the "
         "the value for 'hostname' in HotReloading/Package.swift."];
//    else if (setsockopt(multicastSocket, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl)) < 0)
//        [self error:@"%s: Could set multicast socket ttl: %s", INJECTION_APPNAME, strerror(errno)];
    else if (setsockopt(multicastSocket, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq)) < 0)
        [self error:@"Could not add membersip of multicast socket: %s"];
    else
        [self performSelectorInBackground:@selector(multicastListen:)
                               withObject:[NSNumber numberWithInt:multicastSocket]];
}

/// Listens for clients looking to connect and if the hash matches, replies.
/// @param socket Multicast socket as NSNumber
+ (void)multicastListen:(NSNumber *)socket {
    int multicastSocket = [socket intValue];
    while (multicastSocket) {
        struct sockaddr_in addr;
        unsigned addrlen = sizeof(addr);
        struct multicast_socket_packet msgbuf;

        if (recvfrom(multicastSocket, &msgbuf, sizeof msgbuf, 0,
                     (struct sockaddr *)&addr, &addrlen) < sizeof msgbuf) {
            [self error:@"Could not receive from multicast: %s"];
            sleep(1);
            continue;
        }

        NSLog(@"%@: Multicast recvfrom %s (%s) %d c.f. %d\n",
              self, msgbuf.host, inet_ntoa(addr.sin_addr),
              [self multicastHash], msgbuf.hash);

        gethostname(msgbuf.host, sizeof msgbuf.host);
        if ([self multicastHash] == msgbuf.hash &&
            sendto(multicastSocket, &msgbuf, sizeof msgbuf, 0,
                   (struct sockaddr *)&addr, addrlen) < sizeof msgbuf) {
            [self error:@"Could not send to multicast: %s"];
            sleep(1);
        }
    }
}

/// Client end of multicast means of determining address of server
/// @param multicast Multicast IP address to use.
/// @param port Port number as string.
/// @param format Format for connecting message.
+ (const char *)getMulticastService:(const char *)multicast
    port:(const char *)port message:(const char *)format {
    #ifdef DEVELOPER_HOST
    if (isdigit(DEVELOPER_HOST[0]))
        return DEVELOPER_HOST;
    #else
    #define DEVELOPER_HOST "127.0.0.1"
    #endif

    static struct sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = inet_addr(multicast);
    if (const char *colon = index(port, ':'))
        port = colon+1;
    addr.sin_port = htons(atoi(port));

    // For a real device, we have to use multicast
    // to locate the developer's Mac to connect to.
    int multicastSocket;
    if ((multicastSocket = socket(addr.sin_family, SOCK_DGRAM, 0)) < 0) {
        [self error:@"Could not get multicast socket: %s"];
        return DEVELOPER_HOST;
    }

    struct multicast_socket_packet msgbuf;
    msgbuf.version = 1;
    msgbuf.hash = [self multicastHash];
    gethostname(msgbuf.host, sizeof msgbuf.host);

    for (int sent=0; sent<2; sent++)
        if (sendto(multicastSocket, &msgbuf, sizeof msgbuf, 0,
                   (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            [self error:@"Could not send multicast ping: %s"];
            return DEVELOPER_HOST;
        }

    unsigned addrlen = sizeof(addr);
    while (recvfrom(multicastSocket, &msgbuf, sizeof msgbuf, 0,
                    (struct sockaddr *)&addr, &addrlen) < sizeof msgbuf) {
        [self error:@"%s: Error receiving from multicast: %s"];
        sleep(1);
    }

    const char *ipaddr = inet_ntoa(addr.sin_addr);
    printf(format, msgbuf.host, ipaddr);
    close(multicastSocket);
    return ipaddr;
}

@end
#endif
