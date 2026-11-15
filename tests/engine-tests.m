// SPDX-License-Identifier: GPL-3.0-only
// Device-side tests use only a fake backend; never CLSimulationManager.
#import "ILLFixedLocationEngine.h"
#include <math.h>
#include <stdio.h>

static void Check(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "TEST_FAILED: %s\n", message); exit(1); }
}
static void Wait(dispatch_semaphore_t sem) {
    Check(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
          "Timed out waiting for fake backend");
}
@interface ILLFakeBackend : NSObject <ILLLocationBackend>
@property(nonatomic, strong) NSMutableArray *calls;
@property(nonatomic, strong) NSMutableArray *coordinates;
@property(nonatomic) BOOL blockFirstPrepare;
@property(nonatomic) BOOL rejectStart;
@property(nonatomic) BOOL badThread;
@property(nonatomic, copy) NSString *throwStep;
@property(nonatomic, strong) dispatch_semaphore_t entered;
@property(nonatomic, strong) dispatch_semaphore_t resume;
@end
@implementation ILLFakeBackend
- (instancetype)init {
    if ((self = [super init])) {
        _calls = [NSMutableArray array]; _coordinates = [NSMutableArray array];
        _entered = dispatch_semaphore_create(0); _resume = dispatch_semaphore_create(0);
    }
    return self;
}
- (BOOL)validateForStart:(BOOL)starting error:(NSError **)error {
    self.badThread |= NSThread.isMainThread;
    if (starting && self.rejectStart) {
        *error = [NSError errorWithDomain:@"Fake" code:1 userInfo:nil];
        return NO;
    }
    return YES;
}
- (void)performStep:(NSString *)step location:(CLLocation *)location {
    self.badThread |= NSThread.isMainThread;
    [self.calls addObject:step];
    if ([step isEqual:@"prepare"] && self.blockFirstPrepare) {
        self.blockFirstPrepare = NO;
        dispatch_semaphore_signal(self.entered);
        Wait(self.resume);
    }
    if ([step isEqual:self.throwStep]) [NSException raise:@"InjectedFailure" format:@"Fake backend failure"];
    if ([step isEqual:@"append"]) [self.coordinates addObject:@[@(location.coordinate.latitude), @(location.coordinate.longitude)]];
}
@end
@interface ILLWrongABI : NSObject
- (void)setLocationRepeatBehavior:(uint64_t)value;
@end
@implementation ILLWrongABI
- (void)setLocationRepeatBehavior:(uint64_t)value { (void)value; }
@end

