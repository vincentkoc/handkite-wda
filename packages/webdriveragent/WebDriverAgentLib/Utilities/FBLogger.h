/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 A Global Logger object that understands log levels
 */
@interface FBLogger : NSObject

/**
 Log to stdout.
 */
+ (void)log:(NSString *)message;
+ (void)logFmt:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);

/**
 Log to stdout, only if WDA is Verbose
 */
+ (void)verboseLog:(NSString *)message;
+ (void)verboseLogFmt:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);

@end

typedef NS_ENUM(NSUInteger, FBReadTimingPhase) {
  FBReadTimingPhaseActiveApp,
  FBReadTimingPhaseQuiescence,
  FBReadTimingPhaseSnapshot,
  FBReadTimingPhaseSerialize,
};

/**
 Payload-free, opt-in read diagnostics. Route paths are registration patterns,
 never request URLs. A nil timing leaves the handler unchanged.
 */
@interface FBReadTiming : NSObject
+ (nullable instancetype)enqueueMethod:(NSString *)method
                            routePath:(NSString *)routePath;
- (void)enter;
- (void)exit;
+ (void)phase:(FBReadTimingPhase)phase entering:(BOOL)entering;
@end

NS_ASSUME_NONNULL_END
