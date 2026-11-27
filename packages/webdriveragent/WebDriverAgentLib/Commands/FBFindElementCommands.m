/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBFindElementCommands.h"

#import "FBAlert.h"
#import "FBConfiguration.h"
#import "FBElementCache.h"
#import "FBExceptions.h"
#import "FBMacros.h"
#import "FBRouteRequest.h"
#import "FBSession.h"
#import "XCTestPrivateSymbols.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIElement+FBClassChain.h"
#import "XCUIElement+FBFind.h"
#import "XCUIElement+FBIsVisible.h"
#import "XCUIElement+FBUID.h"
#import "XCUIElement+FBUtilities.h"
#import "XCUIElement+FBWebDriverAttributes.h"
#import "FBScreen.h"
#import "FBXCodeCompatibility.h"
#import "XCUIApplication.h"
#import "FBXCAccessibilityElement.h"
#import "FBXCAXClientProxy.h"
#import "FBScopedMembership.h"
#import "FBXPath.h"
#import "FBXMLGenerationOptions.h"
#import "FBXCElementSnapshotWrapper.h"
#import "NSPredicate+FBFormat.h"
#import "XCUIDevice+FBHelpers.h"
#import "XCUIElement+FBCaching.h"
#import "XCUIElementQuery.h"

// Traversal is complete or refuses: depth/child caps are never reported as
// absence. Membership includes every match, not the caller's previous UIDs.
static NSArray<id<FBXCElementSnapshot>> *FBScopedMembers(
  id<FBXCElementSnapshot> root, NSPredicate *predicate)
{
  FBConfiguration *configuration = FBConfiguration.sharedInstance;
  return FBCollectScopedMembers(root, configuration.snapshotMaxDepth,
    configuration.snapshotMaxChildren, 128,
    ^NSArray *(id node) { return [node children]; },
    ^NSString *(id node) { return [FBXCElementSnapshotWrapper wdUIDWithSnapshot:node]; },
    ^BOOL(id node) { return [predicate evaluateWithObject:node]; });
}

static NSArray<NSString *> *FBScopedUIDs(NSArray<id<FBXCElementSnapshot>> *nodes)
{
  NSMutableArray *result = [NSMutableArray array];
  for (id<FBXCElementSnapshot> node in nodes) {
    [result addObject:[FBXCElementSnapshotWrapper wdUIDWithSnapshot:node]];
  }
  return result;
}

static id<FBResponsePayload> FBNoSuchElementErrorResponseForRequest(FBRouteRequest *request)
{
  return FBResponseWithStatus([FBCommandStatus noSuchElementErrorWithMessage:[NSString stringWithFormat:@"unable to find an element using '%@', value '%@'", request.arguments[@"using"], request.arguments[@"value"]]
                                                                   traceback:[NSString stringWithFormat:@"%@", NSThread.callStackSymbols]]);
}

@implementation FBFindElementCommands

#pragma mark - <FBCommandHandler>

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute POST:@"/wda/scopedSnapshot"] respondWithTarget:self action:@selector(handleScopedSnapshot:)],
    [[FBRoute POST:@"/element"] respondWithTarget:self action:@selector(handleFindElement:)],
    [[FBRoute POST:@"/elements"] respondWithTarget:self action:@selector(handleFindElements:)],
    [[FBRoute POST:@"/element/:uuid/element"] respondWithTarget:self action:@selector(handleFindSubElement:)],
    [[FBRoute POST:@"/element/:uuid/elements"] respondWithTarget:self action:@selector(handleFindSubElements:)],
    [[FBRoute GET:@"/wda/element/:uuid/getVisibleCells"] respondWithTarget:self action:@selector(handleFindVisibleCells:)],
#if TARGET_OS_TV
    [[FBRoute GET:@"/element/active"] respondWithTarget:self action:@selector(handleGetFocusedElement:)],
#else
    [[FBRoute GET:@"/element/active"] respondWithTarget:self action:@selector(handleGetActiveElement:)],
#endif
  ];
}


#pragma mark - Commands

