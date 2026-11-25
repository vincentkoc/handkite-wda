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
#import "XCUIElement+FBIsVisible.h"
#import "FBXCElementSnapshotWrapper+Helpers.h"
#import "XCElementSnapshotDouble.h"
#import "XCTestPrivateSymbols.h"
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

@interface FBVisibilityAXDouble : NSObject
@property (nonatomic, strong) NSDictionary *payload;
@property (nonatomic) int processIdentifier;
@end
@implementation FBVisibilityAXDouble
- (id)valueForKey:(NSString *)key
{
  return [key isEqualToString:@"_elementID"]
    ? self.payload[@"uid.elementID"] : [super valueForKey:key];
}
@end

@interface FBVisibilitySnapshotDouble : XCElementSnapshotDouble
@property (nonatomic, strong) FBVisibilityAXDouble *ax;
@property (nonatomic, strong) NSArray *descendants;
@end
@implementation FBVisibilitySnapshotDouble
- (id)accessibilityElement { return self.ax; }
- (NSArray *)_allDescendants { return self.descendants ?: @[]; }
@end

@interface FBXCElementSnapshotWrapper (VisibilityTestInit)
- (instancetype)initWithSnapshot:(id<FBXCElementSnapshot>)snapshot;
@end

@interface FBVisibilityWrapperDouble : FBXCElementSnapshotWrapper
@property (nonatomic, strong) NSNumber *nativeResult;
@property (nonatomic) NSUInteger reads;
@end
@implementation FBVisibilityWrapperDouble
- (id)fb_attributeValue:(NSString *)attribute error:(NSError **)error
{
  self.reads++;
  return self.nativeResult;
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

- (FBVisibilitySnapshotDouble *)visibilitySnapshot:(NSUInteger)uid
                                          value:(id)value
{
  FBVisibilitySnapshotDouble *snapshot = [FBVisibilitySnapshotDouble new];
  snapshot.ax = [FBVisibilityAXDouble new];
  snapshot.ax.payload = @{@"uid.elementID": @(uid)};
  snapshot.ax.processIdentifier = 42;
  if (nil != value) {
    snapshot.additionalAttributes[FB_XCAXAIsVisibleAttribute] = value;
  }
  return snapshot;
}

- (FBVisibilityWrapperDouble *)visibilityWrapper:(FBVisibilitySnapshotDouble *)snapshot
{
  FBVisibilityWrapperDouble *wrapper = [[FBVisibilityWrapperDouble alloc]
    initWithSnapshot:(id)snapshot];
  wrapper.nativeResult = @NO;
  return wrapper;
}

- (void)testPrefetchedVisibilityPreservesCachedFalse
{
  FBVisibilitySnapshotDouble *target = [self visibilitySnapshot:1 value:@NO];
  FBVisibilityWrapperDouble *wrapper = [self visibilityWrapper:target];
  NSUInteger used = FBWithPrefetchedVisibility(@[(id)target],
    @[(id)[self visibilitySnapshot:1 value:@YES]], ^{
      XCTAssertFalse(wrapper.fb_isVisible);
      XCTAssertEqual(wrapper.reads, 0u);
    });
  XCTAssertEqual(used, 0u);
}

- (void)testPrefetchedVisibilityPreservesVisibleDescendantShortcut
{
  FBVisibilitySnapshotDouble *target = [self visibilitySnapshot:1 value:nil];
  target.descendants = @[[self visibilitySnapshot:2 value:@YES]];
  FBVisibilityWrapperDouble *wrapper = [self visibilityWrapper:target];
  NSUInteger used = FBWithPrefetchedVisibility(@[(id)target],
    @[(id)[self visibilitySnapshot:1 value:@NO]], ^{
      XCTAssertTrue(wrapper.fb_isVisible);
      XCTAssertEqual(wrapper.reads, 0u);
    });
  XCTAssertEqual(used, 0u);
}

- (void)testPrefetchedVisibilitySuppliesBothNativeBooleanValues
{
  for (NSNumber *visible in @[@YES, @NO]) {
    FBVisibilitySnapshotDouble *target = [self visibilitySnapshot:1 value:nil];
    FBVisibilityWrapperDouble *wrapper = [self visibilityWrapper:target];
    NSUInteger used = FBWithPrefetchedVisibility(@[(id)target],
      @[(id)[self visibilitySnapshot:1 value:visible]], ^{
        XCTAssertEqual(wrapper.fb_isVisible, visible.boolValue);
        XCTAssertEqual(wrapper.reads, 0u);
      });
    XCTAssertEqual(used, 1u);
    XCTAssertEqualObjects(target.additionalAttributes[FB_XCAXAIsVisibleAttribute], visible);
  }
}

- (void)testMissingAmbiguousOrMalformedVisibilityUsesNativeGetter
{
  for (NSArray *source in @[
    @[],
    @[[self visibilitySnapshot:2 value:@YES]],
    @[[self visibilitySnapshot:1 value:@YES], [self visibilitySnapshot:1 value:@NO]],
    @[[self visibilitySnapshot:1 value:nil]],
    @[[self visibilitySnapshot:1 value:@"invalid"]]
  ]) {
    FBVisibilitySnapshotDouble *target = [self visibilitySnapshot:1 value:nil];
    FBVisibilityWrapperDouble *wrapper = [self visibilityWrapper:target];
    NSUInteger used = FBWithPrefetchedVisibility(@[(id)target], source, ^{
      XCTAssertFalse(wrapper.fb_isVisible);
      XCTAssertEqual(wrapper.reads, 1u);
    });
    XCTAssertEqual(used, 0u);
  }
}

- (void)testAmbiguousTargetIdsDoNotReceivePrefetchedVisibility
{
  FBVisibilitySnapshotDouble *target = [self visibilitySnapshot:1 value:nil];
  FBVisibilitySnapshotDouble *other = [self visibilitySnapshot:1 value:nil];
  FBVisibilityWrapperDouble *wrapper = [self visibilityWrapper:target];
  FBWithPrefetchedVisibility(@[(id)target, (id)other],
    @[(id)[self visibilitySnapshot:1 value:@YES]], ^{
      XCTAssertFalse(wrapper.fb_isVisible);
      XCTAssertEqual(wrapper.reads, 1u);
    });
}

- (void)testVisibilityPrefetchDoesNotSurviveExceptionOrNextRequest
{
  for (NSNumber *throws in @[@NO, @YES]) {
    FBVisibilitySnapshotDouble *target = [self visibilitySnapshot:1 value:nil];
    FBVisibilityWrapperDouble *wrapper = [self visibilityWrapper:target];
    @try {
      FBWithPrefetchedVisibility(@[(id)target],
        @[(id)[self visibilitySnapshot:1 value:@YES]], ^{
          if (throws.boolValue) {
            @throw [NSException exceptionWithName:@"fixture" reason:nil userInfo:nil];
          }
        });
    } @catch (NSException *exception) {
      XCTAssertEqualObjects(exception.name, @"fixture");
    }
    XCTAssertFalse(wrapper.fb_isVisible);
    XCTAssertEqual(wrapper.reads, 1u);
  }
}

- (void)testVisibilityPrefetchIncludesOtherProcessDescendants
{
  FBVisibilitySnapshotDouble *target = [self visibilitySnapshot:1 value:nil];
  FBVisibilitySnapshotDouble *source = [self visibilitySnapshot:1 value:@YES];
  target.ax.processIdentifier = source.ax.processIdentifier = 77;
  FBVisibilityWrapperDouble *wrapper = [self visibilityWrapper:target];
  FBWithPrefetchedVisibility(@[(id)target], @[(id)source], ^{
    XCTAssertTrue(wrapper.fb_isVisible);
    XCTAssertEqual(wrapper.reads, 0u);
  });
}

@end
