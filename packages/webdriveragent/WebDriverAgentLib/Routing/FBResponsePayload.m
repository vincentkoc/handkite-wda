/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBResponsePayload.h"

#import "FBElementCache.h"
#import "FBResponseJSONPayload.h"
#import "FBSession.h"
#import "FBMathUtils.h"
#import "FBConfiguration.h"
#import "FBMacros.h"
#import "FBProtocolHelpers.h"
#import "XCUIElementQuery.h"
#import "XCUIElement+FBCaching.h"
#import "XCUIElement+FBResolve.h"
#import "XCUIElement+FBUID.h"
#import "XCUIElement+FBUtilities.h"
#import "XCUIElement+FBWebDriverAttributes.h"
#import "XCUIElement+FBIsVisible.h"
#import "FBXCAXClientProxy.h"
#import "XCTestPrivateSymbols.h"

NSString *arbitraryAttrPrefix = @"attribute/";

id<FBResponsePayload> FBResponseWithOK(void)
{
  return FBResponseWithStatus(FBCommandStatus.ok);
}

id<FBResponsePayload> FBResponseWithObject(id object)
{
  return FBResponseWithStatus([FBCommandStatus okWithValue:object]);
}

XCUIElement *maybeStable(XCUIElement *element)
{
  BOOL useNativeCachingStrategy = nil == FBSession.activeSession
    ? YES
    : FBSession.activeSession.useNativeCachingStrategy;
  if (useNativeCachingStrategy) {
    return element;
  }

  XCUIElement *result = element;
  id<FBXCElementSnapshot> snapshot = element.lastSnapshot
    ?: element.fb_cachedSnapshot
    ?: [element fb_standardSnapshot];
  NSString *uid = [FBXCElementSnapshotWrapper wdUIDWithSnapshot:snapshot];
  if (nil != uid) {
    result = [element fb_stableInstanceWithUid:uid];
  }
  return result;
}

id<FBResponsePayload> FBResponseWithCachedElement(XCUIElement *element, FBElementCache *elementCache, BOOL compact)
{
  [elementCache storeElement:maybeStable(element)];
  NSDictionary *response = FBDictionaryResponseWithElement(element, compact);
  element.lastSnapshot = nil;
  return FBResponseWithStatus([FBCommandStatus okWithValue:response]);
}

// Resolves snapshots of all the given elements with a single app snapshot instead of one per element
static id<FBXCElementSnapshot> FBAttachSnapshots(NSArray<XCUIElement *> *elements)
{
  NSMutableDictionary<NSString *, NSMutableArray<XCUIElement *> *> *pending = [NSMutableDictionary dictionary];
  for (XCUIElement *element in elements) {
    if (nil != element.lastSnapshot || nil == element.fb_boundAccessibilityElement) {
      continue;
    }
    NSString *uid = element.fb_cacheId;
    if (nil != uid) {
      NSMutableArray<XCUIElement *> *group = pending[uid];
      if (nil == group) {
        group = [NSMutableArray array];
        pending[uid] = group;
      }
      [group addObject:element];
    }
  }
  if (0 == pending.count) {
    return nil;
  }
  @autoreleasepool {
    XCUIApplication *application = elements.firstObject.application;
    id<FBXCElementSnapshot> root = [application fb_standardSnapshot];
    // The app is long-lived, so don't let it keep the whole tree after this call
    application.lastSnapshot = nil;
    NSMutableArray *snapshots = [NSMutableArray arrayWithObject:root];
    [snapshots addObjectsFromArray:[(id)root _allDescendants]];
    for (id<FBXCElementSnapshot> snapshot in snapshots) {
      NSString *uid = [FBXCElementSnapshotWrapper wdUIDWithSnapshot:snapshot];
      for (XCUIElement *element in (nil == uid ? nil : pending[uid])) {
        element.lastSnapshot = snapshot;
      }
    }
    return root;
  }
}

static NSArray<id<FBXCElementSnapshot>> *FBVisibilitySnapshot(
  id<FBXCElementSnapshot> root)
{
  @try {
    NSError *error = nil;
    NSArray *attributes = [FBStandardAttributeNames()
      arrayByAddingObject:FB_XCAXAIsVisibleAttributeName];
    id<FBXCElementSnapshot> snapshot = [FBXCAXClientProxy.sharedClient
      snapshotForElement:root.accessibilityElement attributes:attributes
      inDepth:YES error:&error];
    if (nil == snapshot || nil != error) {
      return @[];
    }
    NSMutableArray *result = [NSMutableArray arrayWithObject:snapshot];
    [result addObjectsFromArray:[(id)snapshot _allDescendants] ?: @[]];
    return result.count <= 8192 ? result : @[];
  } @catch (NSException *exception) {
    // A failed optional read uses the existing per-element getter; never retry.
    return @[];
  }
}