int main(void) {
    @autoreleasepool {
        NSMutableArray *passed = [NSMutableArray array];
        Check(!ILLMethodMatches(ILLWrongABI.class, @selector(setLocationRepeatBehavior:), @"v", @[@"@", @":", @"C"]),
              "Reject wider integer ABI before any invocation");
        [passed addObject:@"incompatible_integer_abi_rejected"];

        // Happy lifecycle: metadata/coord validation, fixed point and explicit stop.
        ILLFakeBackend *fake = [ILLFakeBackend new];
        ILLFixedLocationEngine *engine = [[ILLFixedLocationEngine alloc] initWithBackend:fake];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSDictionary *startReport, *stopReport;
        [engine startAtLatitude:90 longitude:-180 completion:^(NSDictionary *report) {
            startReport = report; dispatch_semaphore_signal(done);
        }];
        Wait(done);
        [engine stopWithCompletion:^(NSDictionary *report) { stopReport = report; dispatch_semaphore_signal(done); }];
        Wait(done);
        Check([startReport[@"state"] isEqual:@"activation_requested_unverified"], "Start remains externally unverified");
        Check([stopReport[@"state"] isEqual:@"deactivation_requested_unverified"], "Stop does not claim restored location");
        Check(startReport[@"location_observed"] == NSNull.null && stopReport[@"restoration_confirmed"] == NSNull.null,
              "Never conflate requests with observations");
        Check([fake.coordinates isEqual:@[@[@90, @-180]]], "Fixed boundary coordinates delivered unchanged");
        Check(!fake.badThread, "All backend calls run off main thread");
        Check([startReport[@"step_timings"] count] == 9 && [stopReport[@"step_timings"] count] == 4,
              "Lifecycle reports include all attempted backend calls");
        for (NSDictionary *report in @[startReport, stopReport]) {
            double previous = [report[@"worker_started_monotonic_seconds"] doubleValue];
            Check(previous >= [report[@"requested_monotonic_seconds"] doubleValue], "Worker starts after request");
            for (NSDictionary *step in report[@"step_timings"]) {
                Check([step[@"began_monotonic_seconds"] doubleValue] >= previous, "Step begins after preceding work");
                Check([step[@"elapsed_seconds"] doubleValue] >= 0 && [step[@"returned"] boolValue],
                      "Successful lifecycle timings preserve return status");
                previous = [step[@"ended_monotonic_seconds"] doubleValue];
            }
        }
        [passed addObject:@"fixed_point_lifecycle_unverified_states_and_worker_thread"];

        fake = [ILLFakeBackend new]; engine = [[ILLFixedLocationEngine alloc] initWithBackend:fake];
        [engine startAtLatitude:NAN longitude:0 completion:^(NSDictionary *report) {
            Check([report[@"state"] isEqual:@"invalid_coordinates"], "Reject NaN"); dispatch_semaphore_signal(done);
        }];
        Wait(done);
        [engine startAtLatitude:0 longitude:181 completion:^(NSDictionary *report) {
            Check([report[@"state"] isEqual:@"invalid_coordinates"], "Reject out of range coordinate"); dispatch_semaphore_signal(done);
        }];
        Wait(done);
        Check(fake.calls.count == 0, "Invalid coordinate must have no backend effect");
        [passed addObject:@"nan_and_out_of_range_have_no_backend_effect"];

        fake = [ILLFakeBackend new]; fake.rejectStart = YES;
        engine = [[ILLFixedLocationEngine alloc] initWithBackend:fake];
        [engine startAtLatitude:0 longitude:0 completion:^(NSDictionary *report) {
            Check([report[@"state"] isEqual:@"incompatible_api"], "Fail closed on invalid API"); dispatch_semaphore_signal(done);
        }];
        Wait(done);
        Check(fake.calls.count == 0, "No manager creation after validation failure");
        [engine stopWithCompletion:^(NSDictionary *report) {
            Check([report[@"request_sent"] boolValue], "Stop uses independent minimal validation"); dispatch_semaphore_signal(done);
        }];
        Wait(done);
        [passed addObject:@"activation_validation_failure_does_not_disable_stop"];

        fake = [ILLFakeBackend new]; fake.blockFirstPrepare = YES;
        engine = [[ILLFixedLocationEngine alloc] initWithBackend:fake];
        [engine startAtLatitude:1 longitude:2 completion:^(NSDictionary *report) { startReport = report; dispatch_semaphore_signal(done); }];
        Wait(fake.entered);
        [engine startAtLatitude:3 longitude:4 completion:^(NSDictionary *report) {
            Check([report[@"state"] isEqual:@"superseded"], "Queued start canceled by stop"); dispatch_semaphore_signal(done);
        }];
        [engine stopWithCompletion:^(NSDictionary *report) { stopReport = report; dispatch_semaphore_signal(done); }];
        dispatch_semaphore_signal(fake.resume);
        Wait(done); Wait(done); Wait(done);
        Check([startReport[@"state"] isEqual:@"superseded"], "In-flight start stops after current call returns");
        Check(fake.coordinates.count == 0 && ![fake.calls containsObject:@"start"], "No late activation after stop");
        Check([stopReport[@"request_sent"] boolValue], "Cleanup requested after cancellation");
        [passed addObject:@"stop_invalidates_inflight_and_queued_starts"];

        fake = [ILLFakeBackend new]; fake.blockFirstPrepare = YES;
        engine = [[ILLFixedLocationEngine alloc] initWithBackend:fake];
        [engine startAtLatitude:1 longitude:2 completion:^(NSDictionary *report) { (void)report; dispatch_semaphore_signal(done); }];
        Wait(fake.entered);
        [engine stopWithCompletion:^(NSDictionary *report) {
            Check([report[@"state"] isEqual:@"superseded"], "Older stop cannot erase newer explicit start"); dispatch_semaphore_signal(done);
        }];
        [engine startAtLatitude:3 longitude:4 completion:^(NSDictionary *report) {
            Check([report[@"request_sent"] boolValue], "New explicit start is allowed"); dispatch_semaphore_signal(done);
        }];
        dispatch_semaphore_signal(fake.resume);
        Wait(done); Wait(done); Wait(done);
        Check([fake.coordinates isEqual:@[@[@3, @4]]], "Only newest coordinates delivered");
        [passed addObject:@"new_start_supersedes_older_pending_stop"];

        fake = [ILLFakeBackend new]; fake.throwStep = @"stop";
        engine = [[ILLFixedLocationEngine alloc] initWithBackend:fake];
        [engine stopWithCompletion:^(NSDictionary *report) {
            Check([report[@"state"] isEqual:@"cleanup_incomplete"], "Exception never reports successful stop");
            NSArray *timings = report[@"step_timings"];
            Check(timings.count == 4 && ![timings[1][@"returned"] boolValue]
                  && [timings[2][@"returned"] boolValue] && [timings[3][@"returned"] boolValue],
                  "Timing records thrown stop and subsequent cleanup separately");
            dispatch_semaphore_signal(done);
        }];
        Wait(done);
        Check([fake.calls containsObject:@"clear"] && [fake.calls containsObject:@"flush"], "Cleanup continues after stop exception");
        [passed addObject:@"cleanup_attempts_remaining_steps_after_exception"];

        fake = [ILLFakeBackend new]; fake.blockFirstPrepare = YES;
        engine = [[ILLFixedLocationEngine alloc] initWithBackend:fake];
        [engine startAtLatitude:5 longitude:6 completion:^(NSDictionary *report) {
            Check([report[@"request_sent"] boolValue], "Invalid subsequent input does not cancel valid request"); dispatch_semaphore_signal(done);
        }];
        Wait(fake.entered);
        [engine startAtLatitude:100 longitude:0 completion:^(NSDictionary *report) {
            Check([report[@"state"] isEqual:@"invalid_coordinates"], "Invalid later input rejected"); dispatch_semaphore_signal(done);
        }];
        dispatch_semaphore_signal(fake.resume);
        Wait(done); Wait(done);
        Check(!fake.badThread, "No backend callback on main");
        [passed addObject:@"invalid_input_does_not_supersede_valid_request"];

        NSData *json = [NSJSONSerialization dataWithJSONObject:
            @{@"schema": @"ios-location-lab.engine-tests.v1", @"passed": passed,
              @"count": @(passed.count), @"backend": @"fake_only", @"private_api_invoked": @NO}
            options:NSJSONWritingSortedKeys error:nil];
        fwrite(json.bytes, 1, json.length, stdout); putchar('\n');
        return 0;
    }
}
