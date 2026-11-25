/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */


#import <XCTest/XCTest.h>

#import "FBElement.h"
#import "XCUIElementDouble.h"
#import "FBElementUtils.h"
#import "FBConfiguration.h"
#import "XCUIElement+FBUtilities.h"
#import "XCUIElement+FBCaching.h"
#import "XCElementSnapshotDouble.h"
#import <objc/runtime.h>

@interface FBQuiescenceApplicationDouble : NSObject
@property (nonatomic) BOOL fb_shouldWaitForQuiescence;
@property (nonatomic) NSTimeInterval observedTimeout;
@end
@implementation FBQuiescenceApplicationDouble
- (id)applicationImpl { return self; }
- (id)currentProcess { return self; }
- (void)fb_waitForQuiescenceIncludingAnimationsIdle:(BOOL)includingAnimations
{
  self.observedTimeout = FBConfiguration.sharedInstance.waitForIdleTimeout;
  @throw [NSException exceptionWithName:@"QuiescenceFailure" reason:@"test" userInfo:nil];
}
@end

@interface FBLookupAXDouble : NSObject
@property (nonatomic) int processIdentifier;
@property (nonatomic, strong) NSDictionary *payload;
@end
@implementation FBLookupAXDouble
- (id)valueForKey:(NSString *)key
{
  return [key isEqualToString:@"_elementID"]
    ? self.payload[@"uid.elementID"] : [super valueForKey:key];
}
@end

@interface FBLookupSnapshotDouble : XCElementSnapshotDouble
@property (nonatomic, strong) FBLookupAXDouble *ax;
@property (nonatomic, strong) NSArray *descendants;
@end
@implementation FBLookupSnapshotDouble
- (id)accessibilityElement { return self.ax; }
- (NSArray *)_allDescendants { return self.descendants ?: @[]; }
@end

@interface FBLookupElementDouble : NSObject
@property (nonatomic, strong) FBLookupAXDouble *ax;
@property (nonatomic, strong) id lastSnapshot;
@property (nonatomic) BOOL throwsOnCache;
@end
@implementation FBLookupElementDouble
- (id)fb_boundAccessibilityElement { return self.ax; }
- (void)fb_cacheSnapshot:(id)snapshot
{
  self.lastSnapshot = snapshot;
  if (self.throwsOnCache) {
    @throw [NSException exceptionWithName:@"fixture" reason:nil userInfo:nil];
  }
}
@end

@interface FBElementUtilitiesTests : XCTestCase
@end

@implementation FBElementUtilitiesTests

- (void)testStabilityWaitRestoresSettingsAfterAnException
{
  NSTimeInterval originalTimeout = FBConfiguration.sharedInstance.waitForIdleTimeout;
  FBQuiescenceApplicationDouble *application = [FBQuiescenceApplicationDouble new];
  XCUIElementDouble *element = [XCUIElementDouble new];
  element.application = (id)application;
  SEL selector = @selector(fb_waitUntilStableWithTimeout:);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wcast-function-type-strict"
  void (*wait)(id, SEL, NSTimeInterval) = (void (*)(id, SEL, NSTimeInterval))
    class_getMethodImplementation(XCUIElement.class, selector);
#pragma clang diagnostic pop
  @try {
    FBConfiguration.sharedInstance.waitForIdleTimeout = 17;
    XCTAssertThrowsSpecificNamed(wait(element, selector, 2), NSException, @"QuiescenceFailure");
    XCTAssertEqual(application.observedTimeout, 2);
    XCTAssertFalse(application.fb_shouldWaitForQuiescence);
    XCTAssertEqual(FBConfiguration.sharedInstance.waitForIdleTimeout, 17);
  } @finally {
    FBConfiguration.sharedInstance.waitForIdleTimeout = originalTimeout;
  }
}

