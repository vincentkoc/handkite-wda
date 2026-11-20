/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import "FBCustomCommands.h"
#import "FBElementCache.h"
#import "FBRouteRequest-Private.h"
#import "FBSession.h"
#import "FBResponsePayload.h"
#import "RouteResponse.h"
#import "XCUIDevice+FBHinge.h"
#import "Doubles/XCUIElementDouble.h"

#if !TARGET_OS_TV && __clang_major__ >= 15

@interface FBCustomCommands (FBWDATestable)
+ (id<FBResponsePayload>)foregroundStateForApplication:(id)application
                                              locked:(NSNumber *)locked;
+ (id<FBResponsePayload>)handleGetDeviceInfo:(FBRouteRequest *)request;
+ (id<FBResponsePayload>)handleKeyboardInput:(FBRouteRequest *)request;
+ (id<FBResponsePayload>)handleGetSimulatedHingeAngle:(FBRouteRequest *)request;
+ (id<FBResponsePayload>)handleSetSimulatedHingeAngle:(FBRouteRequest *)request;
@end

@interface FBForegroundApplicationDouble : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic) int processID;
@end

@implementation FBForegroundApplicationDouble
- (NSString *)identifier
{
  [NSException raise:NSInternalInconsistencyException
              format:@"Foreground state must not resolve the app identifier"];
  return nil;
}
@end

@interface FBCustomCommandsTests : XCTestCase
@property (nonatomic, strong) FBSession *session;
@end

@implementation FBCustomCommandsTests

- (NSDictionary *)foregroundResponseForApp:(id)app locked:(NSNumber *)locked
{
  RouteResponse *response = [RouteResponse new];
  [[FBCustomCommands foregroundStateForApplication:app locked:locked]
    dispatchWithResponse:response];
  return [NSJSONSerialization JSONObjectWithData:response.responseData
                                        options:0 error:nil];
}

- (void)testForegroundStateUsesOnlyProcessIdentityAndNativeLock
{
  FBForegroundApplicationDouble *app = [FBForegroundApplicationDouble new];
  app.bundleID = @"example.app";
  app.processID = 42;
  for (NSNumber *locked in @[@NO, @YES]) {
    NSDictionary *body = [self foregroundResponseForApp:app locked:locked];
    XCTAssertEqualObjects(body[@"value"], (@{
      @"bundleId": @"example.app", @"pid": @42, @"locked": locked,
    }));
  }
}

- (void)testForegroundStateRefusesUnknownLock
{
  FBForegroundApplicationDouble *app = [FBForegroundApplicationDouble new];
  app.bundleID = @"example.app";
  app.processID = 42;
  XCTAssertEqualObjects(
    [self foregroundResponseForApp:app locked:nil][@"value"][@"error"],
    @"unknown error");
  for (id invalid in @[@0, @1, @"false", NSNull.null]) {
    XCTAssertEqualObjects(
      [self foregroundResponseForApp:app locked:invalid][@"value"][@"error"],
      @"unknown error");
  }
}

- (void)testForegroundStateRefusesMissingProcessIdentity
{
  FBForegroundApplicationDouble *app = [FBForegroundApplicationDouble new];
  app.bundleID = @"example.app";
  XCTAssertEqualObjects(
    [self foregroundResponseForApp:app locked:@NO][@"value"][@"error"],
    @"unknown error");
  app.processID = 42;
  app.bundleID = @"";
  XCTAssertEqualObjects(
    [self foregroundResponseForApp:app locked:@NO][@"value"][@"error"],
    @"unknown error");
}

- (void)setUp
{
  [super setUp];
  self.session = [FBSession initWithApplication:nil];
}

- (void)tearDown
{
  [self.session kill];
  [super tearDown];
}

- (FBRouteRequest *)requestWithElement:(XCUIElementDouble *)element keys:(NSArray *)keys
{
  // uuid "0" is reserved by handleKeyboardInput: to mean "no element" (use the active application).
  element.wdUID = @"1";
  NSString *uuid = [self.session.elementCache storeElement:(XCUIElement *)element];
  FBRouteRequest *request = [FBRouteRequest routeRequestWithURL:[NSURL URLWithString:@"http://localhost:8100/"]
                                                       parameters:@{@"uuid": uuid}
                                                        arguments:@{@"keys": keys}];
  request.session = self.session;
  return request;
}

- (void)testDictionaryKeyWithConstantNameIsResolved
{
  XCUIElementDouble *element = XCUIElementDouble.new;
  FBRouteRequest *request = [self requestWithElement:element
                                                 keys:@[@{@"key": @"XCUIKeyboardKeyTab"}]];
  [FBCustomCommands handleKeyboardInput:request];
  XCTAssertEqualObjects(element.typedKeys, @[XCUIKeyboardKeyTab]);
}

- (void)testDictionaryKeyWithLiteralCharacterIsPassedThrough
{
  XCUIElementDouble *element = XCUIElementDouble.new;
  FBRouteRequest *request = [self requestWithElement:element
                                                 keys:@[@{@"key": @"a"}]];
  [FBCustomCommands handleKeyboardInput:request];
  XCTAssertEqualObjects(element.typedKeys, @[@"a"]);
}

- (void)testDictionaryKeyWithConstantNameAndModifierFlagsIsResolved
{
  XCUIElementDouble *element = XCUIElementDouble.new;
  FBRouteRequest *request = [self requestWithElement:element
                                                 keys:@[@{@"key": @"XCUIKeyboardKeyTab", @"modifierFlags": @2}]];
  [FBCustomCommands handleKeyboardInput:request];
  XCTAssertEqualObjects(element.typedKeys, @[XCUIKeyboardKeyTab]);
  XCTAssertEqual(element.lastTypedModifierFlags, 2);
}

