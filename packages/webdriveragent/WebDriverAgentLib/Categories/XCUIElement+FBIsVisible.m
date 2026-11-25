/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "XCUIElement+FBIsVisible.h"

#import "FBElementUtils.h"
#import "FBXCodeCompatibility.h"
#import "FBXCElementSnapshotWrapper+Helpers.h"
#import "XCUIElement+FBUtilities.h"
#import "XCUIElement+FBVisibleFrame.h"
#import "XCTestPrivateSymbols.h"
#import "XCUIElement+FBUID.h"
#import <objc/runtime.h>

NSNumber* _Nullable fetchSnapshotVisibility(id<FBXCElementSnapshot> snapshot)
{
  return nil == snapshot.additionalAttributes ? nil : snapshot.additionalAttributes[FB_XCAXAIsVisibleAttribute];
}

static char FBPrefetchedVisibilityKey;

@interface FBPrefetchedVisibilityValue : NSObject
@property (nonatomic, strong) NSNumber *value;
@property (nonatomic) BOOL used;
@end
@implementation FBPrefetchedVisibilityValue
@end

static NSDictionary<NSString *, id<FBXCElementSnapshot>> *FBUniqueSnapshots(
  NSArray<id<FBXCElementSnapshot>> *snapshots)
{
  NSMutableDictionary *result = [NSMutableDictionary dictionary];
  NSMutableSet *duplicates = [NSMutableSet set];
  for (id<FBXCElementSnapshot> snapshot in snapshots) {
    NSString *uid = [FBXCElementSnapshotWrapper wdUIDWithSnapshot:snapshot];
    if (nil == uid || [duplicates containsObject:uid]) {
      continue;
    }
    if (nil != result[uid]) {
      [result removeObjectForKey:uid];
      [duplicates addObject:uid];
    } else {
      result[uid] = snapshot;
    }
  }
  return result;
}

NSUInteger FBWithPrefetchedVisibility(NSArray<id<FBXCElementSnapshot>> *snapshots,
                               NSArray<id<FBXCElementSnapshot>> *visibilitySnapshots,
                               void (^body)(void))
{
  NSMutableArray *scoped = [NSMutableArray array];
  @try {
    NSDictionary *targets = FBUniqueSnapshots(snapshots);
    NSDictionary *sources = FBUniqueSnapshots(visibilitySnapshots);
    for (NSString *uid in targets) {
      id<FBXCElementSnapshot> target = targets[uid];
      id<FBXCElementSnapshot> source = sources[uid];
      id visible = source.additionalAttributes[FB_XCAXAIsVisibleAttribute];
      if (nil != fetchSnapshotVisibility(target)
          || ![visible isKindOfClass:NSNumber.class]) {
        continue;
      }
      id raw = [FBXCElementSnapshotWrapper ensureWrapped:target].snapshot;
      [scoped addObject:raw];
      FBPrefetchedVisibilityValue *entry = [FBPrefetchedVisibilityValue new];
      entry.value = visible;
      objc_setAssociatedObject(raw, &FBPrefetchedVisibilityKey, entry,
                               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    body();
    NSUInteger used = 0;
    for (id snapshot in scoped) {
      FBPrefetchedVisibilityValue *entry = objc_getAssociatedObject(
        snapshot, &FBPrefetchedVisibilityKey);
      used += entry.used ? 1 : 0;
    }
    return used;
  } @finally {
    for (id snapshot in scoped) {
      objc_setAssociatedObject(snapshot, &FBPrefetchedVisibilityKey, nil,
                               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
  }
}

@implementation XCUIElement (FBIsVisible)

- (BOOL)fb_isVisible
{
  @autoreleasepool {
    id<FBXCElementSnapshot> snapshot = [self fb_standardSnapshot];
    return [FBXCElementSnapshotWrapper ensureWrapped:snapshot].fb_isVisible;
  }
}

@end

@implementation FBXCElementSnapshotWrapper (FBIsVisible)

- (BOOL)fb_hasVisibleDescendants
{
  for (id<FBXCElementSnapshot> descendant in (self._allDescendants ?: @[])) {
    if ([fetchSnapshotVisibility(descendant) boolValue]) {
      return YES;
    }
  }
  return NO;
}

- (BOOL)fb_isVisible
{
  NSNumber *isVisible = fetchSnapshotVisibility(self);
  if (nil != isVisible) {
    return isVisible.boolValue;
  }

  // Fetching the attribute value is expensive.
  // Shortcircuit here to save time and assume if any of descendants
  // is already determined as visible then the container should be visible as well
  if ([self fb_hasVisibleDescendants]) {
    return YES;
  }

  NSError *error = nil;
  FBPrefetchedVisibilityValue *prefetched = objc_getAssociatedObject(
    self.snapshot, &FBPrefetchedVisibilityKey);
  NSNumber *attributeValue = prefetched.value;
  prefetched.used = nil != attributeValue;
  if (nil == attributeValue) {
    attributeValue = [self fb_attributeValue:FB_XCAXAIsVisibleAttributeName
                                       error:&error];
  }
  if (nil != attributeValue) {
    NSMutableDictionary *updatedValue = [NSMutableDictionary dictionaryWithDictionary:self.additionalAttributes ?: @{}];
    [updatedValue setObject:attributeValue forKey:FB_XCAXAIsVisibleAttribute];
    self.snapshot.additionalAttributes = updatedValue.copy;
    @autoreleasepool {
      return [attributeValue boolValue];
    }
  }

  NSLog(@"Cannot determine visiblity of %@ natively: %@. Defaulting to: %@",
        self.fb_description, error.description, @(NO));
  return NO;
}

@end