+ (id<FBResponsePayload>)handleScopedSnapshot:(FBRouteRequest *)request
{
  // Normal route queue serializes this with existing WDA input/settings routes.
  // No global response profile is written. All failures remain read-only.
  NSDictionary *arguments = request.arguments;
  NSNumber *budget = arguments[@"budget_ms"];
  id expectedDisplay = arguments[@"display"];
  id requestedRecipient = arguments[@"recipient"];
  BOOL requireFocus = [arguments[@"require_focus"] isEqual:@YES];
  if (![arguments[@"version"] isEqual:@1] || ![arguments[@"limit"] isEqual:@128]
      || ![arguments[@"nonce"] isKindOfClass:NSString.class]
      || [arguments[@"nonce"] length] != 32
      || ![arguments[@"predicate"] isKindOfClass:NSString.class]
      || [arguments[@"predicate"] length] > 65536
      || ![arguments[@"app"] isKindOfClass:NSString.class]
      || ![budget isKindOfClass:NSNumber.class] || budget.doubleValue <= 0 || budget.doubleValue > 5000
      || !(expectedDisplay == NSNull.null || [expectedDisplay isKindOfClass:NSNumber.class])
      || !(requestedRecipient == NSNull.null || [requestedRecipient isKindOfClass:NSString.class])) {
    return FBResponseWithUnknownErrorFormat(@"invalid_scoped_snapshot_request");
  }
  NSTimeInterval until = NSProcessInfo.processInfo.systemUptime + budget.doubleValue / 1000;
  void (^checkTime)(void) = ^{
    if (NSProcessInfo.processInfo.systemUptime >= until) {
      @throw [NSException exceptionWithName:@"ScopedSnapshotDeadline" reason:@"original_deadline" userInfo:nil];
    }
  };
  @try {
    XCUIApplication *app = request.session.activeApplication;
    NSDictionary *applicationContext = FBScopedApplicationContext((id)app);
    NSString *bundle = applicationContext[@"bundle"];
    pid_t pid = [applicationContext[@"pid"] intValue];
    id selection = FBConfiguration.sharedInstance.currentDisplayId ?: NSNull.null;
    NSNumber *display = selection == NSNull.null ? @([FBScreen displayID]) : selection;
    if (pid <= 0 || ![bundle isEqual:arguments[@"app"]] || ![selection isEqual:expectedDisplay]
        || FBConfiguration.sharedInstance.boundElementsByIndex) {
      return FBResponseWithUnknownErrorFormat(@"scoped_snapshot_context_changed");
    }
    checkTime();
    NSPredicate *predicate = [NSPredicate fb_snapshotBlockPredicateWithPredicate:
      [NSPredicate predicateWithFormat:arguments[@"predicate"]]];
    id<FBXCElementSnapshot> root = [app fb_standardSnapshot];
    if (root.accessibilityElement.processIdentifier != pid) {
      return FBResponseWithUnknownErrorFormat(@"scoped_snapshot_pid_changed");
    }
    NSArray<id<FBXCElementSnapshot>> *members = FBScopedMembers(root, predicate);
    NSArray<NSString *> *before = FBScopedUIDs(members);
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableArray *bindings = [NSMutableArray array];
    __block XCUIElement *recipient = nil;
    XCUIElementQuery *query = [app.fb_query descendantsMatchingType:XCUIElementTypeAny];
    if (![query respondsToSelector:@selector(_elementMatchingAccessibilityElementOfSnapshot:)]) {
      return FBResponseWithUnknownErrorFormat(@"scoped_snapshot_binding_unavailable");
    }
    for (id<FBXCElementSnapshot> snapshot in members) {
      checkTime();
      FBXCElementSnapshotWrapper *node = [FBXCElementSnapshotWrapper ensureWrapped:snapshot];
      NSString *uid = node.wdUID;
      if (snapshot != root) {
        XCUIElement *element = [query _elementMatchingAccessibilityElementOfSnapshot:snapshot];
        if (element.fb_boundAccessibilityElement == nil || ![element.fb_uid isEqual:uid]
            || ![element.fb_cacheId isEqual:uid]) {
          return FBResponseWithUnknownErrorFormat(@"scoped_snapshot_binding_changed");
        }
        [bindings addObject:@[element,uid]];
        if ([uid isEqual:requestedRecipient]) { recipient = element; }
      }
      // Fetch only bounded native AX visibility. Unknown never becomes false,
      // and the generic helper's slow-read logger cannot print private labels.
      NSError *visibilityError = nil;
      NSNumber *visible = snapshot.additionalAttributes[FB_XCAXAIsVisibleAttribute];
      if (visible == nil) {
        NSDictionary *values = [FBXCAXClientProxy.sharedClient attributesForElement:snapshot.accessibilityElement
          attributes:@[FB_XCAXAIsVisibleAttributeName] error:&visibilityError];
        visible = values[FB_XCAXAIsVisibleAttributeName];
      }
      if (![visible isKindOfClass:NSNumber.class] || visibilityError != nil) {
        return FBResponseWithUnknownErrorFormat(@"scoped_snapshot_visibility_unknown");
      }
      CGRect rect = node.wdFrame;
      [rows addObject:@{@"ELEMENT":uid,@"element-6066-11e4-a52e-4f735466cecf":uid,
        @"type":node.wdType,@"enabled":@(node.enabled),@"displayed":@(visible.boolValue),
        @"rect":@{@"x":@(rect.origin.x),@"y":@(rect.origin.y),
                  @"width":@(rect.size.width),@"height":@(rect.size.height)},
        @"label":node.wdLabel ?: NSNull.null,@"attribute/name":node.wdName ?: NSNull.null,
        @"attribute/value":node.wdValue ?: NSNull.null,
        @"attribute/placeholderValue":node.wdPlaceholderValue ?: NSNull.null,
        @"attribute/focused":@(node.hasFocus),@"attribute/selected":@(node.selected)}];
    }
    FBXMLGenerationOptions *options = [[FBXMLGenerationOptions new]
      withExcludedAttributes:@[@"accessible",@"index",@"traits",@"hittable",
                               @"customActions",@"nativeFrame",@"visible"]];
    NSString *source = [FBXPath xmlStringWithRootElement:
      (id)[FBXCElementSnapshotWrapper ensureWrapped:root] options:options];
    if (source == nil) { return FBResponseWithUnknownErrorFormat(@"scoped_snapshot_source_unknown"); }
    NSDictionary *terminal = FBFinishScopedCapture(before, ^id{
      checkTime();
      NSError *error = nil;
      return [[XCUIDevice sharedDevice] fb_screenshotWithError:&error];
    }, ^NSDictionary *{
      checkTime();
      NSString *active = nil;
      if ([arguments[@"capture_focus"] isEqual:@YES] || requireFocus) {
        active = app.fb_activeElement.fb_uid;
      }
      id recipientFacts = NSNull.null;
      if (requestedRecipient != NSNull.null) {
        if (recipient == nil || !recipient.hittable
            || (requireFocus && ![active isEqual:requestedRecipient])) { return nil; }
        recipientFacts = @{@"id":requestedRecipient,@"hittable":@YES,
                          @"focused":@([active isEqual:requestedRecipient])};
      }
      XCUIApplication *foreground = request.session.activeApplication;
      NSNumber *locked = [[XCUIDevice sharedDevice] fb_observedScreenLockState];
      id selected = FBConfiguration.sharedInstance.currentDisplayId ?: NSNull.null;
      NSNumber *effectiveDisplay = selected == NSNull.null ? @([FBScreen displayID]) : selected;
      if (!FBScopedApplicationMatches((id)foreground, applicationContext)
          || locked == nil || locked.boolValue || ![selected isEqual:expectedDisplay]
          || ![effectiveDisplay isEqual:display]) { return nil; }
      return @{@"active":active ?: NSNull.null,@"recipient":recipientFacts,@"locked":@NO,
               @"display_selection":selected,@"pid_after":@(pid),@"display_after":effectiveDisplay};
    }, ^NSArray *{
      checkTime();
      XCUIApplication *foreground = request.session.activeApplication;
      if (!FBScopedApplicationMatches((id)foreground, applicationContext)) { return nil; }
      id<FBXCElementSnapshot> last = [foreground fb_standardSnapshot];
      if (last.accessibilityElement.processIdentifier != pid) { return nil; }
      NSArray *ids = FBScopedUIDs(FBScopedMembers(last,predicate));
      checkTime();
      return ids;
    });
    // Cache IDs were primed above using direct AX bindings. No snapshot or live
    // getter follows the final native traversal, including during cache insertion.
    for (NSArray *binding in bindings) {
      if (![[request.session.elementCache storeElement:binding[0]] isEqual:binding[1]]) {
        return FBResponseWithUnknownErrorFormat(@"scoped_snapshot_cache_changed");
      }
    }
    checkTime();
    NSMutableDictionary *response = [terminal[@"context"] mutableCopy];
    [response addEntriesFromDictionary:@{@"version":@1,@"nonce":arguments[@"nonce"],
      @"session":request.session.identifier,@"app":bundle,@"predicate":arguments[@"predicate"],
      @"limit":@128,@"pid_before":@(pid),@"display_before":display,
      @"members_before":before,@"members_after":terminal[@"members"],@"rows":rows,
      @"source":source,@"image_after":[terminal[@"image"] base64EncodedStringWithOptions:0]}];
    return FBResponseWithObject(response);
  } @catch (NSException *exception) {
    if ([exception.name isEqualToString:@"ScopedSnapshotBudget"]) {
      return FBResponseWithObject(@{@"version":@1,@"nonce":arguments[@"nonce"],
        @"session":request.session.identifier,@"app":arguments[@"app"],
        @"predicate":arguments[@"predicate"],@"refusal":@"budget"});
    }
    return FBResponseWithUnknownErrorFormat(@"scoped_snapshot_refused");
  }
}

