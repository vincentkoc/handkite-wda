// Copyright (c) 2026 Vincent Koc. BSD-3-Clause; see LICENSE.
#import "../WebDriverAgentLib/Commands/FBScopedMembership.h"

@interface ScopedApplicationFixture : NSObject <FBScopedApplicationIdentity>
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic) pid_t processID;
@end
@implementation ScopedApplicationFixture
- (NSString *)identifier
{
  @throw [NSException exceptionWithName:@"DisplayIdentifierRead"
    reason:@"a display name is not bundle identity" userInfo:nil];
}
@end

static void applicationIdentityChecks(void)
{
  ScopedApplicationFixture *app = [ScopedApplicationFixture new];
  app.bundleID = @"com.example.browser";
  app.processID = 42;
  NSDictionary *context = FBScopedApplicationContext(app);
  NSCAssert([context[@"bundle"] isEqual:app.bundleID], @"read the bundle ID");
  NSCAssert(FBScopedApplicationMatches(app,context), @"same app and PID");
  app.bundleID = @"com.example.replacement";
  NSCAssert(!FBScopedApplicationMatches(app,context), @"same name cannot replace app");
  app.bundleID = @"com.example.browser";
  app.processID = 43;
  NSCAssert(!FBScopedApplicationMatches(app,context), @"same app, changed PID");
  app.processID = 0;
  NSCAssert(FBScopedApplicationContext(app) == nil, @"positive PID required");
  app.processID = 42;
  app.bundleID = @"";
  NSCAssert(FBScopedApplicationContext(app) == nil, @"no display-name fallback");
  app.bundleID = @"com.example.browser";
  for (NSNumber *phase in @[@0,@1,@2]) {
    BOOL refused = NO;
    @try {
      NSDictionary *proof = FBFinishScopedCapture(@[@"member"], ^id{
        return @"frame";
      }, ^NSDictionary *{
        if (phase.intValue == 1) { app.processID = 43; }
        return FBScopedApplicationMatches(app,context) ? @{} : nil;
      }, ^NSArray *{
        if (phase.intValue == 2) { app.bundleID = @"com.example.replacement"; }
        return FBScopedApplicationMatches(app,context) ? @[@"member"] : nil;
      });
      NSCAssert(proof != nil, @"matching terminal identity");
    } @catch (NSException *exception) { refused = YES; }
    NSCAssert(refused == (phase.intValue != 0), @"both terminal reads are guarded");
    app.bundleID = @"com.example.browser";
    app.processID = 42;
  }
}

static NSArray *collect(NSDictionary *root, NSUInteger depth, NSUInteger children, NSUInteger limit)
{
  return FBCollectScopedMembers(root, depth, children, limit,
    ^NSArray *(id node) { return node[@"children"]; },
    ^NSString *(id node) { return node[@"uid"]; },
    ^BOOL(id node) { return [node[@"match"] boolValue]; });
}

static BOOL refuses(NSDictionary *root, NSUInteger depth, NSUInteger children, NSUInteger limit)
{
  @try { collect(root, depth, children, limit); return NO; }
  @catch (NSException *exception) { return YES; }
}

int main(void)
{
  @autoreleasepool {
    applicationIdentityChecks();
    NSDictionary *leaf = @{@"uid":@"leaf",@"match":@YES};
    NSDictionary *root = @{@"uid":@"root",@"children":@[leaf]};
    NSCAssert([collect(root, 50, 1000, 128) isEqual:@[leaf]], @"complete unfiltered match");
    NSCAssert(refuses(@{@"uid":@"root",@"children":@[leaf,leaf]},50,1000,128), @"duplicate identity");
    NSCAssert(refuses(root,1,1000,128), @"depth cap is unknown, never absence");
    NSCAssert(refuses(root,50,1,128), @"child cap is unknown, never absence");
    NSCAssert(refuses(root,50,1000,0), @"bounded rich work before serialization");
    NSCAssert(refuses(@{@"match":@YES},50,1000,128), @"missing native identity");
    NSCAssert(FBScopedSameMembership(@[@"a",@"b"],@[@"b",@"a"]), @"order is irrelevant");
    for (NSArray *after in @[@[],@[@"replacement"],@[@"a",@"new"],@[@"a",@"a"]]) {
      NSCAssert(!FBScopedSameMembership(@[@"a"],after), @"terminal mutation must refuse");
    }
    NSDictionary *unmatched = @{@"children":@[leaf]};
    NSCAssert([collect(unmatched,50,1000,128) isEqual:@[leaf]], @"unmatched structural nodes need no UID");
    NSMutableArray *order = [NSMutableArray array];
    NSDictionary *proof = FBFinishScopedCapture(@[@"a"], ^id{
      [order addObject:@"frame"]; return @"frame";
    }, ^NSDictionary *{
      [order addObject:@"recipient"]; return @{};
    }, ^NSArray *{
      [order addObject:@"terminal"]; return @[@"a"];
    });
    NSCAssert([order isEqual:(@[@"frame",@"recipient",@"terminal"])] && proof != nil,
      @"all live checks precede terminal identity");
    BOOL changedRefused = NO;
    @try {
      __block NSArray *population = @[@"a"];
      FBFinishScopedCapture(population, ^id{ return @"frame"; }, ^NSDictionary *{
        population = @[@"a",@"new-field"]; return @{};
      }, ^NSArray *{ return population; });
    } @catch (NSException *exception) { changedRefused = YES; }
    NSCAssert(changedRefused, @"field added during final recipient read refuses");
    BOOL unknownRefused = NO;
    @try {
      FBFinishScopedCapture(@[], ^id{ return @"frame"; }, ^NSDictionary *{ return @{}; },
        ^NSArray *{ return nil; });
    } @catch (NSException *exception) { unknownRefused = YES; }
    NSCAssert(unknownRefused, @"unknown terminal result is not empty membership");
    puts("scoped membership: 12 traversal and 9 application checks passed");
  }
  return 0;
}
