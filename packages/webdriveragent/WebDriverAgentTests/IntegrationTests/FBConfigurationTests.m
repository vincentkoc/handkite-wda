/**
* Copyright (c) 2015-present, Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD-style license found in the
* LICENSE file in the root directory of this source tree.
*/

#import <XCTest/XCTest.h>
#import "FBIntegrationTestCase.h"

#import "FBConfiguration.h"
#import "FBRuntimeUtils.h"
#import "FBTestMacros.h"
#import "FBXCAccessibilityElement.h"
#import "FBXCAXClientProxy.h"
#import "XCUIApplication.h"
#import "XCUIElement.h"
#import "XCUIElement+FBIsVisible.h"
#import "XCUIElement+FBUtilities.h"
#import "XCUIElement+FBUID.h"
#import "XCTestPrivateSymbols.h"

@interface FBConfigurationTests : FBIntegrationTestCase

@end

@implementation FBConfigurationTests

- (void)testReduceMotion
{
  [self launchApplication];

  BOOL defaultReduceMotionEnabled = FBConfiguration.sharedInstance.reduceMotionEnabled;

  FBConfiguration.sharedInstance.reduceMotionEnabled = YES;
  XCTAssertTrue(FBConfiguration.sharedInstance.reduceMotionEnabled);

  FBConfiguration.sharedInstance.reduceMotionEnabled = defaultReduceMotionEnabled;
  XCTAssertEqual(FBConfiguration.sharedInstance.reduceMotionEnabled, defaultReduceMotionEnabled);
}

- (void)testAccessibilityDeadlineAbortsSnapshotRequestForDeadlockedApp
{
  if (FBIntegrationTestCase.isRunningInCI) {
    XCTSkip(@"Deliberately freezes the app for several seconds, too slow/flaky for CI");
  }

  // Launch only after the CI skip so a skipped test cannot time out in app startup.
  [self launchApplication];

  NSTimeInterval previousDeadline = FBConfiguration.sharedInstance.accessibilityDeadline;
  // Also bounds any snapshot-based wait -tap itself may perform once the app is stuck.
  FBConfiguration.sharedInstance.accessibilityDeadline = 3.0;
  @try {
    XCUIElement *deadlockButton = self.testedApplication.buttons[@"Deadlock app"];
    FBAssertWaitTillBecomesTrue(deadlockButton.fb_isVisible);
    // Freezes the app's main thread for 20s - see -[ViewController deadlockApp:].
    [deadlockButton tap];

    NSError *error;
    NSDate *start = [NSDate date];
    id snapshot = [self.testedApplication snapshotWithError:&error];
    NSTimeInterval elapsed = -start.timeIntervalSinceNow;

    XCTAssertNil(snapshot);
    XCTAssertNotNil(error);
    // Should abort close to accessibilityDeadline (plus XCTest's own internal
    // retries), not hang indefinitely waiting for the frozen app (#1210).
    XCTAssertLessThan(elapsed, 20.0);
  } @finally {
    FBConfiguration.sharedInstance.accessibilityDeadline = previousDeadline;
    [self.testedApplication terminate];
  }
}

- (void)testAccessibilityDeadlineAllowsResponsiveNativeAppSnapshots
{
  [self launchApplication];
  NSTimeInterval previousDeadline = FBConfiguration.sharedInstance.accessibilityDeadline;
  @try {
    FBConfiguration.sharedInstance.accessibilityDeadline = 3;
    NSError *error = nil;
    XCTAssertNotNil([self.testedApplication snapshotWithError:&error]);
    XCTAssertNil(error);
  } @finally {
    FBConfiguration.sharedInstance.accessibilityDeadline = previousDeadline;
    [self.testedApplication terminate];
  }
}

