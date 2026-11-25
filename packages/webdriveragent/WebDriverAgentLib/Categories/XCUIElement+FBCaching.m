/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "XCUIElement+FBCaching.h"
#import "XCUIElement.h"

#import <objc/runtime.h>

#import "FBXCElementSnapshotWrapper+Helpers.h"
#import "XCUIElement+FBWebDriverAttributes.h"
#import "XCUIElement+FBUtilities.h"
#import "XCUIElement+FBUID.h"
#import "FBElementUtils.h"

static BOOL FBLookupSnapshotResult(BOOL reused, NSUInteger total, NSUInteger reason)
{
  if ([NSProcessInfo.processInfo.environment[@"HANDKITE_TIMINGS"] isEqualToString:@"1"]) {
    NSLog(@"lookup_snapshot total=%lu reused=%lu reason=%lu",
      (unsigned long)total, (unsigned long)(reused ? total : 0),
      (unsigned long)reason);
  }
  return reused;
}

BOOL FBCacheSnapshotsFromLookup(NSArray<XCUIElement *> *elements,
                                XCUIElement *scope,
                                id<FBXCElementSnapshot> root)
{
  if (nil == root || elements.count == 0) {
    return FBLookupSnapshotResult(NO, elements.count, 1);
  }
  NSMutableArray *snapshots = [NSMutableArray arrayWithObject:root];
  [snapshots addObjectsFromArray:[(id)root _allDescendants] ?: @[]];
  NSMutableDictionary *byUid = [NSMutableDictionary dictionary];
  NSMutableSet *ambiguous = [NSMutableSet set];
  for (id<FBXCElementSnapshot> snapshot in snapshots) {
    NSString *uid = [FBXCElementSnapshotWrapper wdUIDWithSnapshot:snapshot];
    if (nil == uid || [ambiguous containsObject:uid]) {
      continue;
    }
    if (nil != byUid[uid]) {
      [byUid removeObjectForKey:uid];
      [ambiguous addObject:uid];
    } else {
      byUid[uid] = snapshot;
    }
  }
  NSMutableArray *bindings = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  for (XCUIElement *element in elements) {
    id ax = element == scope ? root.accessibilityElement
      : element.fb_boundAccessibilityElement;
    NSString *uid = nil == ax ? nil : [FBElementUtils uidWithAccessibilityElement:ax];
    if (nil == uid) {
      return FBLookupSnapshotResult(NO, elements.count, 2);
    }
    id snapshot = byUid[uid];
    if (nil == snapshot) {
      return FBLookupSnapshotResult(NO, elements.count,
        [ambiguous containsObject:uid] ? 4 : 3);
    }
    if ([seen containsObject:uid]) {
      return FBLookupSnapshotResult(NO, elements.count, 5);
    }
    [seen addObject:uid];
    [bindings addObject:snapshot];
  }
  @try {
    [elements enumerateObjectsUsingBlock:^(XCUIElement *element, NSUInteger index, BOOL *stop) {
      [element fb_cacheSnapshot:bindings[index]];
    }];
  } @catch (NSException *exception) {
    for (XCUIElement *element in elements) {
      element.lastSnapshot = nil;
    }
    @throw exception;
  }
  return FBLookupSnapshotResult(YES, elements.count, 0);
}

@implementation XCUIElement (FBCaching)

static char XCUIELEMENT_CACHE_ID_KEY;

@dynamic fb_cacheId;

- (NSString *)fb_cacheId
{
  id result = objc_getAssociatedObject(self, &XCUIELEMENT_CACHE_ID_KEY);
  if ([result isKindOfClass:NSString.class]) {
    return (NSString *)result;
  }

  NSString *uid = self.fb_uid;
  objc_setAssociatedObject(self, &XCUIELEMENT_CACHE_ID_KEY, uid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return uid;
}

- (void)fb_cacheSnapshot:(id<FBXCElementSnapshot>)snapshot
{
  NSString *uid = [FBXCElementSnapshotWrapper wdUIDWithSnapshot:snapshot];
  if (nil != uid) {
    objc_setAssociatedObject(self, &XCUIELEMENT_CACHE_ID_KEY, uid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.lastSnapshot = snapshot;
  }
}

@end
