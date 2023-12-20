//
//  SignerService.h
//  InjectionIII
//
//  Created by John Holdsworth on 06/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface SignerService: NSObject

+ (NSString * _Nullable)codesignDylib:(NSString * _Nonnull)dylib identity:(NSString * _Nullable)identity;

@end