- (void)testAccessibilityDeadlineAllowsWebContentSnapshots
{
  NSTimeInterval previousDeadline = FBConfiguration.sharedInstance.accessibilityDeadline;
  @try {
    // Resolve the remote AX element before enabling the guard so the test
    // exercises a WebContent-owned snapshot, not just the host app's tree.
    FBConfiguration.sharedInstance.accessibilityDeadline = 0;
    self.testedApplication.launchArguments = @[@"--webview-fixture"];
    [self.testedApplication launch];
    XCUIElement *text = self.testedApplication.webViews.staticTexts[
      @"WebContent snapshot fixture"];
    XCTAssertTrue([text waitForExistenceWithTimeout:15]);
    NSError *error = nil;
    id<FBXCElementSnapshot> initial = [text snapshotWithError:&error];
    XCTAssertNotNil(initial);
    XCTAssertNil(error);
    id<FBXCAccessibilityElement> element = initial.accessibilityElement;
    XCTAssertNotEqual(element.processIdentifier, self.testedApplication.processID);

    FBConfiguration.sharedInstance.accessibilityDeadline = 3;
    for (NSUInteger i = 0; i < 3; i++) {
      error = nil;
      id<FBXCElementSnapshot> snapshot = [FBXCAXClientProxy.sharedClient
        snapshotForElement:element attributes:@[] inDepth:YES error:&error];
      XCTAssertNotNil(snapshot);
      XCTAssertNil(error);
    }
    XCTAssertTrue(text.exists);
  } @finally {
    FBConfiguration.sharedInstance.accessibilityDeadline = previousDeadline;
    [self.testedApplication terminate];
  }
}

// Diagnostic for the exact native request used by inventory prefetching.
// This runs against the synthetic test app, never a connected personal app.
- (void)testInventoryVisibilityAttributeCostAndParity
{
  @try {
    [self launchApplication];
    [self goToAttributesPage];
    [self.testedApplication.textFields[@"aIdentifier"] tap];
    XCTAssertTrue([self.testedApplication.keyboards.firstMatch
      waitForExistenceWithTimeout:5]);
    for (NSUInteger trial = 0; trial < 3; trial++) {
      id<FBXCElementSnapshot> root = [self.testedApplication fb_standardSnapshot];
      NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
      for (NSUInteger offset = 0; offset < 2; offset++) {
        BOOL minimal = (trial + offset) % 2 != 0;
        NSArray *attributes = minimal ? @[FB_XCAXAIsVisibleAttributeName]
          : [FBStandardAttributeNames()
             arrayByAddingObject:FB_XCAXAIsVisibleAttributeName];
        __block NSError *error = nil;
        NSError *timeoutError = nil;
        __block id<FBXCElementSnapshot> snapshot = nil;
        NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
        BOOL completed = [FBXCAXClientProxy.sharedClient withAXTimeout:20 do:^{
          snapshot = [FBXCAXClientProxy.sharedClient
            snapshotForElement:root.accessibilityElement attributes:attributes
            inDepth:YES error:&error];
        } error:&timeoutError];
        XCTAssertTrue(completed);
        XCTAssertNil(timeoutError);
        XCTAssertNil(error);
        XCTAssertNotNil(snapshot);
        NSMutableArray *nodes = [NSMutableArray arrayWithObject:snapshot];
        [nodes addObjectsFromArray:[(id)snapshot _allDescendants] ?: @[]];
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        for (id<FBXCElementSnapshot> node in nodes) {
          NSString *uid = [FBXCElementSnapshotWrapper wdUIDWithSnapshot:node];
          id visible = node.additionalAttributes[FB_XCAXAIsVisibleAttribute];
          XCTAssertNotNil(uid);
          XCTAssertTrue([visible isKindOfClass:NSNumber.class]);
          XCTAssertTrue([visible isEqual:@YES] || [visible isEqual:@NO]);
          if (nil == values[uid]) {
            values[uid] = [NSMutableArray array];
          }
          [values[uid] addObject:visible];
        }
        XCTAssertGreaterThan(values.count, 8u);
        for (NSMutableArray *aliases in values.allValues) {
          [aliases sortUsingSelector:@selector(compare:)];
        }
        // Native aliases carry no additional authority. Preserve them here so
        // neither missing nodes nor changed multiplicities can pass parity.
        [results addObject:values];
        NSLog(@"visibility_contract minimal=%u nodes=%lu ms=%.3f",
          minimal ? 1U : 0U, (unsigned long)nodes.count,
          (NSProcessInfo.processInfo.systemUptime - started) * 1000);
      }
      XCTAssertEqualObjects(results[0], results[1]);
    }
  } @finally {
    [self.testedApplication terminate];
  }
}

@end