- (NSDictionary *)hingeResponseWithArguments:(NSDictionary *)arguments
{
  FBRouteRequest *request = [FBRouteRequest routeRequestWithURL:[NSURL URLWithString:@"http://localhost:8100/"]
                                                  parameters:@{}
                                                   arguments:arguments];
  RouteResponse *response = [RouteResponse new];
  [[FBCustomCommands handleSetSimulatedHingeAngle:request] dispatchWithResponse:response];
  return [NSJSONSerialization JSONObjectWithData:response.responseData options:0 error:nil];
}

- (void)testDeviceInfoIncludesHasHinge
{
  FBRouteRequest *request = [FBRouteRequest routeRequestWithURL:[NSURL URLWithString:@"http://localhost:8100/wda/device/info"]
                                                  parameters:@{}
                                                   arguments:@{}];
  RouteResponse *response = [RouteResponse new];
  [[FBCustomCommands handleGetDeviceInfo:request] dispatchWithResponse:response];
  NSDictionary *body = [NSJSONSerialization JSONObjectWithData:response.responseData options:0 error:nil];
  id hasHinge = body[@"value"][@"hasHinge"];
  XCTAssertNotNil(hasHinge);
  if (nil == hasHinge) {
    return;
  }
  XCTAssertEqual(CFGetTypeID((__bridge CFTypeRef)hasHinge), CFBooleanGetTypeID());
  XCTAssertEqual([hasHinge boolValue], XCUIDevice.sharedDevice.fb_supportsHingeAngleReading);
  NSLog(@"Device info hasHinge: %@", [hasHinge boolValue] ? @"true" : @"false");
}

- (void)testHingeAngleReading
{
  NSError *error = nil;
  NSNumber *angle = [XCUIDevice.sharedDevice fb_getSimulatedHingeAngle:&error];
  BOOL available = XCUIDevice.sharedDevice.fb_supportsHingeAngleReading;
  if (available) {
    XCTAssertNotNil(angle);
    XCTAssertNil(error);
    XCTAssertTrue(isfinite(angle.doubleValue));
  } else {
    XCTAssertNil(angle);
    XCTAssertNotNil(error);
  }

  FBRouteRequest *request = [FBRouteRequest routeRequestWithURL:[NSURL URLWithString:@"http://localhost:8100/"]
                                                  parameters:@{}
                                                   arguments:@{}];
  RouteResponse *response = [RouteResponse new];
  [[FBCustomCommands handleGetSimulatedHingeAngle:request] dispatchWithResponse:response];
  NSDictionary *body = [NSJSONSerialization JSONObjectWithData:response.responseData options:0 error:nil];
  if (available) {
    XCTAssertTrue([body[@"value"] isKindOfClass:NSNumber.class]);
    XCTAssertTrue(isfinite([body[@"value"] doubleValue]));
  } else {
    XCTAssertEqualObjects(body[@"value"][@"error"], @"unsupported operation");
  }
}

- (void)testHingeAngleRejectsInvalidArguments
{
  for (id value in @[@(-1), @181, @YES, @"90", NSNull.null, @(NAN), @(INFINITY)]) {
    NSDictionary *response = [self hingeResponseWithArguments:@{@"angle": value}];
    XCTAssertEqualObjects(response[@"value"][@"error"], @"invalid argument");
  }
  XCTAssertEqualObjects([self hingeResponseWithArguments:@{}][@"value"][@"error"], @"invalid argument");
}

- (void)testHingeAngleReadbackMatchesRequestedAngle
{
#if TARGET_OS_SIMULATOR
  XCUIDevice *device = XCUIDevice.sharedDevice;
  XCTSkipUnless(device.fb_supportsHingeAngleReading && device.fb_canAttemptSimulatedHingeAngleInjection,
                @"Requires a device with a hinge that supports reading and injection");
  NSNumber *originalAngle = [device fb_getSimulatedHingeAngle:nil];
  XCTAssertNotNil(originalAngle, @"Cannot read the original hinge angle");
  if (nil == originalAngle) {
    return;
  }
  [self addTeardownBlock:^{
    [device fb_setSimulatedHingeAngle:originalAngle.doubleValue error:nil];
  }];
  // Intermediate angles are the ones iOS 27.2 initially stops short of
  for (NSNumber *angle in @[@0, @45, @90, @150, @120, @10, @180]) {
    NSError *error = nil;
    XCTAssertTrue([device fb_setSimulatedHingeAngle:angle.doubleValue error:&error], @"%@", error);
    NSNumber *reading = [device fb_getSimulatedHingeAngle:&error];
    XCTAssertNotNil(reading, @"%@", error);
    XCTAssertEqualWithAccuracy(reading.doubleValue, angle.doubleValue, 0.1, @"Requested %@", angle);
  }
#else
  XCTSkip(@"Hinge injection is only verified on simulators");
#endif
}

- (void)testHingeAngleRejectsUnsupportedDevices
{
  XCTSkipIf(XCUIDevice.sharedDevice.fb_canAttemptSimulatedHingeAngleInjection, @"Requires a device without an available hinge");
  for (NSNumber *angle in @[@0, @90, @180]) {
    XCTAssertEqualObjects([self hingeResponseWithArguments:@{@"angle": angle}][@"value"][@"error"],
                          @"unsupported operation");
  }
}

@end

#endif
