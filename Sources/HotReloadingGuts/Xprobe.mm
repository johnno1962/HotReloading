//
//  Xprobe.m
//  XprobePlugin
//
//  Created by John Holdsworth on 17/05/2014.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//
//  For full licensing term see https://github.com/johnno1962/XprobePlugin
//  $Id: //depot/HotReloading/Sources/HotReloadingGuts/Xprobe.mm#2 $
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//  DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE
//  FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
//  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
//  SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
//  CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
//  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
//  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

/*
 *  This is the source for the Xprobe memory scanner. While it connects as a client
 *  it effectively operates as a service for the Xcode browser window receiving
 *  the arguments to JavaScript "prompt()" calls. The first argument is the
 *  selector to be called in the Xprobe class. The second is an arugment 
 *  specifying the part of the page to be modified, generally the pathID 
 *  which also identifies the object the user action is related to. In 
 *  response, the selector sends back JavaScript to be executed in the
 *  browser window or, if an object has been traced, trace output.
 *
 *  The pathID is the index into the paths array which contain objects from which
 *  the object referred to can be determined rather than pass back and forward
 *  raw memory addresses. Initially, this is the number of the root object from
 *  the original search but as you browse through objects or ivars and arrays a
 *  path is built up of these objects so when the value of an ivar browsed to 
 *  changes it will be reflected in the browser when you next click on it.
 */

#ifdef DEBUG

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wold-style-cast"
#pragma clang diagnostic ignored "-Wcstring-format-directive"
#pragma clang diagnostic ignored "-Wc++98-compat-pedantic"
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wpadded"
#pragma clang diagnostic ignored "-Wobjc-missing-property-synthesis"
#pragma clang diagnostic ignored "-Wnullable-to-nonnull-conversion"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wglobal-constructors"
#pragma clang diagnostic ignored "-Wobjc-interface-ivars"
#pragma clang diagnostic ignored "-Wdirect-ivar-access"
#pragma clang diagnostic ignored "-Wc++11-extensions"

#import <libkern/OSAtomic.h>
#import <vector>
#import <map>

#import "Xprobe.h"
#import "IvarAccess.h"

#import "Xtrace.h"

@interface Xprobe(Seeding)
+ (NSArray *)xprobeSeeds;
@end

static NSString *swiftPrefix = @"_TtC";
static BOOL logXprobeSweep = NO;

extern "C"
void *xprobeGenericPointer( unsigned *opaquePointer, void *metadata ) {
    return opaquePointer;
}

#pragma mark sweep state

struct _xsweep {
    unsigned sequence, depth;
    __unsafe_unretained id from;
    const char *source;
    std::map<__unsafe_unretained id,unsigned> owners;
};

static struct _xsweep sweepState;

static std::map<__unsafe_unretained id,struct _xsweep> instancesSeen;
static std::map<__unsafe_unretained Class,std::vector<__unsafe_unretained id> > instancesByClass;
static std::map<__unsafe_unretained id,BOOL> instancesTraced;

BOOL xprobeRetainObjects = YES;
NSMutableArray<XprobePath *> *xprobePaths;

#pragma mark "dot" object graph rendering

#define MESSAGE_POLL_INTERVAL .1
#define HIGHLIGHT_PERSIST_TIME 2

struct _animate {
    NSTimeInterval lastMessageTime;
    NSString *color;
    unsigned sequence, callCount;
    BOOL highlighted;
};

static std::map<__unsafe_unretained id,struct _animate> instancesLabeled;

typedef NS_OPTIONS(NSUInteger, XGraphOptions) {
    XGraphArrayWithoutLmit       = 1 << 0,
    XGraphInterconnections       = 1 << 1,
    XGraphAllObjects             = 1 << 2,
    XGraphWithoutExcepton        = 1 << 3,
    XGraphIncludedOnly           = 1 << 4,
};

static NSString *graphOutlineColor = @"#000000", *graphHighlightColor = @"#ff0000";
static unsigned maxArrayItemsForGraphing = 20, currentMaxArrayIndex;

static XGraphOptions graphOptions;
static NSMutableString *dotGraph;

static unsigned graphEdgeID;
static BOOL graphAnimating;

#pragma mark snapshot capture

static char snapshotInclude[] =
"<html><head>\n\
<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\" />\n\
<style>\n\
\n\
body { background: #f0f8ff; }\n\
body, table { font-family: \"Helvetica Neue\", Helvetica, Arial, sans-serif; }\n\
\n\
span.letStyle { color: #A90D91; }\n\
span.typeStyle { color: green; }\n\
span.classStyle { color: blue; }\n\
\n\
span.protoStyle { }\n\
span.propsStyle { }\n\
span.methodStyle { }\n\
\n\
a.linkClicked { color: purple; }\n\
span.snapshotStyle { display: none; }\n\
\n\
form { margin: 0px }\n\
\n\
td.indent { width: 20px; }\n\
td.drilldown { border: 1px inset black; background-color:rgba(200,200,200,0.4); border-radius: 10px; padding: 10px; padding-top: 7px; box-shadow: 5px 5px 5px #888888; }\n\
\n\
.kitclass { display: none; }\n\
.kitclass > span > a:link { color: grey; }\n\
\n\
</style>\n\
<script>\n\
\n\
function $(id) {\n\
    return id ? document.getElementById(id) : document.body;\n\
}\n\
\n\
function sendClient(selector,pathID,ID,force) {\n\
    var element = $('ID'+ID);\n\
    if ( element ) {\n\
        if ( force || element.style.display != 'block' ) {\n\
            var el = element;\n\
            while ( element ) {\n\
                element.style.display = 'block';\n\
                element = element.parentElement;\n\
            }\n\
            if ( force )\n\
              var offsetY = 0;\n\
              while ( el ) {\n\
                offsetY += el.offsetTop;\n\
                el = el.offsetParent || el.parentElement;\n\
              }\n\
              if ( offsetY )\n\
                window.scrollTo( 0, offsetY );\n\
        }\n\
        else\n\
            element.style.display = 'none';\n\
    }\n\
    return false;\n\
}\n\
\n\
function lookupSym(span) {}\n\
\n\
function kitswitch(checkbox) {\n\
    var divs = document.getElementsByTagName('DIV');\n\
\n\
    for ( var i=0 ; i<divs.length ; i++ )\n\
        if ( divs[i].className == 'kitclass' )\n\
            divs[i].style.display = checkbox.checked ? 'none' : 'block';\n\
}\n\
\n\
</script>\n\
</head>\n\
<body>\n\
<b>Application Memory Snapshot</b>\n\
(<input type=checkbox onclick='kitswitch(this);' checked/> - Filter out \"kit\" instances)<br/>\n";

@interface SnapshotString : NSObject {
    FILE *out;
}
- (void)appendFormat:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);
@end

@implementation SnapshotString

