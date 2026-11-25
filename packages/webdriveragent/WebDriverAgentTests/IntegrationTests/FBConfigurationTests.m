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
#import "XCUIElement+FBFind.h"
#import "XCUIElement+FBCaching.h"
#import "FBResponsePayload.h"
#import "FBElementCache.h"

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

- (void)testRichLookupUsesCurrentValuesWithStableIdentity
{
  FBConfiguration *configuration = FBConfiguration.sharedInstance;
  BOOL compact = configuration.shouldUseCompactResponses;
  BOOL boundByIndex = configuration.boundElementsByIndex;
  NSString *attributes = configuration.elementResponseAttributes;
  NSArray<XCUIElement *> *beforeElements = nil;
  NSArray<XCUIElement *> *afterElements = nil;
  @try {
    configuration.shouldUseCompactResponses = NO;
    configuration.boundElementsByIndex = NO;
    configuration.elementResponseAttributes = @"type,label,rect,enabled,attribute/name,attribute/value";
    self.testedApplication.launchArguments = @[@"--query-snapshot-fixture"];
    [self.testedApplication launch];
    XCTAssertTrue([self.testedApplication.buttons[@"snapshot-update"]
      waitForExistenceWithTimeout:5]);
    NSPredicate *predicate = [NSPredicate predicateWithFormat:
      @"type == 'XCUIElementTypeApplication' OR name == 'snapshot-target'"];
    beforeElements = [self.testedApplication fb_descendantsMatchingPredicateForResponse:predicate];
    XCTAssertEqual(beforeElements.count, 2u);
    NSDictionary *before = nil;
    for (XCUIElement *element in beforeElements) {
      XCTAssertNotNil(element.lastSnapshot);
      NSDictionary *row = FBDictionaryResponseWithElement(element, NO);
      if ([row[@"attribute/name"] isEqual:@"snapshot-target"]) {
        before = row;
      }
    }
    FBResponseWithCachedElements(beforeElements, [FBElementCache new], NO);
    for (XCUIElement *element in beforeElements) {
      XCTAssertNil(element.lastSnapshot);
    }
    XCTAssertNotNil(before);
    XCTAssertNotNil(before[@"ELEMENT"]);
    XCTAssertEqualObjects(before[@"label"], @"Before");
    XCTAssertEqualObjects(before[@"attribute/value"], @"before");
    XCTAssertEqualObjects(before[@"enabled"], @YES);
    [self.testedApplication.buttons[@"snapshot-update"] tap];
    afterElements = [self.testedApplication fb_descendantsMatchingPredicateForResponse:predicate];
    XCTAssertEqual(afterElements.count, 2u);
    NSDictionary *after = nil;
    for (XCUIElement *element in afterElements) {
      XCTAssertNotNil(element.lastSnapshot);
      NSDictionary *row = FBDictionaryResponseWithElement(element, NO);
      if ([row[@"attribute/name"] isEqual:@"snapshot-target"]) {
        after = row;
      }
    }
    FBResponseWithCachedElements(afterElements, [FBElementCache new], NO);
    for (XCUIElement *element in afterElements) {
      XCTAssertNil(element.lastSnapshot);
    }
    XCTAssertNotNil(after);
    XCTAssertNotNil(after[@"ELEMENT"]);
    XCTAssertEqualObjects(before[@"ELEMENT"], after[@"ELEMENT"]);
    XCTAssertEqualObjects(after[@"label"], @"After");
    XCTAssertEqualObjects(after[@"attribute/value"], @"after");
    XCTAssertEqualObjects(after[@"enabled"], @NO);
    XCTAssertEqualWithAccuracy([after[@"rect"][@"x"] doubleValue],
      [before[@"rect"][@"x"] doubleValue] + 20, 0.5);
    XCTAssertEqualWithAccuracy([after[@"rect"][@"y"] doubleValue],
      [before[@"rect"][@"y"] doubleValue] + 10, 0.5);
    // Single link-text lookups use this property helper and discard all but
    // their first result. They must not inherit response-only snapshot seeding.
    NSArray<XCUIElement *> *links = [self.testedApplication
      fb_descendantsMatchingProperty:@"name" value:@"snapshot-" partialSearch:YES];
    XCTAssertGreaterThan(links.count, 1u);
    for (XCUIElement *element in links) {
      XCTAssertNil(element.lastSnapshot);
    }
    XCTAssertNil(self.testedApplication.lastSnapshot);
  } @finally {
    NSArray *allElements = [(beforeElements ?: @[])
      arrayByAddingObjectsFromArray:(afterElements ?: @[])];
    for (XCUIElement *element in allElements) {
      element.lastSnapshot = nil;
    }
    configuration.shouldUseCompactResponses = compact;
    configuration.boundElementsByIndex = boundByIndex;
    configuration.elementResponseAttributes = attributes;
    [self.testedApplication terminate];
  }
}

@end