+ (id<FBResponsePayload>)handleFindElement:(FBRouteRequest *)request
{
  FBSession *session = request.session;
  XCUIElement *element = [self.class elementUsing:request.arguments[@"using"]
                                        withValue:request.arguments[@"value"]
                                            under:session.activeApplication];
  if (!element) {
    return FBNoSuchElementErrorResponseForRequest(request);
  }
  return FBResponseWithCachedElement(element, request.session.elementCache, FBConfiguration.sharedInstance.shouldUseCompactResponses);
}

+ (id<FBResponsePayload>)handleFindElements:(FBRouteRequest *)request
{
  FBSession *session = request.session;
  NSArray *elements = [self.class elementsUsing:request.arguments[@"using"]
                                      withValue:request.arguments[@"value"]
                                          under:session.activeApplication
                    shouldReturnAfterFirstMatch:NO];
  return FBResponseWithCachedElements(elements, request.session.elementCache, FBConfiguration.sharedInstance.shouldUseCompactResponses);
}

+ (id<FBResponsePayload>)handleFindVisibleCells:(FBRouteRequest *)request
{
  FBElementCache *elementCache = request.session.elementCache;
  XCUIElement *element = [elementCache elementForUUID:(NSString *)request.parameters[@"uuid"]];
  id<FBXCElementSnapshot> snapshot = [element fb_customSnapshot];
  NSArray<id<FBXCElementSnapshot>> *visibleCellSnapshots = [snapshot descendantsByFilteringWithBlock:^BOOL(id<FBXCElementSnapshot> shot) {
    return shot.elementType == XCUIElementTypeCell
      && [FBXCElementSnapshotWrapper ensureWrapped:shot].wdVisible;
  }];
  NSArray *cells = [element fb_filterDescendantsWithSnapshots:visibleCellSnapshots
                                                 onlyChildren:NO];
  return FBResponseWithCachedElements(cells, request.session.elementCache, FBConfiguration.sharedInstance.shouldUseCompactResponses);
}