- (instancetype)initPath:(NSString *)path {
    if ( (self = [super init]) ) {
        if ( !(out = fopen( [path UTF8String], "w" )) ) {
            NSLog( @"Xprobe: Could not save snapshot to path: %@", path );
            return nil;
        }
    }
    return self;
}

- (int)write:(const char *)chars {
  return fputs( chars, out );
}

- (void)appendString:(NSString *)aString {
    NSString *unescaped = [aString stringByReplacingOccurrencesOfString:@"\\'" withString:@"'"];
    [self write:[unescaped UTF8String]];
}

- (void)appendFormat:(NSString *)format, ... {
    va_list argp; va_start(argp, format);
    return [self appendString:[[NSString alloc] initWithFormat:format arguments:argp]];
}

- (void)close {
    if ( out )
        fclose( out );
}

@end

//#define ZIPPED_SNAPSHOTS
#ifdef ZIPPED_SNAPSHOTS
#import <zlib.h>

@interface SnapshotZipped : SnapshotString {
    gzFile zout;
}
@end

@implementation SnapshotZipped

- (instancetype)initPath:(NSString *)path {
    if ( (self = [super init]) ) {
        if ( !(zout = gzopen( [path UTF8String], "w" )) ) {
            NSLog( @"Xprobe: Could not save snapshot to path: %@", path );
            return nil;
        }
    }
    return self;
}

- (int)write:(const char *)chars {
    return gzputs( zout, chars );
}

- (void)close {
    if ( zout )
        gzclose( zout );
}

@end
#endif

static SnapshotString *snapshot;
static NSRegularExpression *snapshotExclusions;
static std::map<__unsafe_unretained Class,std::map<__unsafe_unretained id,int> > instanceIDs;
static int instanceID;

#ifndef APPEND_TYPE // in Xtrace
template <class _M,typename _K>
static inline bool exists( const _M &map, const _K &key ) {
    return map.find(key) != map.end();
}
#endif

static NSString *xNSStringFromClass( Class aClass ) {
    NSString *string = NSStringFromClass( aClass );
    static Class xprobeSwift;
    if ( [string hasPrefix:@"_T"] && (xprobeSwift = xprobeSwift ?: xloadXprobeSwift("NSStringFromClass")) ) {
        string = [[xprobeSwift demangle:string] xhtmlEscape];
    }
    return string;
}

@interface NSObject(XprobeReferences)

#pragma mark external references

- (NSString *)base64EncodedStringWithOptions:(NSUInteger)options;
+ (const char *)connectedAddress;
- (NSArray *)getNSArray;
- (NSArray *)subviews;

- (id)contentView;
- (id)superview;
- (id)document;
- (id)delegate;
- (SEL)action;
- (id)target;

@end

#pragma mark classes that go to make up a path

static const char *seedName = "seed", *superName = "super";

@implementation XprobePath

+ (id)withPathID:(int)pathID {
    XprobePath *path = [self new];
    path.pathID = pathID;
    return path;
}

- (int)xadd {
    int newPathID = (int)xprobePaths.count;
    [xprobePaths addObject:self];
    return newPathID;
}

- (int)xadd:(__unsafe_unretained id)obj {
    return instancesSeen[obj].sequence = [self xadd];
}

- (id)object {
    return [xprobePaths[self.pathID] object];
}

- (id)aClass {
    return object_getClass( [self object] );
}

- (NSMutableString *)xpath {
    if ( self.name == seedName ) {
        NSMutableString *path = [NSMutableString new];
        [path appendFormat:@"%@", utf8String(seedName)];
        return path;
    }

    NSMutableString *path = [xprobePaths[self.pathID] xpath];
    if ( self.name != superName )
        [path appendFormat:@".%@", utf8String(self.name)];
    return path;
}

@end

@implementation XprobeRetained
@end

//@implementation XprobeAssigned
//@end

@implementation XprobeWeak
@end

@implementation XprobeIvar

- (id)object {
    id obj = [super object];
    Ivar ivar = class_getInstanceVariable( self.iClass, self.name );
    return xvalueForIvar( obj, ivar, self.iClass );
}

@end

@implementation XprobeMethod

- (id)object {
    id obj = [super object];
    Method method = class_getInstanceMethod([obj class], sel_registerName(self.name));
    if ( !method ) {
        obj = [obj class] == [XprobeClass class] ? [obj aClass] : [obj class];
        method = class_getClassMethod(obj, sel_registerName(self.name));
    }
    return xvalueForMethod( obj, method );
}

@end

@implementation XprobeArray

- (NSArray *)array {
    return [super object];
}

- (id)object {
    NSArray *arr = [self array];
    if ( self.sub < [arr count] )
        return arr[self.sub];
    NSLog( @"Xprobe: %@ reference %d beyond end of array %d",
          xNSStringFromClass([self class]), (int)self.sub, (int)[arr count] );
    return nil;
}

- (NSMutableString *)xpath {
    NSMutableString *path = [xprobePaths[self.pathID] xpath];
    [path appendFormat:@".%d", (int)self.sub];
    return path;
}

@end

@implementation XprobeSet

- (NSArray *)array {
    return [[xprobePaths[self.pathID] object] allObjects];
}

@end

@implementation XprobeView

- (NSArray *)array {
    return [[xprobePaths[self.pathID] object] subviews];
}

@end

@implementation XprobeDict

- (id)object {
    return [[super object] objectForKey:self.sub];
}

- (NSMutableString *)xpath {
    NSMutableString *path = [xprobePaths[self.pathID] xpath];
    [path appendFormat:@".%@", self.sub];
    return path;
}

@end

@implementation XprobeSuper
@end

@implementation XprobeClass

- (id)object {
    return self;
}

@end

@implementation NSRegularExpression(Xprobe)

+ (NSRegularExpression *)xsimpleRegexp:(NSString *)pattern {
    NSError *error = nil;
    NSRegularExpression *regexp = [[NSRegularExpression alloc] initWithPattern:pattern
                                                                       options:NSRegularExpressionCaseInsensitive
                                                                         error:&error];
    if ( error && [pattern length] )
    NSLog( @"Xprobe: Filter compilation error: %@, in pattern: \"%@\"", [error localizedDescription], pattern );
    return regexp;
}

- (BOOL)xmatches:(NSString *)str  {
    return [self rangeOfFirstMatchInString:str options:0 range:NSMakeRange(0, [str length])].location != NSNotFound;
}

@end

/*************************************************************************
 *************************************************************************/

#pragma mark implmentation of Xprobe service

@implementation Xprobe

+ (NSString *)revision {
    return @"$Id: //depot/HotReloading/Sources/HotReloadingGuts/Xprobe.mm#2 $";
}

+ (BOOL)xprobeExclude:(NSString *)className {
    static NSRegularExpression *excluded;
    if ( !excluded )
        excluded = [NSRegularExpression xsimpleRegexp:@"^(_|NS|XC|IDE|DVT|Xcode3|IB|VK|WebHistory|RAC|UI(Input|Transition))"];
    return [excluded xmatches:className] && ![className hasPrefix:swiftPrefix];
}

