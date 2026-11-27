// Copyright (c) 2026 Vincent Koc. BSD-3-Clause; see LICENSE.
#import <Foundation/Foundation.h>

@protocol FBScopedApplicationIdentity <NSObject>
@property (nonatomic, readonly, copy) NSString *bundleID;
@property (nonatomic, readonly) pid_t processID;
@end

// XCTest's identifier is a display/accessibility name, not bundle authority.
// Share the actual producer read with host-only fixtures; never fall back to it.
static NSDictionary *FBScopedApplicationContext(id<FBScopedApplicationIdentity> app)
{
  NSString *bundle = [app.bundleID copy];
  pid_t pid = app.processID;
  if (bundle.length == 0 || pid <= 0) { return nil; }
  return @{@"bundle":bundle, @"pid":@(pid)};
}

static BOOL FBScopedApplicationMatches(id<FBScopedApplicationIdentity> app,
  NSDictionary *expected)
{
  NSDictionary *current = FBScopedApplicationContext(app);
  return current != nil && expected != nil && [current isEqual:expected];
}

// Foundation-only so the exact production traversal can be tested without
// starting XCTest, a simulator, a service, or a physical device.
static NSArray *FBCollectScopedMembers(id root, NSUInteger maxDepth,
  NSUInteger maxChildren, NSUInteger limit, NSArray *(^childrenOf)(id),
  NSString *(^identityOf)(id), BOOL (^matches)(id))
{
  NSMutableArray *pending = [NSMutableArray arrayWithObject:@[root, @0]];
  NSMutableArray *result = [NSMutableArray array];
  NSHashTable *visited = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsStrongMemory];
  NSMutableSet *matchingUIDs = [NSMutableSet set];
  while (pending.count > 0) {
    NSArray *entry = pending.lastObject;
    [pending removeLastObject];
    id node = entry[0];
    NSUInteger depth = [entry[1] unsignedIntegerValue];
    NSArray *children = childrenOf(node) ?: @[];
    if ([visited containsObject:node]
        || visited.count >= 20000 || depth >= maxDepth
        || (maxChildren > 0 && children.count >= maxChildren)) {
      @throw [NSException exceptionWithName:@"ScopedSnapshotIncomplete"
        reason:@"incomplete_native_membership" userInfo:nil];
    }
    [visited addObject:node];
    if (matches(node)) {
      NSString *uid = identityOf(node);
      if (uid.length == 0 || [matchingUIDs containsObject:uid]) {
        @throw [NSException exceptionWithName:@"ScopedSnapshotIdentity"
          reason:@"ambiguous_native_membership" userInfo:nil];
      }
      [matchingUIDs addObject:uid];
      [result addObject:node];
      if (result.count > limit) {
        @throw [NSException exceptionWithName:@"ScopedSnapshotBudget"
          reason:@"native_membership_budget" userInfo:nil];
      }
    }
    for (id child in children) { [pending addObject:@[child, @(depth + 1)]]; }
  }
  return result;
}

static BOOL FBScopedSameMembership(NSArray<NSString *> *before, NSArray<NSString *> *after)
{
  if (before == nil || after == nil) { return NO; }
  NSSet *first = [NSSet setWithArray:before];
  NSSet *last = [NSSet setWithArray:after];
  return first.count == before.count && last.count == after.count
    && [first isEqual:last];
}

// The exact production terminal ordering is exercised by Foundation fixtures.
static NSDictionary *FBFinishScopedCapture(NSArray<NSString *> *before,
  id (^frame)(void), NSDictionary *(^facts)(void), NSArray<NSString *> *(^members)(void))
{
  id image = frame();
  NSDictionary *context = facts();
  NSArray *after = members();
  if (image == nil || context == nil || !FBScopedSameMembership(before, after)) {
    @throw [NSException exceptionWithName:@"ScopedSnapshotTerminal"
      reason:@"native_terminal_changed" userInfo:nil];
  }
  return @{@"image":image,@"context":context,@"members":after};
}