+ (id<FBResponsePayload>)handleFindSubElement:(FBRouteRequest *)request
{
  FBElementCache *elementCache = request.session.elementCache;
  XCUIElement *element = [elementCache elementForUUID:(NSString *)request.parameters[@"uuid"]
                                       checkStaleness:NO];
  XCUIElement *foundElement = [self.class elementUsing:request.arguments[@"using"]
                                             withValue:request.arguments[@"value"]
                                                 under:element];
  if (!foundElement) {
    return FBNoSuchElementErrorResponseForRequest(request);
  }
  return FBResponseWithCachedElement(foundElement, request.session.elementCache, FBConfiguration.sharedInstance.shouldUseCompactResponses);
}

+ (id<FBResponsePayload>)handleFindSubElements:(FBRouteRequest *)request
{
  FBElementCache *elementCache = request.session.elementCache;
  XCUIElement *element = [elementCache elementForUUID:(NSString *)request.parameters[@"uuid"]
                                       checkStaleness:NO];
  NSArray *foundElements = [self.class elementsUsing:request.arguments[@"using"]
                                           withValue:request.arguments[@"value"]
                                               under:element
                         shouldReturnAfterFirstMatch:NO];
  return FBResponseWithCachedElements(foundElements, request.session.elementCache, FBConfiguration.sharedInstance.shouldUseCompactResponses);
}

