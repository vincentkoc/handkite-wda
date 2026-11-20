/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBLogger.h"

#import "FBConfiguration.h"

#include <math.h>

@implementation FBLogger

+ (void)log:(NSString *)message
{
  NSLog(@"%@", message);
}

+ (void)logFmt:(NSString *)format, ...
{
  va_list args;
  va_start(args, format);
  NSLogv(format, args);
  va_end(args);
}

+ (void)verboseLog:(NSString *)message
{
  if (!FBConfiguration.sharedInstance.verboseLoggingEnabled) {
    return;
  }
  [self log:message];
}

+ (void)verboseLogFmt:(NSString *)format, ...
{
  if (!FBConfiguration.sharedInstance.verboseLoggingEnabled) {
    return;
  }
  va_list args;
  va_start(args, format);
  NSLogv(format, args);
  va_end(args);
}

+ (NSTimeInterval)performanceStart
{
  static BOOL enabled;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    enabled = [NSProcessInfo.processInfo.environment[@"HANDKITE_WDA_TIMINGS"]
      isEqualToString:@"1"];
  });
  return enabled ? NSProcessInfo.processInfo.systemUptime : 0;
}

+ (nullable NSDictionary *)performanceRecordForStage:(NSString *)stage
                                          startedAt:(NSTimeInterval)startedAt
                                         finishedAt:(NSTimeInterval)finishedAt
                                          completed:(BOOL)completed
{
  static NSSet<NSString *> *stages;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    stages = [NSSet setWithArray:@[
      @"route_queue", @"route_handler", @"element_cache",
      @"element_staleness", @"element_snapshot", @"element_tap",
      @"ax_snapshot", @"quiescence", @"screenshot", @"source"
    ]];
  });
  if (![stages containsObject:stage] || !isfinite(startedAt)
      || !isfinite(finishedAt) || startedAt <= 0 || finishedAt < startedAt) {
    return nil;
  }
  double startedMilliseconds = startedAt * 1000;
  double elapsedMilliseconds = (finishedAt - startedAt) * 1000;
  if (!isfinite(startedMilliseconds) || !isfinite(elapsedMilliseconds)) {
    return nil;
  }
  return @{
    @"kind": @"handkite_wda_timing",
    @"stage": stage,
    @"started_uptime_ms": @(startedMilliseconds),
    @"elapsed_ms": @(elapsedMilliseconds),
    @"completed": @(completed),
  };
}

+ (void)logPerformanceStage:(NSString *)stage
                  startedAt:(NSTimeInterval)startedAt
                  completed:(BOOL)completed
{
  if (startedAt <= 0) {
    return;
  }
  NSDictionary *record = [self performanceRecordForStage:stage
                                             startedAt:startedAt
                                            finishedAt:NSProcessInfo.processInfo.systemUptime
                                             completed:completed];
  NSData *data = nil == record ? nil
    : [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
  if (nil != data) {
    [self log:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
  }
}

@end
