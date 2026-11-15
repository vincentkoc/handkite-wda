/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBLogger.h"

#import "FBConfiguration.h"
#import "XCTestPrivateSymbols.h"
#import "XCDebugLogDelegate-Protocol.h"

#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>
#import <time.h>

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

@end

static NSString *const FBReadTimingThreadKey = @"FBReadTiming.current";
static atomic_uint_fast64_t FBReadTimingNextID;

static uint64_t FBReadTimingNow(void)
{
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (uint64_t)now.tv_sec * NSEC_PER_SEC + (uint64_t)now.tv_nsec;
}

@interface FBReadTiming ()
@property (nonatomic, copy) NSString *route;
@property (nonatomic) uint64_t identifier;
@property (nonatomic) uint64_t enqueuedAt;
@property (nonatomic, strong, nullable) FBReadTiming *previous;
@end

@implementation FBReadTiming

+ (instancetype)enqueueMethod:(NSString *)method routePath:(NSString *)path
{
  const char *enabled = getenv("HANDKITE_WDA_READ_TIMINGS");
  if (NULL == enabled || 0 != strcmp(enabled, "1")
      || ![method isEqualToString:@"GET"]) {
    return nil;
  }
  // Classify only static registered routes; no request data enters an event.
  NSString *route = nil;
  if ([path isEqualToString:@"/source"]
      || [path isEqualToString:@"/session/:sessionID/source"]) {
    route = @"source";
  } else if ([path isEqualToString:@"/wda/activeAppInfo"]
             || [path isEqualToString:@"/session/:sessionID/wda/activeAppInfo"]) {
    route = @"activeAppInfo";
  } else if ([path isEqualToString:@"/wda/locked"]
             || [path isEqualToString:@"/session/:sessionID/wda/locked"]) {
    route = @"locked";
  } else if ([path isEqualToString:@"/session/:sessionID"]) {
    route = @"session";
  }
  if (nil == route) {
    return nil;
  }
  FBReadTiming *timing = [self new];
  timing.route = route;
  timing.identifier = atomic_fetch_add(&FBReadTimingNextID, 1) + 1;
  timing.enqueuedAt = FBReadTimingNow();
  [timing emitPhase:@"handler" event:@"enqueue" elapsed:0];
  return timing;
}

- (void)emitPhase:(NSString *)phase event:(NSString *)event
         elapsed:(uint64_t)elapsed
{
  // Send only fixed enums and numbers through XCTest's existing transport.
  // Diagnostic transport failure must not change request/error behavior.
  @try {
    if (NULL != XCDebugLogger) {
      [XCDebugLogger() logDebugMessage:[NSString stringWithFormat:
        @"handkite_wda_read_timing {\"v\":1,\"id\":%llu,\"route\":\"%@\","
         "\"phase\":\"%@\",\"event\":\"%@\",\"elapsed_us\":%llu}",
        (unsigned long long)self.identifier, self.route, phase, event,
        (unsigned long long)elapsed]];
    }
  } @catch (NSException *exception) {
    // Deliberately do not log the exception or its payload.
  }
}

- (void)emitPhase:(NSString *)phase event:(NSString *)event
{
  [self emitPhase:phase event:event
         elapsed:(FBReadTimingNow() - self.enqueuedAt) / 1000];
}

- (void)enter
{
  NSMutableDictionary *thread = NSThread.currentThread.threadDictionary;
  self.previous = thread[FBReadTimingThreadKey];
  thread[FBReadTimingThreadKey] = self;
  [self emitPhase:@"handler" event:@"entry"];
}

- (void)exit
{
  [self emitPhase:@"handler" event:@"exit"];
  NSMutableDictionary *thread = NSThread.currentThread.threadDictionary;
  if (nil == self.previous) {
    [thread removeObjectForKey:FBReadTimingThreadKey];
  } else {
    thread[FBReadTimingThreadKey] = self.previous;
  }
  self.previous = nil;
}

+ (void)phase:(FBReadTimingPhase)phase entering:(BOOL)entering
{
  FBReadTiming *timing = NSThread.currentThread.threadDictionary[FBReadTimingThreadKey];
  if (![timing.route isEqualToString:@"source"]) {
    return;
  }
  NSString *name;
  switch (phase) {
    case FBReadTimingPhaseActiveApp: name = @"active_app"; break;
    case FBReadTimingPhaseQuiescence: name = @"quiescence"; break;
    case FBReadTimingPhaseSnapshot: name = @"snapshot"; break;
    case FBReadTimingPhaseSerialize: name = @"serialize"; break;
    default: return;
  }
  [timing emitPhase:name event:entering ? @"entry" : @"exit"];
}

@end