+ (void)snapshot:(NSString *)filepath {
    dispatch_async( dispatch_get_main_queue(), ^{
        [self snapshot:filepath seeds:[self xprobeSeeds]];
    } );
}

+ (NSString *)snapshot:(NSString *)filepath seeds:(NSArray *)seeds {
    return [self snapshot:filepath seeds:seeds excluding:SNAPSHOT_EXCLUSIONS];
}

+ (NSString *)snapshot:(NSString *)filepath seeds:(NSArray *)seeds excluding:(NSString *)exclusions {

    if ( ![filepath hasPrefix:@"/"] ) {
        NSString *tmp = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES)[0];
        filepath = [tmp stringByAppendingPathComponent:filepath];
    }

    instanceIDs.clear();
    [self performSweep:seeds];

    Class writer =
#ifdef ZIPPED_SNAPSHOTS
    [filepath hasSuffix:@".gz"] ? [SnapshotZipped class] :
#endif
    [SnapshotString class];
    snapshot = [[writer alloc] initPath:filepath];

    NSString *hostname  = @"";
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
    hostname = [[UIDevice currentDevice] name];
#endif
    [snapshot appendFormat:@"%s%@ &#160;%@ &#160;%@<p/>", snapshotInclude, [NSDate date],
     [NSBundle mainBundle].infoDictionary[@"CFBundleIdentifier"], hostname];

    snapshotExclusions = [NSRegularExpression xsimpleRegexp:exclusions];
    [self filterSweepOutputBy:@"" into:(NSMutableString *)snapshot];
    [snapshot appendString:@"</body></html>"];
    [snapshot close];
    snapshot = nil;

    if ( [self respondsToSelector:@selector(writeString:)] )
        [self writeString:[NSString stringWithFormat:@"snapshot: %@",
                           [[NSData dataWithContentsOfFile:filepath] base64EncodedStringWithOptions:0]]];
    return filepath;
}

+ (void)performSweep:(NSArray *)seeds {
    instancesSeen.clear();
    instancesByClass.clear();
    instancesLabeled.clear();

    sweepState.sequence = sweepState.depth = 0;
    sweepState.source = seedName;
    graphEdgeID = 1;

    xprobePaths = [NSMutableArray new];
    [seeds xsweep];

    NSLog( @"Xprobe: sweep complete, %d objects found", (int)xprobePaths.count );
}

+ (void)filterSweepOutputBy:(NSString *)pattern into:(NSMutableString *)html {
    // original search by instance's class name
    NSRegularExpression *classRegexp = [NSRegularExpression xsimpleRegexp:pattern];
    std::map<__unsafe_unretained id,int> matchedObjects;

    for ( const auto &byClass : instancesByClass )
        if ( !classRegexp || [classRegexp xmatches:xNSStringFromClass(byClass.first)] )
            for ( const auto &instance : byClass.second )
                matchedObjects[instance]++;

    if ( !matchedObjects.empty() ) {

        for ( int pathID=0, count = (int)xprobePaths.count ; pathID < count ; pathID++ ) {
            id obj = [xprobePaths[pathID] object];

            if( matchedObjects[obj] ) {
                const char *className = class_getName([obj class]);
                BOOL isUIKit = className[0] == '_' || strncmp(className, "NS", 2) == 0 ||
                strncmp(className, "UI", 2) == 0 || strncmp(className, "CA", 2) == 0 ||
                strncmp(className, "BS", 2) == 0 || strncmp(className, "FBS", 3) == 0 ||
                strncmp(className, "RBS", 3) == 0 || strncmp(className, "OS_", 3) == 0; ////

                [html appendFormat:@"<div%@>", isUIKit ? @" class=\\'kitclass\\'" : @""];

                struct _xsweep &info = instancesSeen[obj];
                for ( unsigned i=1 ; i<info.depth ; i++ )
                    [html appendString:@"&#160; &#160; "];

                [obj xlinkForCommand:@"open" withPathID:info.sequence into:html];
                [html appendString:@"</div>"];
            }
        }
    }
    else
        if ( ![self findClassesMatching:classRegexp into:html] )
            [html appendString:@"No root objects or classes found, check class name pattern.<br/>"];
}

+ (NSUInteger)findClassesMatching:(NSRegularExpression *)classRegexp into:(NSMutableString *)html {

    unsigned ccount;
    Class *classes = objc_copyClassList( &ccount );
    NSMutableArray *classesFound = [NSMutableArray new];

    for ( unsigned i=0 ; i<ccount ; i++ ) {
        NSString *className = xNSStringFromClass(classes[i]);
        if ( [classRegexp xmatches:className] && ![className hasPrefix:@"__"] )
            [classesFound addObject:className];
    }

    free( classes );

    [classesFound sortUsingSelector:@selector(caseInsensitiveCompare:)];

    for ( NSString *className in classesFound ) {
        XprobeClass *path = [XprobeClass new];
        path.aClass = NSClassFromString(className);
        [path xlinkForCommand:@"open" withPathID:[path xadd] into:html];
        [html appendString:@"<br/>"];
    }

    return [classesFound count];
}

+ (void)findMethodsMatching:(NSString *)pattern type:(unichar)firstChar into:(NSMutableString *)html {

    NSRegularExpression *methodRegexp = [NSRegularExpression xsimpleRegexp:pattern];
    NSMutableDictionary *classesFound = [NSMutableDictionary new];

    unsigned ccount;
    Class *classes = objc_copyClassList( &ccount );
    for ( unsigned i=0 ; i<ccount ; i++ ) {
        Class aClass = firstChar=='+' ? object_getClass(classes[i]) : classes[i];
        NSMutableString *methodsFound = nil;

        unsigned mc;
        Method *methods = class_copyMethodList(aClass, &mc);
        for ( unsigned i=0 ; i<mc ; i++ ) {
            NSString *methodName = NSStringFromSelector(method_getName(methods[i]));
            if ( [methodRegexp xmatches:methodName] ) {
                if ( !methodsFound )
                    methodsFound = [NSMutableString stringWithString:@"<br/>"];
                [methodsFound appendFormat:@"&#160; &#160; %@%@<br/>", [NSString stringWithCharacters:&firstChar length:1], methodName];
            }
        }

        if ( methodsFound )
            classesFound[xNSStringFromClass(classes[i])] = methodsFound;

        free( methods );
    }

    for ( NSString *className in [[classesFound allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)] )
        if ( [className characterAtIndex:1] != '_' && [html length] < 500000 ) {
            XprobeClass *path = [XprobeClass new];
            path.aClass = NSClassFromString(className);
            [path xlinkForCommand:@"open" withPathID:[path xadd] into:html];
            [html appendString:classesFound[className]];
        }
}

/*************************************************************************
 *************************************************************************/

#pragma mark service methods using C++ data structs

