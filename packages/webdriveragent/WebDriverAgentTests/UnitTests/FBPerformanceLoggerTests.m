/**
 * Copyright (c) 2026 Vincent Koc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import "FBLogger.h"

#include <math.h>
#include <float.h>

@interface FBLogger (PerformanceTests)
+ (nullable NSDictionary *)performanceRecordForStage:(NSString *)stage
                                          startedAt:(NSTimeInterval)startedAt
                                         finishedAt:(NSTimeInterval)finishedAt
                                          completed:(BOOL)completed;
@end

@interface FBPerformanceLoggerTests : XCTestCase
@end

@implementation FBPerformanceLoggerTests

- (void)testTimingRecordContainsOnlyFixedMetadata
{
  NSDictionary *record = [FBLogger performanceRecordForStage:@"element_staleness"
                                                  startedAt:10
                                                 finishedAt:10.25
                                                  completed:YES];
  XCTAssertEqualObjects(record, (@{
    @"kind": @"handkite_wda_timing",
    @"stage": @"element_staleness",
    @"started_uptime_ms": @10000,
    @"elapsed_ms": @250,
    @"completed": @YES,
  }));
  XCTAssertTrue([NSJSONSerialization isValidJSONObject:record]);
}

- (void)testUnknownStageCannotLogContent
{
  XCTAssertNil([FBLogger performanceRecordForStage:@"unexpected content"
                                        startedAt:10 finishedAt:11 completed:YES]);
}

- (void)testInvalidOrDisabledTimesAreRejected
{
  for (NSNumber *startedAt in @[@0, @(-1), @(NAN), @(INFINITY), @12, @(DBL_MAX)]) {
    XCTAssertNil([FBLogger performanceRecordForStage:@"element_staleness"
                                          startedAt:startedAt.doubleValue
                                         finishedAt:11 completed:YES]);
  }
  XCTAssertNil([FBLogger performanceRecordForStage:@"element_staleness"
                                        startedAt:10 finishedAt:INFINITY completed:YES]);
}

- (void)testIncompleteSpanIsNotReportedAsSuccessful
{
  NSDictionary *record = [FBLogger performanceRecordForStage:@"element_staleness"
                                                  startedAt:10
                                                 finishedAt:10
                                                  completed:NO];
  XCTAssertEqualObjects(record[@"elapsed_ms"], @0);
  XCTAssertEqualObjects(record[@"completed"], @NO);
}

@end