id<FBResponsePayload> FBResponseWithCachedElements(NSArray<XCUIElement *> *elements,
                                                 FBElementCache *elementCache,
                                                 BOOL compact)
{
  NSMutableArray *elementsResponse = [NSMutableArray array];
  @try {
    id<FBXCElementSnapshot> root = compact ? nil : FBAttachSnapshots(elements);
    void (^serialize)(void) = ^{
      for (XCUIElement *element in elements) {
        [elementCache storeElement:maybeStable(element)];
        [elementsResponse addObject:FBDictionaryResponseWithElement(element, compact)];
        element.lastSnapshot = nil;
      }
    };
    NSArray *fields = [FBConfiguration.sharedInstance.elementResponseAttributes
      componentsSeparatedByString:@","];
    if (!compact && elements.count > 1 && nil != root
        && [fields containsObject:@"displayed"]) {
      NSMutableArray *snapshots = [NSMutableArray array];
      for (XCUIElement *element in elements) {
        if (nil != element.lastSnapshot) {
          [snapshots addObject:element.lastSnapshot];
        }
      }
      FBWithPrefetchedVisibility(snapshots, FBVisibilitySnapshot(root), serialize);
    } else {
      serialize();
    }
  } @finally {
    // Both ordinary and prefetched snapshots are request-scoped, including errors.
    for (XCUIElement *element in elements) {
      element.lastSnapshot = nil;
    }
  }
  return FBResponseWithStatus([FBCommandStatus okWithValue:elementsResponse]);
}

id<FBResponsePayload> FBResponseWithUnknownError(NSError *error)
{
  return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:error.description traceback:nil]);
}

id<FBResponsePayload> FBResponseWithUnknownErrorFormat(NSString *format, ...)
{
  va_list argList;
  va_start(argList, format);
  NSString *errorMessage = [[NSString alloc] initWithFormat:format arguments:argList];
  id<FBResponsePayload> payload = FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:errorMessage
                                                                                      traceback:nil]);
  va_end(argList);
  return payload;
}

id<FBResponsePayload> FBResponseWithStatus(FBCommandStatus *status)
{
  NSMutableDictionary* response = [NSMutableDictionary dictionary];
  response[@"sessionId"] = [FBSession activeSession].identifier ?: NSNull.null;
  if (nil == status.error) {
    response[@"value"] = status.value ?: NSNull.null;
  } else {
    response[@"value"] = @{
      @"error": (id)status.error,
      @"message": status.message ?: @"",
      @"traceback": status.traceback ?: @""
    };
  }
  return [[FBResponseJSONPayload alloc] initWithDictionary:response.copy
                                            httpStatusCode:status.statusCode];
}

inline NSDictionary *FBDictionaryResponseWithElement(XCUIElement *element, BOOL compact)
{
  __block NSDictionary *elementResponse = nil;
  @autoreleasepool {
    NSString *boundUid = element.fb_boundAccessibilityElement ? element.fb_cacheId : nil;
    if (compact && nil != boundUid) {
      elementResponse = FBToElementDict(boundUid);
      return elementResponse;
    }
    id<FBXCElementSnapshot> snapshot = element.lastSnapshot
      ?: element.fb_cachedSnapshot
      ?: [element fb_customSnapshot];
    NSDictionary *compactResult = FBToElementDict(boundUid ?: (NSString *)[FBXCElementSnapshotWrapper wdUIDWithSnapshot:snapshot]);
    if (compact) {
      elementResponse = compactResult;
      return elementResponse;
    }

    NSMutableDictionary *result = compactResult.mutableCopy;
    FBXCElementSnapshotWrapper *wrappedSnapshot = [FBXCElementSnapshotWrapper ensureWrapped:snapshot];
    NSArray *fields = [FBConfiguration.sharedInstance.elementResponseAttributes componentsSeparatedByString:@","];
    for (NSString *field in fields) {
      // 'name' here is the w3c-approved identifier for what we mean by 'type'
      if ([field isEqualToString:@"name"] || [field isEqualToString:@"type"]) {
        result[field] = wrappedSnapshot.wdType;
      } else if ([field isEqualToString:@"text"]) {
        result[field] = FBFirstNonEmptyValue(wrappedSnapshot.wdValue, wrappedSnapshot.wdLabel) ?: [NSNull null];
      } else if ([field isEqualToString:@"rect"]) {
        result[field] = wrappedSnapshot.wdRect;
      } else if ([field isEqualToString:@"enabled"]) {
        result[field] = @(wrappedSnapshot.wdEnabled);
      } else if ([field isEqualToString:@"displayed"]) {
        result[field] = @(wrappedSnapshot.wdVisible);
      } else if ([field isEqualToString:@"selected"]) {
        result[field] = @(wrappedSnapshot.wdSelected);
      } else if ([field isEqualToString:@"label"]) {
        result[field] = wrappedSnapshot.wdLabel ?: [NSNull null];
      } else if ([field hasPrefix:arbitraryAttrPrefix]) {
        NSString *attributeName = [field substringFromIndex:[arbitraryAttrPrefix length]];
        result[field] = [wrappedSnapshot fb_valueForWDAttributeName:attributeName] ?: [NSNull null];
      }
    }
    elementResponse = result.copy;
  }
  return elementResponse;
}