+ (id<FBResponsePayload>)handleGetActiveElement:(FBRouteRequest *)request
{
  XCUIElement *element = request.session.activeApplication.fb_activeElement;
  if (nil == element) {
    return FBNoSuchElementErrorResponseForRequest(request);
  }
  return FBResponseWithCachedElement(element, request.session.elementCache, FBConfiguration.sharedInstance.shouldUseCompactResponses);
}

#if TARGET_OS_TV
+ (id<FBResponsePayload>)handleGetFocusedElement:(FBRouteRequest *)request
{
  XCUIElement *element = request.session.activeApplication.fb_focusedElement;
  return element == nil
    ? FBNoSuchElementErrorResponseForRequest(request)
    : FBResponseWithCachedElement(element, request.session.elementCache, FBConfiguration.sharedInstance.shouldUseCompactResponses);
}
#endif

#pragma mark - Helpers

+ (XCUIElement *)elementUsing:(NSString *)usingText withValue:(NSString *)value under:(XCUIElement *)element
{
  return [[self elementsUsing:usingText
                    withValue:value
                        under:element
  shouldReturnAfterFirstMatch:YES] firstObject];
}

+ (NSArray *)elementsUsing:(NSString *)usingText
                 withValue:(NSString *)value
                     under:(XCUIElement *)element
shouldReturnAfterFirstMatch:(BOOL)shouldReturnAfterFirstMatch
{
  if ([usingText isEqualToString:@"partial link text"]
      || [usingText isEqualToString:@"link text"]) {
    NSArray *components = [value componentsSeparatedByString:@"="];
    NSString *propertyValue = components.lastObject;
    NSString *propertyName = (components.count < 2 ? @"name" : components.firstObject);
    return [element fb_descendantsMatchingProperty:propertyName
                                             value:propertyValue
                                     partialSearch:[usingText containsString:@"partial"]];
  } else if ([usingText isEqualToString:@"class name"]) {
    return [element fb_descendantsMatchingClassName:value
                        shouldReturnAfterFirstMatch:shouldReturnAfterFirstMatch];
  } else if ([usingText isEqualToString:@"class chain"]) {
    return [element fb_descendantsMatchingClassChain:value
                         shouldReturnAfterFirstMatch:shouldReturnAfterFirstMatch];
  } else if ([usingText isEqualToString:@"xpath"]) {
    return [element fb_descendantsMatchingXPathQuery:value
                         shouldReturnAfterFirstMatch:shouldReturnAfterFirstMatch];
  } else if ([usingText isEqualToString:@"predicate string"]) {
    return [element fb_descendantsMatchingPredicate:[NSPredicate predicateWithFormat:value]
                        shouldReturnAfterFirstMatch:shouldReturnAfterFirstMatch];
  } else if ([usingText isEqualToString:@"name"]
             || [usingText isEqualToString:@"id"]
             || [usingText isEqualToString:@"accessibility id"]) {
    return [element fb_descendantsMatchingIdentifier:value
                         shouldReturnAfterFirstMatch:shouldReturnAfterFirstMatch];
  } else {
    @throw [NSException exceptionWithName:FBElementAttributeUnknownException
                                   reason:[NSString stringWithFormat:@"Invalid locator requested: %@", usingText]
                                 userInfo:nil];
  }
}

@end