static NSString *lastPattern;

+ (void)_search:(NSString *)pattern {

    pattern = [pattern stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    if ( [pattern hasPrefix:@"0x"] ) {

        // raw pointers entered as 0xNNN.. search
        XprobeRetained *path = [XprobeRetained new];
        path.object = [path xvalueForKeyPath:pattern];
        path.name = strdup( [[NSString stringWithFormat:@"%p", (void *)path.object] UTF8String] );
        [self open:[[NSNumber numberWithInt:[path xadd]] stringValue]];
        return;
    }
    else if ( [pattern hasPrefix:@"seed."] ) {

        // recovery of object from a KVO-like path
        @try {

            NSArray *keys = [pattern componentsSeparatedByString:@"."];
            id obj = [xprobePaths[0] object];

            for ( int i=1 ; i<[keys count] ; i++ ) {
                obj = [obj xvalueForKey:keys[i]];

                int pathID;
                if ( !exists( instancesSeen, obj ) ) {
                    XprobeRetained *path = [XprobeRetained new];
                    path.object = [[xprobePaths[0] object] xvalueForKeyPath:[pattern substringFromIndex:[@"seed." length]]];
                    path.name = strdup( [[NSString stringWithFormat:@"%p", (void *)path.object] UTF8String] );
                    pathID = [path xadd];
                }
                else
                    pathID = instancesSeen[obj].sequence;

                [self open:[[NSNumber numberWithInt:pathID] stringValue]];
            }
        }
        @catch ( NSException *e ) {
            NSLog( @"Xprobe: keyPath error: %@", e );
        }
        return;
    }

    NSLog( @"Xprobe: sweeping memory, filtering by '%@'", pattern );
    dotGraph = [NSMutableString stringWithString:@"digraph sweep {\n"
                "    node [href=\"javascript:void(click_node('\\N'))\" id=\"\\N\" fontname=\"Arial\"];\n"];

    if ( pattern != lastPattern ) {
        lastPattern = pattern;
        graphOptions = 0;
    }

    NSArray *seeds = [self xprobeSeeds];
    if ( !seeds.count )
        NSLog( @"Xprobe: no seeds returned from xprobeSeeds category" );

    [self performSweep:seeds];

    [dotGraph appendString:@"}\n"];
    [self writeString:dotGraph];
    dotGraph = nil;

    NSMutableString *html = [NSMutableString new];
    [html appendString:@"$().innerHTML = '<b>Application Memory Sweep</b> "
     "(<input type=checkbox onclick=\"kitswitch(this);\" checked> - Filter out \"kit\" instances)<p/>"];

    // various types of earches
    unichar firstChar = [pattern length] ? [pattern characterAtIndex:0] : 0;
    if ( (firstChar == '+' || firstChar == '-') && [pattern length] > 3 )
        [self findMethodsMatching:[pattern substringFromIndex:1] type:firstChar into:html];
    else
        [self filterSweepOutputBy:pattern into:html];

    [html appendString:@"';"];
    [self writeString:html];
    
    if ( graphAnimating )
        [self animate:@"1"];
}

+ (void)regraph:(NSString *)input {
    graphOptions = [input intValue];
    [self search:lastPattern];
}

+ (void)owners:(NSString *)input {
    int pathID = [input intValue];
    id obj = [xprobePaths[pathID] object];

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('O%d').outerHTML = '<p/>", pathID];

    for ( auto owner : instancesSeen[obj].owners ) {
        int pathID = instancesSeen[owner.first].sequence;
        [owner.first xlinkForCommand:@"open" withPathID:pathID into:html];
        [html appendString:@"&#160; "];
    }

    [html appendString:@"<p/>';"];
    [self writeString:html];
}

+ (void)siblings:(NSString *)input {
    int pathID = [input intValue];
    Class aClass = [xprobePaths[pathID] aClass];

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('S%d').outerHTML = '<p/>", pathID];

    for ( const auto &obj : instancesByClass[aClass] ) {
        XprobeRetained *path = [XprobeRetained new];
        path.object = obj;
        [obj xlinkForCommand:@"open" withPathID:[path xadd] into:html];
        [html appendString:@" "];
    }

    [html appendString:@"<p/>';"];
    [self writeString:html];
}

static std::map<unsigned,NSTimeInterval> edgesCalled;
static OSSpinLock edgeLock;

+ (void)traceinstance:(NSString *)input {
    int pathID = [input intValue];
    XprobePath *path = xprobePaths[pathID];
    id obj = [path object];
    Class aClass = [path aClass];

    Class xTrace = objc_getClass("Xtrace");
    [xTrace setDelegate:self];
    if ( [path class] == [XprobeClass class] ) {
        if ( !object_isClass(obj) )
            obj = aClass;
        [xloadXprobeSwift("traceinstance:") ?: xTrace traceClass:aClass];
        [self writeString:[NSString stringWithFormat:@"Tracing [%@ class]", xNSStringFromClass(aClass)]];
    }
    else {
        [xTrace traceInstance:obj class:aClass]; ///
        instancesTraced[obj] = YES;
        [self writeString:[NSString stringWithFormat:@"Tracing <%@ %p>", xNSStringFromClass(aClass), (void *)obj]];
    }
}

+ (void)traceclass:(NSString *)input {
    XprobeClass *path = [XprobeClass new];
    path.aClass = [xprobePaths[[input intValue]] aClass];
    [self traceinstance:[NSString stringWithFormat:@"%d", [path xadd]]];
}

+ (void)tracebundle:(NSString *)input {
    Class theClass = [xprobePaths[[input intValue]] aClass];
    NSBundle *theBundle = [NSBundle bundleForClass:theClass];

    Class xTrace = objc_getClass("Xtrace");
    [xTrace setDelegate:self];
    [xloadXprobeSwift("tracebundle:") ?: xTrace traceBundle:theBundle];
}

+ (void)untrace:(NSString *)input {
    int pathID = [input intValue];
    id obj = [xprobePaths[pathID] object];
    [objc_getClass("Xtrace") notrace:obj];
    auto i = instancesTraced.find(obj);
    if ( i != instancesTraced.end() )
        instancesTraced.erase(i);
}

+ (void)xtrace:(NSString *)trace forInstance:(void *)optr indent:(int)indent {
    __unsafe_unretained id obj = (__bridge __unsafe_unretained id)optr;

    if ( !graphAnimating || exists( instancesTraced, obj ) )
        [self writeString:trace];

    if ( graphAnimating && !dotGraph ) {
        OSSpinLockLock(&edgeLock);

        struct _animate &info = instancesLabeled[obj];
        info.lastMessageTime = [NSDate timeIntervalSinceReferenceDate];
        info.callCount++;

        static __unsafe_unretained id callStack[1000];
        if ( indent >= 0 && indent < sizeof callStack / sizeof callStack[0] ) {
            callStack[indent] = obj;

            __unsafe_unretained id caller = callStack[indent-1];
            std::map<__unsafe_unretained id,unsigned> &owners = instancesSeen[obj].owners;
            if ( indent > 0 && obj != caller && exists( owners, caller ) ) {
                edgesCalled[owners[caller]] = info.lastMessageTime;
            }
        }

        OSSpinLockUnlock(&edgeLock);
    }
}

+ (void)animate:(NSString *)input {
    BOOL wasAnimating = graphAnimating;
    Class xTrace = objc_getClass("Xtrace");
    if ( (graphAnimating = [input intValue]) ) {
        edgeLock = OS_SPINLOCK_INIT;
        [xTrace setDelegate:self];

        for ( const auto &graphing : instancesLabeled ) {
            const char *className = object_getClassName( graphing.first );
            if (
#if TARGET_OS_IPHONE
                strncmp( className, "NS", 2 ) != 0 &&
#endif
                strncmp( className, "__", 2 ) != 0 )
                [xTrace traceInstance:graphing.first];
        }

        if ( !wasAnimating )
            [self performSelectorInBackground:@selector(sendUpdates) withObject:nil];

        NSLog( @"Xprobe: traced %d objects", (int)instancesLabeled.size() );
    }
    else
        for ( const auto &graphing : instancesLabeled )
            if ( exists( instancesTraced, graphing.first ) )
                [xTrace notrace:graphing.first];
}

+ (void)sendUpdates {
    while ( graphAnimating ) {
        NSTimeInterval then = [NSDate timeIntervalSinceReferenceDate];
        [NSThread sleepForTimeInterval:MESSAGE_POLL_INTERVAL];

        if ( !dotGraph ) {
            NSMutableString *updates = [NSMutableString new];
            std::vector<unsigned> expired;

            OSSpinLockLock(&edgeLock);

            for ( auto &called : edgesCalled )
                if ( called.second > then )
                    [updates appendFormat:@" colorEdge('%u','%@');", called.first, graphHighlightColor];
                else if ( called.second < then - HIGHLIGHT_PERSIST_TIME ) {
                    [updates appendFormat:@" colorEdge('%u','%@');", called.first, graphOutlineColor];
                    expired.push_back(called.first);
                }

            for ( auto &edge : expired )
                edgesCalled.erase(edge);

            OSSpinLockUnlock(&edgeLock);

            if ( [updates length] ) {
                [updates insertString:@" startEdge();" atIndex:0];
                [updates appendString:@" stopEdge();"];
            }

            for ( auto &graphed : instancesLabeled )
                if ( graphed.second.lastMessageTime > then ) {
                    [updates appendFormat:@" $('%u').style.color = '%@'; $('%u').title = 'Messaged %d times';",
                     graphed.second.sequence, graphHighlightColor, graphed.second.sequence, graphed.second.callCount];
                    graphed.second.highlighted = TRUE;
                }
                else if ( graphed.second.highlighted && graphed.second.lastMessageTime < then - HIGHLIGHT_PERSIST_TIME ) {
                    [updates appendFormat:@" $('%u').style.color = '%@';", graphed.second.sequence, graphOutlineColor];
                    graphed.second.highlighted = FALSE;
                }
            
            if ( [updates length] )
                [self writeString:[@"updates:" stringByAppendingString:updates]];
        }
    }
}

@end

/*************************************************************************
 *************************************************************************/

#pragma mark sweep and object display methods

@implementation NSObject(Xprobe)

+ (void)xsweep {
}

- (void)xsweep {
    BOOL sweptAlready = exists( instancesSeen, self );
    __unsafe_unretained id from = sweepState.from;
    const char *source = sweepState.source;

    if ( !sweptAlready )
        instancesSeen[self] = sweepState;

//    if ( ![self isKindOfClass:[NSObject class]] )
//        return;
//
    BOOL didConnect = [from xgraphConnectionTo:self];

    if ( sweptAlready )
        return;

    XprobeRetained *path = xprobeRetainObjects ? [XprobeRetained new] : (XprobeRetained *)[XprobeWeak new];
    path.pathID = instancesSeen[sweepState.from].sequence;
    path.object = self;
    path.name = source;

    assert( [path xadd] == sweepState.sequence );

    sweepState.from = self;
    sweepState.sequence++;
    sweepState.depth++;

    Class aClass = object_getClass(self);
    NSString *className = xNSStringFromClass(aClass);
    BOOL legacy = [Xprobe xprobeExclude:className];

    if ( logXprobeSweep )
        printf("Xprobe sweep %d %*s: <%s %p> %s %d\n", sweepState.sequence-1, sweepState.depth, "",
                                                    [className UTF8String], (__bridge void *)self, path.name, legacy);

    for ( ; aClass && aClass != [NSObject class] ; aClass = class_getSuperclass(aClass) ) {
        if ( className.length == 1 || ![className hasPrefix:@"__"] )
            instancesByClass[aClass].push_back(self);

        // avoid sweeping legacy classes ivars
        if ( legacy )
            continue;

        static Class xprobeSwift;
        if ( isSwift( aClass ) && (xprobeSwift = xprobeSwift ?: xloadXprobeSwift("Xprobe")) ) {
            [xprobeSwift xprobeSweep:self forClass:aClass];
            continue;
        }

        unsigned ic;
        Ivar *ivars = class_copyIvarList( aClass, &ic );
        __unused const char *currentClassName = class_getName( aClass );
        
        for ( unsigned i=0 ; i<ic ; i++ ) {
            const char *currentIvarName = sweepState.source = ivar_getName( ivars[i] );
            const char *type = ivar_getTypeEncodingSwift( ivars[i], aClass );

            if ( strncmp( currentIvarName, "__", 2 ) != 0 && strcmp( currentIvarName, "_extraIvars" ) != 0 &&
                type && (type[0] == '@' || isSwiftObject( type ) || isOOType( type )) ) {
                id subObject = xvalueForIvarType( self, ivars[i], type, aClass );
                if ( [subObject respondsToSelector:@selector(xsweep)] ) {
                    const char *className = object_getClassName( subObject ); ////
                    if ( className[0] != '_' )
                        [subObject xsweep];////( subObject );
                }
            }
        }

        free( ivars );
    }

    sweepState.source = "target";
    if ( [self respondsToSelector:@selector(target)] ) {
        if ( [self respondsToSelector:@selector(action)] )
            sweepState.source = sel_getName([self action]);
        [[self target] xsweep];
    }
    sweepState.source = "delegate";
    if ( [self respondsToSelector:@selector(delegate)] &&
        ![className isEqualToString:@"UITransitionView"] )
        [[self delegate] xsweep];
    sweepState.source = "document";
    if ( [self respondsToSelector:@selector(document)] )
        [[self document] xsweep];

    sweepState.source = "contentView";
    if ( [self respondsToSelector:@selector(contentView)] &&
        [[self contentView] respondsToSelector:@selector(superview)] )
        [[[self contentView] superview] xsweep];

    sweepState.source = "subview";
    if ( [self respondsToSelector:@selector(subviews)] )
        [[self subviews] xsweep];

    sweepState.source = "subscene";
    if ( [self respondsToSelector:@selector(getNSArray)] )
        [[self getNSArray] xsweep];

    sweepState.source = source;
    sweepState.from = from;
    sweepState.depth--;

    if ( !didConnect && graphOptions & XGraphInterconnections )
        [from xgraphConnectionTo:self];
}

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html
{
    XprobePath *path = xprobePaths[pathID];
    Class aClass = [path aClass];

    NSString *closer = [NSString stringWithFormat:@"<span onclick=\\'sendClient(\"open:\",\"%d\"); "
                        "event.cancelBubble = true;\\'>%@</span>",
                        pathID, xNSStringFromClass(aClass)];
    [html appendFormat:[self class] == aClass ? @"<b>%@</b>" : @"%@", closer];

    if ( [aClass superclass] ) {
        XprobeSuper *superPath = [path class] == [XprobeClass class] ? [XprobeClass new] :
            [XprobeSuper withPathID:[path class] == [XprobeSuper class] ? path.pathID : pathID];
        superPath.aClass = [aClass superclass];
        superPath.name = superName;

        [html appendString:@" : "];
        [self xlinkForCommand:@"open" withPathID:[superPath xadd] into:html];
    }

    unsigned c;
    Protocol *__unsafe_unretained *protos = class_copyProtocolList(aClass, &c);
    if ( c ) {
        [html appendString:@" &lt;"];

        for ( unsigned i=0 ; i<c ; i++ ) {
            if ( i )
                [html appendString:@", "];
            NSString *protocolName = NSStringFromProtocol(protos[i]);
            [html appendString:snapshot ? protocolName : xlinkForProtocol( protocolName )];
        }

        [html appendString:@"&gt;"];
        free( protos );
    }

    [html appendString:@" {<br/>"];


    static Class xprobeSwift;
    if ( isSwift( aClass ) && (xprobeSwift = xprobeSwift ?: xloadXprobeSwift("class")) ) {
        [xprobeSwift dumpIvars:self forClass:aClass into:html];
    }
    else {
//        dispatch_sync(dispatch_get_main_queue(), ^{
            unsigned c;
            Ivar *ivars = class_copyIvarList(aClass, &c);
            for ( unsigned i=0 ; i<c ; i++ ) {
                __unused const char *name = ivar_getName( ivars[i] );
                const char *type = ivar_getTypeEncodingSwift( ivars[i], aClass );
                NSString *typeStr = xtype( type );
                [html appendFormat:@" &#160; &#160;%@%@", typeStr, [typeStr containsString:@"*<"] ? @"" : @" "];
                [self xspanForPathID:pathID ivar:ivars[i] type:type into:html];
                [html appendString:@";<br/>"];
            }

            free( ivars );
//        });
    }

    [html appendString:@"} "];
    if ( snapshot )
        return;

    [self xlinkForCommand:@"properties" withPathID:pathID into:html];
    [html appendString:@" "];
    [self xlinkForCommand:@"methods" withPathID:pathID into:html];
    [html appendString:@" "];
    [self xlinkForCommand:@"owners" withPathID:pathID into:html];
    [html appendString:@" "];
    [self xlinkForCommand:@"siblings" withPathID:pathID into:html];
    [html appendString:@" "];
    [self xlinkForCommand:@"tracebundle" withPathID:pathID into:html];
    [html appendString:@" "];
    [self xlinkForCommand:@"traceclass" withPathID:pathID into:html];
    [html appendString:@" "];
    [self xlinkForCommand:@"traceinstance" withPathID:pathID into:html];
    [html appendString:@" "];
    [self xlinkForCommand:@"untrace" withPathID:pathID into:html];

    if ( [self respondsToSelector:@selector(subviews)] ) {
        [html appendString:@" "];
        [self xlinkForCommand:@"render" withPathID:pathID into:html];
        [html appendString:@" "];
        [self xlinkForCommand:@"views" withPathID:pathID into:html];
    }

    [html appendFormat:@" <a href=\\'#\\' onclick=\\'sendClient(\"close:\",\"%d\"); return false;\\'>close</a>", pathID];

    Class injectionLoader = NSClassFromString(@"BundleInjection");
    if ( [injectionLoader respondsToSelector:@selector(connectedAddress)] ) {
        BOOL injectionConnected = [injectionLoader connectedAddress] != NULL;

        Class myClass = [self class];
        [html appendFormat:@"<br/><span><button onclick=\"evalForm(this.parentElement,%d,\\'%@\\',%d);"
            "return false;\"%@>Evaluate code against this instance..</button>%@</span>",
            pathID, xNSStringFromClass(myClass), isSwift( myClass ) ? 1 : 0,
            injectionConnected ? @"" : @" disabled",
            injectionConnected ? @"" :@" (requires connection to "
            "<a href=\\'https://github.com/johnno1962/injectionforxcode\\'>injectionforxcode plugin</a>)"];
    }
}

- (void)xspanForPathID:(int)pathID ivar:(Ivar)ivar type:(const char *)type into:(NSMutableString *)html {
    Class aClass = [xprobePaths[pathID] aClass];
    const char *currentIvarName = ivar_getName( ivar );
    NSString *utf8Name = utf8String( currentIvarName );

    [html appendFormat:@"<span onclick=\\'if ( event.srcElement.tagName != \"INPUT\" ) { this.id =\"I%d\"; "
        "sendClient( \"ivar:\", \"%d,%@\" ); event.cancelBubble = true; }\\'>%@",
     pathID, pathID, utf8Name, utf8Name];

    if ( [xprobePaths[pathID] class] != [XprobeClass class] ) {
        [html appendString:@" = "];

        if ( !type || type[0] == '@' || isSwiftObject( type ) || isOOType( type ) || isCFType( type ) || isNewRefType( type ) )
            xprotect( ^{
                id subObject = xvalueForIvar( self, ivar, aClass );
                if ( subObject ) {
                    XprobeIvar *ivarPath = [XprobeIvar withPathID:pathID];
                    ivarPath.iClass = aClass;
                    ivarPath.name = currentIvarName;
                    if ( [subObject respondsToSelector:@selector(xsweep)] )
                        [subObject xlinkForCommand:@"open" withPathID:[ivarPath xadd:subObject] into:html];
                    else
                        [html appendFormat:@"&lt;%@ %p&gt;",
                         xNSStringFromClass([subObject class]), (void *)subObject];
                }
                else
                    [html appendString:@"nil"];
            } );
        else
            [html appendFormat:@"<span onclick=\\'this.id =\"E%d\"; sendClient( \"edit:\", \"%d,%@\" ); "
                "event.cancelBubble = true;\\'>%@</span>", pathID, pathID, utf8Name,
                [xvalueForIvar( self, ivar, aClass) xhtmlEscape]];
    }

    [html appendString:@"</span>"];
}

static NSString *xclassName( NSObject *self ) {
    return xNSStringFromClass( [self class] );
}

+ (void)xlinkForCommand:(NSString *)which withPathID:(int)pathID into:(NSMutableString *)html {
    [html appendFormat:@"[%@ class]", xNSStringFromClass(self)];
}


- (void)xlinkForCommand:(NSString *)which withPathID:(int)pathID into:(NSMutableString *)html {
    if ( self == trapped || self == notype || self == invocationException ) {
        [html appendString:(NSString *)self];
        return;
    }

    XprobePath *path = xprobePaths[pathID];
    Class linkClass = [path aClass];
    NSString *linkClassName = xNSStringFromClass( linkClass );
    BOOL basic = [which isEqualToString:@"open"] || [which isEqualToString:@"close"];
    NSString *linkLabel = !basic ? which : [self class] != linkClass ? linkClassName :
        [NSString stringWithFormat:@"&lt;%@&#160;%p&gt;", xclassName( self ), (void *)self];
    unichar firstChar = toupper( [which characterAtIndex:0] );

    BOOL notBeenSeen = !exists( instanceIDs[linkClass], self );
    if ( notBeenSeen )
        instanceIDs[linkClass][self] = instanceID++;

    int ID = instanceIDs[linkClass][self];

    BOOL excluded = snapshot && linkClassName && [snapshotExclusions xmatches:linkClassName];
    BOOL willExpand = snapshot && notBeenSeen && !excluded;

    if ( excluded ) //|| [linkClassName hasPrefix:@"_TtG"] )
        [html appendString:linkLabel];
    else
        [html appendFormat:@"<span id=\\'%@%d\\' onclick=\\'event.cancelBubble = true;\\'>"
            "<a href=\\'#\\' onclick=\\'sendClient( \"%@:\", \"%d\", %d, %d ); "
            "this.className = \"linkClicked\"; event.cancelBubble = true; return false;\\'%@>%@</a>%@",
            basic ? @"" : [NSString stringWithCharacters:&firstChar length:1],
            pathID, which, pathID, ID, !willExpand, path.name ?
            [NSString stringWithFormat:@" title=\\'%@\\'", utf8String( path.name )] : @"",
            linkLabel, [which isEqualToString:@"close"] || willExpand ? @"" : @"</span>"];

    if ( willExpand ) {
        [html appendFormat:@"</span></span><span><span><span id='ID%d' class='snapshotStyle'>", ID];
        [Xprobe xopen:self withPathID:pathID into:html];
        [html appendString:@"</span>"];
    }
}

+ (void)xopen:(NSObject *)obj withPathID:(int)pathID into:(NSMutableString *)html {
    [html appendString:@"<table><tr><td class=\\'indent\\'/><td class=\\'drilldown\\'>"];
    [obj xopenPathID:pathID into:html];
    [html appendString:@"</td></tr></table></span>"];
}

#pragma dot object graph generation code

static BOOL xgraphInclude( NSObject *self ) {
    NSString *className = xNSStringFromClass([self class]);
    static NSRegularExpression *excluded;
    if ( !excluded )
        excluded = [NSRegularExpression xsimpleRegexp:@"^(?:_|NS|UI|CA|OS_|Web|Wak|FBS)"];
    return ![excluded xmatches:className];
}

static BOOL xgraphExclude( NSObject *self ) {
    NSString *className = xNSStringFromClass([self class]);
    return ![className hasPrefix:swiftPrefix] &&
        ([className characterAtIndex:0] == '_' ||
         [className isEqual:@"CALayer"] || [className hasPrefix:@"NSIS"] ||
         [className hasSuffix:@"Constraint"] || [className hasSuffix:@"Variable"] ||
         [className hasSuffix:@"Color"]);
}

static NSString *outlineColorFor( NSObject *self, NSString *className ) {
    return graphOutlineColor;
}

static void xgraphLabelNode( NSObject *self ) {
    if ( !exists( instancesLabeled, self ) ) {
        NSString *className = xNSStringFromClass([self class]);
        OSSpinLockLock(&edgeLock);
        instancesLabeled[self].sequence = instancesSeen[self].sequence;
        OSSpinLockUnlock(&edgeLock);
        NSString *color = instancesLabeled[self].color = outlineColorFor( self, className );
        [dotGraph appendFormat:@"    %d [label=\"%@\" tooltip=\"<%@ %p> #%d\"%s%s color=\"%@\"];\n",
             instancesSeen[self].sequence, xclassName( self ), className, (void *)self, instancesSeen[self].sequence,
             [self respondsToSelector:@selector(subviews)] ? " shape=box" : "",
             xgraphInclude( self ) ? " style=\"filled\" fillcolor=\"#e0e0e0\"" : "", color];
    }
}

- (BOOL)xgraphConnectionTo:(id)ivar {
    int edgeID = instancesSeen[ivar].owners[self] = graphEdgeID++;
    if ( dotGraph && (__bridge CFNullRef)ivar != kCFNull &&
            (graphOptions & XGraphArrayWithoutLmit || currentMaxArrayIndex < maxArrayItemsForGraphing) &&
            (graphOptions & XGraphAllObjects ||
                (graphOptions & XGraphIncludedOnly ?
                 xgraphInclude( self ) && xgraphInclude( ivar ) :
                 xgraphInclude( self ) || xgraphInclude( ivar )) ||
                (graphOptions & XGraphInterconnections &&
                 exists( instancesLabeled, self ) &&
                 exists( instancesLabeled, ivar ))) &&
            (graphOptions & XGraphWithoutExcepton || (!xgraphExclude( self ) && !xgraphExclude( ivar ))) ) {
        xgraphLabelNode( self );
        xgraphLabelNode( ivar );
        [dotGraph appendFormat:@"    %d -> %d [label=\"%@\" color=\"%@\" eid=\"%d\"];\n",
            instancesSeen[self].sequence, instancesSeen[ivar].sequence, utf8String( sweepState.source ),
            instancesLabeled[self].color, edgeID];
        return YES;
    }
    else
        return NO;
}

- (id)xvalueForKey:(NSString *)key {
    if ( [key hasPrefix:@"0x"] ) {
        NSScanner* scanner = [NSScanner scannerWithString:key];
        unsigned long long objectPointer;
        [scanner scanHexLongLong:&objectPointer];
        return (__bridge id)(void *)objectPointer;
    }
    else
        return [self valueForKey:key];
}

- (id)xvalueForKeyPath:(NSString *)key {
    NSUInteger dotLocation = [key rangeOfString:@"."].location;
    if ( dotLocation == NSNotFound )
        return [self xvalueForKey:key];
    else
        return [[self xvalueForKey:[key substringToIndex:dotLocation]]
                xvalueForKeyPath:[key substringFromIndex:dotLocation+1]];
}

- (NSString *)xhtmlEscape {
    return [[[[[[[[self description]
                  stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
                 stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"]
                stringByReplacingOccurrencesOfString:@"\n" withString:@"<br/>"]
               stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
              stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"]
             stringByReplacingOccurrencesOfString:@"  " withString:@" &#160;"]
            stringByReplacingOccurrencesOfString:@"\t" withString:@" &#160; &#160;"];
}

@end

/*************************************************************************
 *************************************************************************/

#pragma mark sweep of foundation classes

@implementation NSArray(Xprobe)

- (void)xsweep {
    sweepState.depth++;
    unsigned saveMaxArrayIndex = currentMaxArrayIndex;

    for ( unsigned i=0 ; i<[self count] ; i++ ) {
        if ( currentMaxArrayIndex < i )
            currentMaxArrayIndex = i;
        if ( [self[i] respondsToSelector:@selector(xsweep)] )
            [self[i] xsweep];//// xsweep( self[i] );
    }

    currentMaxArrayIndex = saveMaxArrayIndex;
    sweepState.depth--;
}

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html {
    [html appendString:@"@["];

    for ( int i=0 ; i < self.count ; i++ ) {
        if ( i )
            [html appendString:@", "];

        XprobeArray *path = [XprobeArray withPathID:pathID];
        path.sub = i;
        id obj = self[i];
        [obj xlinkForCommand:@"open" withPathID:[path xadd:obj] into:html];
    }

    [html appendString:@"]"];
}

- (id)xvalueForKey:(NSString *)key {
    return [self objectAtIndex:[key intValue]];
}

@end

@implementation NSSet(Xprobe)

- (void)xsweep {
    [[self allObjects] xsweep];
}

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html {
    [html appendString:@"@["];

    for ( int i=0 ; i < self.count ; i++ ) {
        if ( i )
            [html appendString:@", "];

        XprobeSet *path = [XprobeSet withPathID:pathID];
        path.sub = i;
        id obj = [self allObjects][i];
        [obj xlinkForCommand:@"open" withPathID:[path xadd:obj] into:html];
    }

    [html appendString:@"]"];
}

- (id)xvalueForKey:(NSString *)key {
    return [[self allObjects] objectAtIndex:[key intValue]];
}

@end

@implementation NSDictionary(Xprobe)

- (void)xsweep {
    [[self allValues] xsweep];
}

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html
{
    [html appendString:@"@{<br/>"];

    NSArray *keys = [self allKeys];
    for ( id key in [keys.firstObject respondsToSelector:@selector(compare:)] ?
            [keys sortedArrayUsingSelector:@selector(compare:)] : keys) {
        [html appendFormat:@" &#160; &#160;%@ : ", [key xhtmlEscape]];

        XprobeDict *path = [XprobeDict withPathID:pathID];
        path.sub = key;

        id obj = self[key];
        [obj xlinkForCommand:@"open" withPathID:[path xadd:obj] into:html];
        [html appendString:@",<br/>"];
    }

    [html appendString:@"}"];
}

@end

@implementation NSMapTable(Xprobe)

- (void)xsweep {
    [[[self objectEnumerator] allObjects] xsweep];
}

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html {
    [html appendString:@"@{<br/>"];

    for ( id key in [[[self keyEnumerator] allObjects] sortedArrayUsingSelector:@selector(compare:)] ) {
        [html appendFormat:@" &#160; &#160;%@ : ", [key xhtmlEscape]];

        XprobeDict *path = [XprobeDict withPathID:pathID];
        path.sub = key;

        id obj = [self objectForKey:key];
        [obj xlinkForCommand:@"open" withPathID:[path xadd:obj] into:html];
        [html appendString:@",<br/>"];
    }

    [html appendString:@"}"];
}

@end

@implementation NSHashTable(Xprobe)

- (void)xsweep {
    [[self allObjects] xsweep];
}

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html {
    NSArray *all = [self allObjects];

    [html appendString:@"@["];
    for ( int i=0 ; i<[all count] ; i++ ) {
        if ( i )
            [html appendString:@", "];

        XprobeSet *path = [XprobeSet withPathID:pathID];
        path.sub = i;
        id obj = all[i];
        [obj xlinkForCommand:@"open" withPathID:[path xadd:obj] into:html];
    }
    [html appendString:@"]"];
}

- (id)xvalueForKey:(NSString *)key {
    return [[self allObjects] objectAtIndex:[key intValue]];
}

@end

@implementation NSString(Xprobe)

- (void)xsweep {
}

- (void)xlinkForCommand:(NSString *)which withPathID:(int)pathID into:(NSMutableString *)html {
    if ( self.length < 50 )
        [self xopenPathID:pathID into:html];
    else
        [super xlinkForCommand:which withPathID:pathID into:html];
}

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html {
    [html appendFormat:@"@\"%@\"", [self xhtmlEscape]];
}

@end

@implementation NSValue(Xprobe)

- (void)xsweep {
}

- (void)xlinkForCommand:(NSString *)which withPathID:(int)pathID into:(NSMutableString *)html {
    [html appendString:@"@"];
    [html appendString:[self xhtmlEscape]];
}

@end

@implementation NSData(Xprobe)

- (void)xsweep {
}

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html {
    [html appendString:[self xhtmlEscape]];
}

@end

@implementation NSBlock(Xprobe)

// Block internals. (thanks to https://github.com/steipete/Aspects)
typedef NS_OPTIONS(int, AspectBlockFlags) {
    AspectBlockFlagsHasCopyDisposeHelpers = (1 << 25),
    AspectBlockFlagsHasSignature          = (1 << 30)
};
typedef struct _AspectBlock {
    __unused Class isa;
    AspectBlockFlags flags;
    __unused int reserved;
    void (*invoke)(struct _AspectBlock *block, ...);
    struct {
        unsigned long int reserved;
        unsigned long int size;
        // requires AspectBlockFlagsHasCopyDisposeHelpers
        void (*copy)(void *dst, const void *src);
        void (*dispose)(const void *);
        // requires AspectBlockFlagsHasSignature
        const char *signature;
        const char *layout;
    } *descriptor;
    // imported variables
} *AspectBlockRef;

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html {
    AspectBlockRef blockInfo = (__bridge AspectBlockRef)self;
    BOOL hasInfo = blockInfo->flags & AspectBlockFlagsHasSignature ? YES : NO;
    [html appendFormat:@"<br/>%p ^( %s ) {<br/>&nbsp &#160; %s<br/>}", (void *)blockInfo->invoke,
     hasInfo && blockInfo->descriptor->signature ?
     blockInfo->descriptor->signature : "blank",
     /*hasInfo && blockInfo->descriptor->layout ?
     blockInfo->descriptor->layout :*/ "// layout blank"];
}

@end

@implementation NSProxy(Xprobe)

- (void)xsweep {
}

@end

#pragma clang diagnostic pop

#endif
