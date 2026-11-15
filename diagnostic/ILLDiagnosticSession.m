// SPDX-License-Identifier: GPL-3.0-only
#import "ILLDiagnosticSession.h"
#import "ILLTiming.h"
#include <math.h>

static NSString *ILLStorageIssue(NSString *summary, NSError *error) {
    if (!error) return summary;
    return [summary stringByAppendingFormat:@" (%@ %ld)", error.domain, (long)error.code];
}

BOOL ILLParseCoordinateText(NSString *text, double *value) {
    NSString *clean = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!clean.length || ([clean containsString:@","] && [clean containsString:@"."])) return NO;
    clean = [clean stringByReplacingOccurrencesOfString:@"," withString:@"."];
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    double parsed;
    if (![scanner scanDouble:&parsed] || !scanner.isAtEnd || !isfinite(parsed)) return NO;
    *value = parsed;
    return YES;
}

@implementation ILLDiagnosticSession {
    ILLFixedLocationEngine *_engine;
    id<ILLExecutionGuard> _guard;
    dispatch_queue_t _control;
    dispatch_source_t _timer;
    NSURL *_stateURL;
    NSString *_phase;
    NSString *_storageError;
    NSString *_lastIssue;
    NSDictionary *_selected;
    NSDictionary *_lastReport;
    BOOL _needsCleanup, _active, _stopping, _continuous;
    uint64_t _token, _revision;
    double _deadline, _wallDeadline;
    NSMutableArray<dispatch_block_t> *_stopWaiters;
    NSLock *_activationGate;
    BOOL _guardExpired;
    uint64_t _stopEpoch;
    uint64_t _guardGeneration;
    double _activationWallTime;
    BOOL _recoveryDetected;
    double _recoveryStopReportTime;
}
- (instancetype)initWithEngine:(ILLFixedLocationEngine *)engine
                         guard:(id<ILLExecutionGuard>)guard directory:(NSURL *)directory {
    if ((self = [super init])) {
        _engine = engine; _guard = guard;
        _control = dispatch_queue_create("org.ios-location-lab.diagnostic", DISPATCH_QUEUE_SERIAL);
        _phase = @"idle";
        _stopWaiters = [NSMutableArray array];
        _activationGate = [NSLock new];
        _stateURL = [directory URLByAppendingPathComponent:@"cleanup-state.json"];
        _logURL = [directory URLByAppendingPathComponent:
            [NSString stringWithFormat:@"diagnostic-%@.jsonl", NSUUID.UUID.UUIDString]];
        dispatch_async(_control, ^{
            NSError *error;
            if (![NSFileManager.defaultManager createDirectoryAtURL:directory
                    withIntermediateDirectories:YES attributes:nil error:&error])
                self->_storageError = ILLStorageIssue(@"Could not prepare local storage.", error);
            if ([NSFileManager.defaultManager fileExistsAtPath:self->_stateURL.path]) {
                NSData *data = [NSData dataWithContentsOfURL:self->_stateURL];
                id state = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                if (![state isKindOfClass:NSDictionary.class]
                    || ![state[@"needs_cleanup"] isKindOfClass:NSNumber.class]) {
                    self->_storageError = @"Could not read the previous state. Use Request stop to recover.";
                } else {
                    self->_needsCleanup = [state[@"needs_cleanup"] boolValue];
                    self->_recoveryDetected = self->_needsCleanup;
                    if (self->_needsCleanup) self->_phase = @"recovery_required";
                }
            }
            [self publish:@"launch" details:@{}];
        });
    }
    return self;
}
- (BOOL)persistCleanup:(BOOL)pending {
    NSData *data = [NSJSONSerialization dataWithJSONObject:
        @{@"schema": @"ios-location-lab.diagnostic-state.v1", @"needs_cleanup": @(pending)}
        options:NSJSONWritingSortedKeys error:nil];
    NSError *error;
    if (!data || ![data writeToURL:_stateURL options:NSDataWritingAtomic error:&error]) {
        _storageError = ILLStorageIssue(@"Could not save cleanup state.", error);
        return NO;
    }
    _storageError = nil;
    return YES;
}
- (void)appendEvent:(NSDictionary *)entry {
    NSData *data = [NSJSONSerialization dataWithJSONObject:entry options:NSJSONWritingSortedKeys error:nil];
    if (!data) { _storageError = @"Could not serialize diagnostics."; return; }
    NSError *error = nil;
    if (![NSFileManager.defaultManager fileExistsAtPath:self.logURL.path]
        && ![NSData.data writeToURL:self.logURL options:NSDataWritingWithoutOverwriting error:&error]) {
        _storageError = ILLStorageIssue(@"Could not create local diagnostics.", error); return;
    }
    NSFileHandle *file = [NSFileHandle fileHandleForWritingToURL:self.logURL error:&error];
    if (!file) { _storageError = ILLStorageIssue(@"Could not open local diagnostics.", error); return; }
    @try {
        [file seekToEndOfFile]; [file writeData:data];
        [file writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [file closeFile];
    } @catch (NSException *exception) {
        (void)exception;
        _storageError = @"Could not write local diagnostics.";
        @try { [file closeFile]; } @catch (NSException *ignored) { (void)ignored; }
    }
}
- (void)publish:(NSString *)event details:(NSDictionary *)details {
    NSMutableDictionary *entry = [details mutableCopy];
    entry[@"event"] = event; entry[@"phase"] = _phase;
    entry[@"received_unix"] = @(NSDate.date.timeIntervalSince1970);
    entry[@"monotonic_seconds"] = @(ILLMonotonicSeconds());
    entry[@"session_token"] = @(_token);
    [self appendEvent:entry];
    NSDictionary *snapshot = @{@"phase": _phase, @"revision": @(++_revision), @"session_token": @(_token),
        @"needs_cleanup": @(_needsCleanup), @"needs_execution": @(_active || _stopping),
        @"active_request": @(_active), @"mode": _continuous ? @"continuous" : @"timed",
        @"has_deadline": @(!_continuous && _active),
        @"activation_requested_unix": @(_activationWallTime),
        @"recovery_detected": @(_recoveryDetected),
        @"recovery_stop_report_unix": @(_recoveryStopReportTime),
        @"can_activate": @(!_active && !_stopping && !_needsCleanup && !_storageError),
        @"stopping": @(_stopping), @"selected": _selected ?: (id)NSNull.null,
        @"last_report": _lastReport ?: (id)NSNull.null,
        @"last_issue": _lastIssue ?: @"", @"storage_error": _storageError ?: @"",
        @"wall_deadline": @(_wallDeadline), @"location_observed": NSNull.null,
        @"restoration_confirmed": NSNull.null};
    void (^callback)(NSDictionary *) = self.onChange;
    if (callback) dispatch_async(dispatch_get_main_queue(), ^{ callback(snapshot); });
}
- (BOOL)beginGuard {
    __weak ILLDiagnosticSession *weakSelf = self;
    uint64_t generation = _guardGeneration;
    return [_guard beginWithExpiration:^{
        ILLDiagnosticSession *session = weakSelf;
        if (!session) return;
        [session->_activationGate lock];
        if (generation != session->_guardGeneration) { [session->_activationGate unlock]; return; }
        session->_guardExpired = YES;
        [session->_activationGate unlock];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(session->_control, ^{
            if (generation != session->_guardGeneration) { dispatch_semaphore_signal(done); return; }
            if (!session->_needsCleanup && !session->_active && !session->_stopping) {
                dispatch_semaphore_signal(done); return;
            }
            session->_lastIssue = @"Session execution was interrupted. A stop was requested.";
            [session stopOnControl:session->_continuous ? @"continuous_execution_interrupted" : @"background_time_expired"
                       completion:^{ dispatch_semaphore_signal(done); }];
        });
        // Only the OS expiration path waits, never ordinary UI actions. Private
        // calls remain on the engine worker. A blocked call cannot be interrupted.
        BOOL finished = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0;
        dispatch_async(session->_control, ^{
            if (generation != session->_guardGeneration) return;
            [session publish:@"expiration_cleanup_wait" details:@{@"completed_within_one_second": @(finished)}];
        });
    } continuous:_continuous && _active];
}
- (void)activateLatitude:(double)latitude longitude:(double)longitude duration:(double)seconds {
    [self activateLatitude:latitude longitude:longitude duration:seconds continuous:NO];
}
- (void)activateContinuouslyAtLatitude:(double)latitude longitude:(double)longitude {
    [self activateLatitude:latitude longitude:longitude duration:0 continuous:YES];
}
- (void)activateLatitude:(double)latitude longitude:(double)longitude duration:(double)seconds continuous:(BOOL)continuous {
    [_activationGate lock]; uint64_t stopEpoch = _stopEpoch; [_activationGate unlock];
    dispatch_async(_control, ^{
        if (!CLLocationCoordinate2DIsValid(CLLocationCoordinate2DMake(latitude, longitude))
            || !isfinite(latitude) || !isfinite(longitude)
            || (!continuous && (!isfinite(seconds) || seconds <= 0 || seconds > 300))) {
            self->_lastIssue = @"Invalid coordinates or duration.";
            [self publish:@"invalid_input" details:@{}]; return;
        }
        if (self->_active || self->_stopping || self->_needsCleanup) {
            [self publish:@"activation_rejected_busy" details:@{}]; return;
        }
        if (self->_storageError) { [self publish:@"activation_rejected_storage" details:@{}]; return; }
        [self->_activationGate lock]; self->_guardExpired = NO; ++self->_guardGeneration;
        [self->_activationGate unlock];
        self->_continuous = continuous;
        // Select guard mode before publishing active state or touching the engine.
        self->_active = YES;
        if (![self beginGuard]) {
            self->_active = NO;
            self->_lastIssue = @"Could not start the session. Check location permission and try again with the app open.";
            [self publish:@"execution_guard_unavailable" details:@{}]; return;
        }
        if (![self persistCleanup:YES]) {
            self->_active = NO;
            [self->_guard end]; [self publish:@"activation_rejected_storage" details:@{}]; return;
        }
        self->_needsCleanup = YES; self->_active = YES; self->_lastIssue = nil; self->_lastReport = nil;
        self->_recoveryDetected = NO; self->_recoveryStopReportTime = 0;
        self->_phase = @"start_pending";
        self->_selected = @{@"latitude": @(latitude), @"longitude": @(longitude),
            @"mode": continuous ? @"continuous" : @"timed",
            @"duration_seconds": continuous ? (id)NSNull.null : @(seconds)};
        uint64_t token = ++self->_token;
        self->_activationWallTime = NSDate.date.timeIntervalSince1970;
        self->_deadline = continuous ? 0 : ILLMonotonicSeconds() + seconds;
        self->_wallDeadline = continuous ? 0 : NSDate.date.timeIntervalSince1970 + seconds;
        if (!continuous) {
            self->_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_control);
            dispatch_source_set_timer(self->_timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                                      DISPATCH_TIME_FOREVER, 0);
            __weak ILLDiagnosticSession *weakSelf = self;
            dispatch_source_set_event_handler(self->_timer, ^{
                ILLDiagnosticSession *session = weakSelf;
                if (session && token == session->_token) [session stopOnControl:@"lease_expired" completion:nil];
            });
            dispatch_resume(self->_timer);
        }
        [self publish:@"activation_selected" details:@{@"configuration": self->_selected}];
        // Coordinate this commit with the expiration callback. Once expiration
        // marks the guard, no newly queued start may overtake the cleanup.
        [self->_activationGate lock];
        if (self->_guardExpired || self->_stopEpoch != stopEpoch
            || (!continuous && (ILLMonotonicSeconds() >= self->_deadline
            || NSDate.date.timeIntervalSince1970 >= self->_wallDeadline))) {
            [self->_activationGate unlock];
            self->_lastIssue = @"The start request was canceled before being sent. Cleanup was requested.";
            [self stopOnControl:@"cancelled_before_start_commit" completion:nil];
            return;
        }
        [self->_engine startAtLatitude:latitude longitude:longitude completion:^(NSDictionary *report) {
            dispatch_async(self->_control, ^{
                if (token != self->_token) { [self publish:@"old_start_report" details:@{@"report": report}]; return; }
                self->_lastReport = report;
                if (!self->_stopping) {
                    if ([report[@"state"] isEqual:@"activation_requested_unverified"])
                        self->_phase = @"activation_requested_unverified";
                    else self->_lastIssue = @"The engine did not complete the start request. Cleanup was requested.";
                }
                [self publish:@"engine_start_report" details:@{@"report": report}];
                if (!self->_stopping && ![report[@"state"] isEqual:@"activation_requested_unverified"])
                    [self stopOnControl:@"start_failed" completion:nil];
            });
        }];
        [self->_activationGate unlock];
    });
}
- (void)stopWithReason:(NSString *)reason completion:(dispatch_block_t)completion {
    [_activationGate lock]; ++_stopEpoch; [_activationGate unlock];
    dispatch_async(_control, ^{ [self stopOnControl:reason completion:completion]; });
}
- (void)stopOnControl:(NSString *)reason completion:(dispatch_block_t)completion {
    if (completion) [_stopWaiters addObject:[completion copy]];
    if (_stopping) { [self publish:@"stop_coalesced" details:@{@"reason": reason}]; return; }
    _stopping = YES; _active = NO; _needsCleanup = YES; _phase = @"stop_pending";
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    (void)[self beginGuard]; // Cleanup is attempted even if background time is unavailable.
    uint64_t token = _token;
    // Invalidate pending engine starts before filesystem work or publishing UI.
    [_engine stopWithCompletion:^(NSDictionary *report) {
        dispatch_async(self->_control, ^{
            if (token != self->_token) return;
            self->_lastReport = report; self->_stopping = NO;
            BOOL sent = [report[@"request_sent"] boolValue];
            BOOL stored = sent && [self persistCleanup:NO];
            if (self->_recoveryDetected && stored)
                self->_recoveryStopReportTime = NSDate.date.timeIntervalSince1970;
            self->_needsCleanup = !stored;
            self->_phase = stored ? @"deactivation_requested_unverified" : @"cleanup_required";
            if (!sent) self->_lastIssue = @"Cleanup did not finish. Tap Request stop again.";
            [self->_guard end];
            [self publish:@"engine_stop_report" details:@{@"reason": reason, @"report": report}];
            NSArray<dispatch_block_t> *waiters = [self->_stopWaiters copy];
            [self->_stopWaiters removeAllObjects];
            for (dispatch_block_t waiter in waiters) waiter();
        });
    }];
    (void)[self persistCleanup:YES];
    [self publish:@"stop_requested" details:@{@"reason": reason}];
}
- (void)applicationEnteredBackground {
    dispatch_async(_control, ^{ [self publish:@"entered_background" details:@{}]; });
}
- (void)applicationBecameActive {
    dispatch_async(_control, ^{
        if (self->_needsCleanup && (!self->_active || (!self->_continuous
                && (ILLMonotonicSeconds() >= self->_deadline
                || NSDate.date.timeIntervalSince1970 >= self->_wallDeadline))))
            [self stopOnControl:@"foreground_recovery" completion:nil];
        else [self publish:@"became_active" details:@{}];
    });
}
- (void)refresh { dispatch_async(_control, ^{ [self publish:@"refresh" details:@{}]; }); }
- (void)recordObservation:(NSDictionary *)observation {
    dispatch_async(_control, ^{ [self appendEvent:observation]; });
}
- (void)exportLogWithCompletion:(void (^)(NSURL *))completion {
    dispatch_async(_control, ^{
        NSURL *copy = [[self.logURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:
            [NSString stringWithFormat:@"Shared-diagnostic-%@.jsonl", NSUUID.UUID.UUIDString]];
        BOOL copied = [NSFileManager.defaultManager copyItemAtURL:self.logURL toURL:copy error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(copied ? copy : nil); });
    });
}
@end
