// SPDX-License-Identifier: GPL-3.0-only
// Runs only fake backends/guards. No UIKit or private simulation calls.
#import "ILLDiagnosticSession.h"
#include <math.h>
#include <stdio.h>

static void Check(BOOL ok, NSString *message) {
    if (!ok) { fprintf(stderr, "DIAGNOSTIC_TEST_FAILED: %s\n", message.UTF8String); exit(1); }
}
static void Until(BOOL (^condition)(void), NSString *message) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    BOOL satisfied = condition();
    while (!satisfied && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
        satisfied = condition();
    }
    Check(satisfied, message);
}
static NSUInteger Count(NSArray *array, NSString *value) {
    NSUInteger count = 0; for (id item in array) if ([item isEqual:value]) count++; return count;
}
static NSURL *TempDirectory(void) {
    return [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:[@"ill-diagnostic-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
}
@interface DiagnosticFakeBackend : NSObject <ILLLocationBackend>
@property(nonatomic, strong) NSMutableArray *calls;
@property(nonatomic) BOOL blockNextPrepare, blockNextStop;
@property(nonatomic, copy) NSString *throwStep;
@property(nonatomic, strong) dispatch_semaphore_t entered, resume;
@end
@implementation DiagnosticFakeBackend
- (instancetype)init {
    if ((self = [super init])) {
        _calls = [NSMutableArray array]; _entered = dispatch_semaphore_create(0);
        _resume = dispatch_semaphore_create(0);
    }
    return self;
}
- (BOOL)validateForStart:(BOOL)starting error:(NSError **)error {
    (void)starting; (void)error; return YES;
}
- (void)performStep:(NSString *)step location:(CLLocation *)location {
    (void)location; Check(!NSThread.isMainThread, @"Backend never runs on UI thread");
    [self.calls addObject:step];
    BOOL block = ([step isEqual:@"prepare"] && self.blockNextPrepare)
        || ([step isEqual:@"stop"] && self.blockNextStop);
    if (block) {
        self.blockNextPrepare = NO; self.blockNextStop = NO;
        dispatch_semaphore_signal(self.entered);
        Check(dispatch_semaphore_wait(self.resume, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
              @"Blocked fake step released");
    }
    if ([step isEqual:self.throwStep]) [NSException raise:@"InjectedCleanupFailure" format:@"Fake only"];
}
@end
@interface DiagnosticFakeGuard : NSObject <ILLExecutionGuard>
@property(atomic) BOOL allowed, active, continuous;
@property(atomic) BOOL expireOnNextBegin;
@property(atomic) BOOL blockNextBegin;
@property(nonatomic, strong) dispatch_semaphore_t beginEntered, beginResume;
@property(atomic) NSUInteger begins, ends;
@property(atomic, copy) dispatch_block_t expiration;
@end
@implementation DiagnosticFakeGuard
- (instancetype)init {
    if ((self = [super init])) {
        _allowed = YES; _beginEntered = dispatch_semaphore_create(0);
        _beginResume = dispatch_semaphore_create(0);
    }
    return self;
}
- (BOOL)beginWithExpiration:(dispatch_block_t)expiration continuous:(BOOL)continuous {
    self.continuous = continuous;
    @synchronized (self) {
        if (!self.allowed) return NO;
        if (!self.active) {
            self.active = YES; self.begins++; self.expiration = expiration;
            if (self.blockNextBegin) {
                self.blockNextBegin = NO; dispatch_semaphore_signal(self.beginEntered);
                Check(dispatch_semaphore_wait(self.beginResume, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
                      @"Blocked guard begin released");
            }
            if (self.expireOnNextBegin) {
                self.expireOnNextBegin = NO;
                dispatch_semaphore_t finished = dispatch_semaphore_create(0);
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                    expiration(); dispatch_semaphore_signal(finished);
                });
                Check(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0,
                      @"Expiration exercised before begin returns");
            }
        }
        return YES;
    }
}
- (void)end {
    @synchronized (self) {
        if (self.active) { self.active = NO; self.ends++; self.expiration = nil; }
    }
}
@end
@interface Fixture : NSObject
@property(nonatomic, strong) DiagnosticFakeBackend *backend;
@property(nonatomic, strong) DiagnosticFakeGuard *guard;
@property(nonatomic, strong) ILLDiagnosticSession *session;
@property(nonatomic, strong) NSDictionary *last;
@property(nonatomic, strong) NSURL *directory;
- (instancetype)initWithDirectory:(NSURL *)directory;
- (void)waitPhase:(NSString *)phase;
@end
@implementation Fixture
- (instancetype)init { return [self initWithDirectory:TempDirectory()]; }
- (instancetype)initWithDirectory:(NSURL *)directory {
    if ((self = [super init])) {
        self.directory = directory; self.backend = [DiagnosticFakeBackend new];
        self.guard = [DiagnosticFakeGuard new];
        self.session = [[ILLDiagnosticSession alloc]
            initWithEngine:[[ILLFixedLocationEngine alloc] initWithBackend:self.backend]
            guard:self.guard directory:directory];
        __weak Fixture *weakSelf = self;
        self.session.onChange = ^(NSDictionary *snapshot) {
            Check(NSThread.isMainThread, @"UI snapshots delivered on main"); weakSelf.last = snapshot;
        };
        [self.session refresh];
        Until(^BOOL { return weakSelf.last != nil; }, @"Initial snapshot delivered");
    }
    return self;
}
- (void)waitPhase:(NSString *)phase {
    Until(^BOOL { return [self.last[@"phase"] isEqual:phase]; }, [@"Expected phase " stringByAppendingString:phase]);
}
@end

int main(void) {
    @autoreleasepool {
        NSMutableArray *passed = [NSMutableArray array]; double number;
        Check(ILLParseCoordinateText(@" 35,68126 ", &number) && fabs(number - 35.68126) < 1e-9,
              @"Comma decimal supported");
        Check(ILLParseCoordinateText(@"-180.0", &number) && number == -180, @"Negative longitude supported");
        for (NSString *bad in @[@"", @"nan", @"inf", @"1,234.5", @"1,2,3", @"1x"])
            Check(!ILLParseCoordinateText(bad, &number), @"Reject malformed/nonfinite input");
        [passed addObject:@"coordinate_text_comma_negative_and_invalid"];

        Fixture *f = [Fixture new];
        [f.session activateLatitude:35 longitude:139 duration:0.5];
        [f waitPhase:@"activation_requested_unverified"];
        Check([f.last[@"needs_cleanup"] boolValue], @"Cleanup marker set before activation");
        [f waitPhase:@"deactivation_requested_unverified"];
        Check(![f.last[@"needs_cleanup"] boolValue] && f.guard.ends == 1, @"Lease expiry ends execution guard");
        Check(f.last[@"restoration_confirmed"] == NSNull.null, @"Backend does not certify restoration");
        [passed addObject:@"lease_expiry_unverified_state_and_guard_balance"];

        f = [Fixture new];
        [f.session activateLatitude:35 longitude:139 duration:10]; [f waitPhase:@"activation_requested_unverified"];
        NSUInteger revision = [f.last[@"revision"] unsignedIntegerValue];
        [f.session activateLatitude:0 longitude:0 duration:10];
        [f.session activateLatitude:NAN longitude:0 duration:10];
        Until(^BOOL { return [f.last[@"revision"] unsignedIntegerValue] >= revision + 2; }, @"Busy and invalid input handled");
        Check(Count(f.backend.calls, @"start") == 1, @"Double tap and invalid input do not restart or supersede session");
        Check([f.last[@"phase"] isEqual:@"activation_requested_unverified"], @"Input issue preserves current phase");
        [f.session stopWithReason:@"test" completion:nil]; [f waitPhase:@"deactivation_requested_unverified"];
        [passed addObject:@"busy_and_invalid_input_preserve_current_session"];

        f = [Fixture new]; f.backend.blockNextPrepare = YES;
        [f.session activateLatitude:35 longitude:139 duration:10];
        Until(^BOOL { return dispatch_semaphore_wait(f.backend.entered, DISPATCH_TIME_NOW) == 0; }, @"Start entered fake prepare");
        [f.session stopWithReason:@"cancel_inflight" completion:nil]; [f waitPhase:@"stop_pending"];
        revision = [f.last[@"revision"] unsignedIntegerValue]; [f.session refresh];
        Until(^BOOL { return [f.last[@"revision"] unsignedIntegerValue] > revision; }, @"Stop invalidation enqueued before releasing start");
        dispatch_semaphore_signal(f.backend.resume); [f waitPhase:@"deactivation_requested_unverified"];
        Check(![f.backend.calls containsObject:@"start"] && ![f.backend.calls containsObject:@"append"], @"No late activation after pending stop");
        [passed addObject:@"stop_cancels_inflight_start_without_late_ui_reactivation"];

        f = [Fixture new]; f.guard.blockNextBegin = YES;
        [f.session activateLatitude:35 longitude:139 duration:10];
        Until(^BOOL { return dispatch_semaphore_wait(f.guard.beginEntered, DISPATCH_TIME_NOW) == 0; }, @"Start waiting for guard");
        [f.session stopWithReason:@"stop_before_commit" completion:nil];
        dispatch_semaphore_signal(f.guard.beginResume); [f waitPhase:@"deactivation_requested_unverified"];
        Check(![f.backend.calls containsObject:@"start"] && ![f.backend.calls containsObject:@"append"],
              @"Stop requested while preparation is blocked prevents a late activation");
        [passed addObject:@"stop_before_activation_commit_prevents_late_start"];

        f = [Fixture new];
        [f.session activateLatitude:35 longitude:139 duration:10]; [f waitPhase:@"activation_requested_unverified"];
        f.backend.blockNextStop = YES;
        [f.session stopWithReason:@"first_stop" completion:nil];
        Until(^BOOL { return dispatch_semaphore_wait(f.backend.entered, DISPATCH_TIME_NOW) == 0; }, @"Stop entered fake backend");
        [f waitPhase:@"stop_pending"]; revision = [f.last[@"revision"] unsignedIntegerValue];
        [f.session stopWithReason:@"second_stop" completion:nil]; [f.session refresh];
        Until(^BOOL { return [f.last[@"revision"] unsignedIntegerValue] >= revision + 2; }, @"Repeated stop coalesced");
        dispatch_semaphore_signal(f.backend.resume); [f waitPhase:@"deactivation_requested_unverified"];
        Check(Count(f.backend.calls, @"stop") == 2, @"Only pre-start stop and one cleanup, not competing cleanup generations");
        Check(f.guard.begins == 1 && f.guard.ends == 1, @"Execution guard balanced once");
        [passed addObject:@"repeated_stop_coalesces_without_superseding_cleanup"];

        f = [Fixture new]; f.guard.allowed = NO;
        [f.session activateLatitude:35 longitude:139 duration:10];
        Until(^BOOL { return [f.last[@"last_issue"] length] > 0; }, @"Guard refusal reported");
        Check(f.backend.calls.count == 0 && ![f.last[@"needs_cleanup"] boolValue], @"No private calls after guard refusal");
        f.guard.allowed = YES;
        [f.session activateLatitude:35 longitude:139 duration:10]; [f waitPhase:@"activation_requested_unverified"];
        dispatch_block_t expire = [f.guard.expiration copy]; Check(expire != nil, @"Expiration callback retained");
        expire(); [f waitPhase:@"deactivation_requested_unverified"];
        Check(f.guard.ends == 1, @"Expiration requests stop and releases guard");
        revision = [f.last[@"revision"] unsignedIntegerValue]; [f.session applicationBecameActive];
        Until(^BOOL { return [f.last[@"revision"] unsignedIntegerValue] > revision; }, @"Foreground reconciliation finished");
        Check(Count(f.backend.calls, @"start") == 1, @"Foreground does not reactivate");
        [passed addObject:@"guard_refusal_expiration_cleanup_and_no_resume_activation"];

        f = [Fixture new]; f.guard.expireOnNextBegin = YES;
        [f.session activateLatitude:35 longitude:139 duration:10];
        [f waitPhase:@"deactivation_requested_unverified"];
        Check(![f.backend.calls containsObject:@"start"] && ![f.backend.calls containsObject:@"append"],
              @"Expiration before activation commit prevents all new start requests");
        Check([f.backend.calls containsObject:@"stop"], @"Cleanup still attempted after expired execution guard");
        [passed addObject:@"expiration_before_commit_prevents_late_activation"];

        NSURL *recovery = TempDirectory();
        Check([NSFileManager.defaultManager createDirectoryAtURL:recovery withIntermediateDirectories:YES attributes:nil error:nil], @"Create recovery fixture");
        Check([[@"{\"needs_cleanup\":true}" dataUsingEncoding:NSUTF8StringEncoding]
            writeToURL:[recovery URLByAppendingPathComponent:@"cleanup-state.json"] atomically:YES], @"Seed previous pending cleanup");
        f = [[Fixture alloc] initWithDirectory:recovery]; [f waitPhase:@"recovery_required"];
        Check([f.last[@"recovery_detected"] boolValue], @"Interrupted-session notice follows durable marker");
        Check(f.backend.calls.count == 0, @"Loading marker alone does not activate or instantiate backend");
        [f.session applicationBecameActive]; [f waitPhase:@"deactivation_requested_unverified"];
        Check(![f.backend.calls containsObject:@"start"] && [f.backend.calls containsObject:@"stop"], @"Relaunch requests cleanup only");
        Check([f.last[@"recovery_detected"] boolValue]
            && [f.last[@"recovery_stop_report_unix"] doubleValue] > 0,
            @"Successful recovery retains notice and completion time for fresh-reading comparison");
        [f.session activateLatitude:35 longitude:139 duration:0.1]; [f waitPhase:@"activation_requested_unverified"];
        Check(![f.last[@"recovery_detected"] boolValue], @"Next explicit activation clears previous recovery notice");
        [f waitPhase:@"deactivation_requested_unverified"];
        [passed addObject:@"persisted_marker_recovers_by_stop_never_start"];

        f = [Fixture new];
        [f.session activateLatitude:35 longitude:139 duration:10]; [f waitPhase:@"activation_requested_unverified"];
        f.backend.throwStep = @"clear";
        [f.session stopWithReason:@"failing_cleanup" completion:nil]; [f waitPhase:@"cleanup_required"];
        Check([f.last[@"needs_cleanup"] boolValue] && ![f.last[@"can_activate"] boolValue], @"Failed cleanup keeps marker and blocks activation");
        f.backend.throwStep = nil; [f.session applicationBecameActive]; [f waitPhase:@"deactivation_requested_unverified"];
        Check(Count(f.backend.calls, @"start") == 1 && f.guard.ends == 2, @"Foreground retries cleanup without simulation restart");
        [passed addObject:@"failed_cleanup_keeps_marker_until_foreground_retry"];

        NSURL *occupied = TempDirectory();
        Check([[@"occupied" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:occupied atomically:YES], @"Create invalid directory fixture");
        f = [[Fixture alloc] initWithDirectory:occupied];
        revision = [f.last[@"revision"] unsignedIntegerValue]; [f.session activateLatitude:35 longitude:139 duration:10];
        Until(^BOOL { return [f.last[@"revision"] unsignedIntegerValue] > revision; }, @"Storage refusal processed");
        Check(f.backend.calls.count == 0 && ![f.last[@"can_activate"] boolValue], @"No activation without durable cleanup marker");
        [passed addObject:@"storage_failure_prevents_activation"];

        f = [Fixture new];
        [f.session activateContinuouslyAtLatitude:35 longitude:139];
        [f waitPhase:@"activation_requested_unverified"];
        Check(f.guard.continuous, @"Continuous activation uses background location guard");
        Check(![f.last[@"has_deadline"] boolValue] && [f.last[@"wall_deadline"] doubleValue] == 0,
              @"Continuous mode has no deadline");
        Check(f.last[@"selected"][@"duration_seconds"] == NSNull.null, @"Continuous configuration has no duration");
        [f.session applicationEnteredBackground];
        // Regression against accidentally keeping the former 30-second lease.
        NSDate *continuousDeadline = [NSDate dateWithTimeIntervalSinceNow:31];
        while (continuousDeadline.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        [f.session applicationBecameActive]; revision = [f.last[@"revision"] unsignedIntegerValue];
        [f.session refresh];
        Until(^BOOL { return [f.last[@"revision"] unsignedIntegerValue] > revision; }, @"Continuous refresh after 31 seconds");
        Check([f.last[@"active_request"] boolValue] && Count(f.backend.calls, @"start") == 1,
              @"No automatic stop or restart at 30 seconds or foreground return");
        Check(Count(f.backend.calls, @"stop") == 1, @"Only initial reset precedes manual OFF");
        dispatch_block_t oldExpiration = [f.guard.expiration copy];
        [f.session stopWithReason:@"switch_off" completion:nil]; [f waitPhase:@"deactivation_requested_unverified"];
        Check(![f.last[@"active_request"] boolValue] && f.guard.ends == 1, @"OFF ends continuous lease");
        [passed addObject:@"continuous_exceeds_30_seconds_no_deadline_background_and_manual_off"];

        [f.session activateContinuouslyAtLatitude:35 longitude:139]; [f waitPhase:@"activation_requested_unverified"];
        oldExpiration();
        revision = [f.last[@"revision"] unsignedIntegerValue]; [f.session refresh];
        Until(^BOOL { return [f.last[@"revision"] unsignedIntegerValue] > revision; }, @"Old expiration drained");
        Check([f.last[@"active_request"] boolValue], @"Stale guard expiration cannot stop a newer session");
        dispatch_block_t currentExpiration = [f.guard.expiration copy];
        currentExpiration(); [f waitPhase:@"deactivation_requested_unverified"];
        Check(![f.last[@"needs_cleanup"] boolValue], @"Loss of continuous guard still requests cleanup");
        [passed addObject:@"continuous_guard_loss_cleans_up_stale_callback_cannot_stop_new_session"];

        NSData *json = [NSJSONSerialization dataWithJSONObject:@{
            @"schema": @"ios-location-lab.diagnostic-session-tests.v1", @"passed": passed,
            @"count": @(passed.count), @"backend": @"fake_only", @"private_api_invoked": @NO}
            options:NSJSONWritingSortedKeys error:nil];
        fwrite(json.bytes, 1, json.length, stdout); putchar('\n');
        return 0;
    }
}