- (void)testTypesFiltering {
  NSMutableArray *elements = [NSMutableArray new];
  XCUIElementDouble *el1 = [XCUIElementDouble new];
  [elements addObject:el1];
  XCUIElementDouble *el2 = [XCUIElementDouble new];
  el2.elementType = XCUIElementTypeAlert;
  el2.wdType = @"XCUIElementTypeAlert";
  [elements addObject:el2];
  XCUIElementDouble *el3 = [XCUIElementDouble new];
  [elements addObject:el3];
  
  NSSet *result = [FBElementUtils uniqueElementTypesWithElements:elements];
  XCTAssertEqual([result count], 2);
}

- (FBLookupSnapshotDouble *)lookupSnapshot:(NSUInteger)uid
{
  FBLookupSnapshotDouble *snapshot = [FBLookupSnapshotDouble new];
  snapshot.ax = [FBLookupAXDouble new];
  snapshot.ax.payload = @{@"uid.elementID": @(uid)};
  snapshot.ax.processIdentifier = 42;
  return snapshot;
}

- (FBLookupElementDouble *)lookupElement:(FBLookupSnapshotDouble *)snapshot
{
  FBLookupElementDouble *element = [FBLookupElementDouble new];
  element.ax = snapshot.ax;
  return element;
}

- (void)testLookupSnapshotIncludesSelfAndMatchesReorderedIds
{
  FBLookupSnapshotDouble *root = [self lookupSnapshot:1];
  FBLookupSnapshotDouble *a = [self lookupSnapshot:2];
  FBLookupSnapshotDouble *b = [self lookupSnapshot:3];
  root.descendants = @[a, b];
  FBLookupElementDouble *scope = [FBLookupElementDouble new];
  FBLookupElementDouble *first = [self lookupElement:a];
  FBLookupElementDouble *second = [self lookupElement:b];
  XCTAssertTrue(FBCacheSnapshotsFromLookup((id)@[second, scope, first],
    (id)scope, (id)root));
  XCTAssertEqual(second.lastSnapshot, b);
  XCTAssertEqual(scope.lastSnapshot, root);
  XCTAssertEqual(first.lastSnapshot, a);
}

- (void)testLookupSnapshotRefusesPartialOrAmbiguousCoverageAtomically
{
  for (NSUInteger scenario = 0; scenario < 4; scenario++) {
    FBLookupSnapshotDouble *root = [self lookupSnapshot:1];
    FBLookupSnapshotDouble *child = [self lookupSnapshot:2];
    root.descendants = scenario == 1
      ? @[child, [self lookupSnapshot:2]] : @[child];
    FBLookupElementDouble *scope = [FBLookupElementDouble new];
    FBLookupElementDouble *element = [self lookupElement:
      [self lookupSnapshot:scenario == 0 ? 3 : 2]];
    if (scenario == 2) {
      element.ax = nil;
    }
    NSArray *elements = scenario == 3
      ? @[scope, element, [self lookupElement:child]] : @[scope, element];
    for (FBLookupElementDouble *item in elements) {
      item.lastSnapshot = @"unchanged";
    }
    XCTAssertFalse(FBCacheSnapshotsFromLookup((id)elements, (id)scope, (id)root));
    for (FBLookupElementDouble *item in elements) {
      XCTAssertEqualObjects(item.lastSnapshot, @"unchanged");
    }
  }
}

- (void)testLookupSnapshotClearsPartialAssignmentOnException
{
  FBLookupSnapshotDouble *root = [self lookupSnapshot:1];
  FBLookupSnapshotDouble *child = [self lookupSnapshot:2];
  root.descendants = @[child];
  FBLookupElementDouble *scope = [FBLookupElementDouble new];
  FBLookupElementDouble *element = [self lookupElement:child];
  element.throwsOnCache = YES;
  XCTAssertThrowsSpecificNamed(FBCacheSnapshotsFromLookup((id)@[scope, element],
    (id)scope, (id)root), NSException, @"fixture");
  XCTAssertNil(scope.lastSnapshot);
  XCTAssertNil(element.lastSnapshot);
}

@end
