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

BOOL FBCacheSnapshotsFromLookup(NSArray<XCUIElement *> *elements,
                                XCUIElement *scope,
                                id<FBXCElementSnapshot> root)
{
  if (nil == root || elements.count == 0) {
    return NO;
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
    id snapshot = nil == uid ? nil : byUid[uid];
    if (nil == snapshot || [seen containsObject:uid]) {
      return NO;
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
  return YES;
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
