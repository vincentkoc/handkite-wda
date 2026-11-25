/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>
#import "FBXCElementSnapshot.h"

NS_ASSUME_NONNULL_BEGIN

/** Seed one rich response only when its newly executed query covers every
 returned AX-bound element with a unique snapshot. Never use a previous query. */
FOUNDATION_EXPORT BOOL FBCacheSnapshotsFromLookup(
  NSArray<XCUIElement *> *elements, XCUIElement *scope,
  id<FBXCElementSnapshot> root);

@interface XCUIElement (FBCaching)

@property (nonatomic, readonly) NSString *fb_cacheId;

/**
 Seeds the cache ID and response snapshot from a freshly executed lookup.
 Only call with the snapshot that was used to bind this element. Response
 serialization clears lastSnapshot; subsequent commands resolve the live element.
 */
- (void)fb_cacheSnapshot:(id<FBXCElementSnapshot>)snapshot;

@end

NS_ASSUME_NONNULL_END
