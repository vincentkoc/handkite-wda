/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <WebDriverAgentLib/FBXCElementSnapshotWrapper.h>

NS_ASSUME_NONNULL_BEGIN

/** Supply one request's native visibility values without changing the getter's
 cached-value or visible-descendant precedence. Always clears them after body. Returns how many prefetched values were used. */
FOUNDATION_EXPORT NSUInteger FBWithPrefetchedVisibility(
  NSArray<id<FBXCElementSnapshot>> *snapshots,
  NSArray<id<FBXCElementSnapshot>> *visibilitySnapshots,
  void (^body)(void));

@interface XCUIElement (FBIsVisible)

/*! Whether or not the element is visible */
@property (atomic, readonly) BOOL fb_isVisible;

@end


@interface FBXCElementSnapshotWrapper (FBIsVisible)

/*! Whether or not the element is visible */
@property (atomic, readonly) BOOL fb_isVisible;

@end

NS_ASSUME_NONNULL_END
