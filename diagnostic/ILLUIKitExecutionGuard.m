// SPDX-License-Identifier: GPL-3.0-only
#import "ILLUIKitExecutionGuard.h"
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

@interface ILLUIKitExecutionGuard () <CLLocationManagerDelegate>
@end

@implementation ILLUIKitExecutionGuard {
    UIBackgroundTaskIdentifier _task;
    uint64_t _epoch;
    BOOL _starting;
    CLLocationManager *_continuousManager;
    dispatch_block_t _continuousExpiration;
}
- (instancetype)init {
    if ((self = [super init])) _task = UIBackgroundTaskInvalid;
    return self;
}
- (BOOL)beginWithExpiration:(dispatch_block_t)expiration continuous:(BOOL)continuous {
    @synchronized (self) { if (continuous && _continuousManager) return YES; }
    if (continuous) return [self beginContinuousWithExpiration:expiration];
    uint64_t epoch;
    @synchronized (self) {
        if (_task != UIBackgroundTaskInvalid) return YES;
        if (_starting) return NO;
        _starting = YES; epoch = ++_epoch;
    }
    __weak ILLUIKitExecutionGuard *weakSelf = self;
    UIBackgroundTaskIdentifier task = [UIApplication.sharedApplication
        beginBackgroundTaskWithName:@"Finish location diagnostic" expirationHandler:^{
            ILLUIKitExecutionGuard *guard = weakSelf;
            if (!guard) return;
            @synchronized (guard) { if (guard->_epoch != epoch) return; }
            expiration();
            [guard endEpoch:epoch];
        }];
    BOOL accepted;
    @synchronized (self) {
        accepted = _epoch == epoch;
        if (accepted) { _starting = NO; _task = task; }
    }
    if (!accepted && task != UIBackgroundTaskInvalid)
        [UIApplication.sharedApplication endBackgroundTask:task];
    return accepted && task != UIBackgroundTaskInvalid;
}
- (BOOL)beginContinuousWithExpiration:(dispatch_block_t)expiration {
    __block BOOL accepted = NO;
    void (^begin)(void) = ^{
        // Start the user-initiated background location activity only in foreground.
        // Never set allowsBackgroundLocationUpdates without the matching plist key.
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive
            || !CLLocationManager.locationServicesEnabled
            || ![[NSBundle.mainBundle objectForInfoDictionaryKey:@"UIBackgroundModes"] containsObject:@"location"])
            return;
        CLLocationManager *manager = [CLLocationManager new];
        CLAuthorizationStatus auth = manager.authorizationStatus;
        if (auth != kCLAuthorizationStatusAuthorizedAlways && auth != kCLAuthorizationStatusAuthorizedWhenInUse)
            return;
        manager.delegate = self;
        manager.desiredAccuracy = kCLLocationAccuracyBest;
        manager.distanceFilter = kCLDistanceFilterNone;
        manager.activityType = CLActivityTypeOther;
        manager.pausesLocationUpdatesAutomatically = NO;
        manager.showsBackgroundLocationIndicator = YES;
        manager.allowsBackgroundLocationUpdates = YES;
        @synchronized (self) {
            self->_continuousManager = manager;
            self->_continuousExpiration = [expiration copy];
        }
        [manager startUpdatingLocation];
        accepted = YES;
    };
    if (NSThread.isMainThread) begin(); else dispatch_sync(dispatch_get_main_queue(), begin);
    return accepted;
}
- (void)interruptContinuousManager:(CLLocationManager *)manager {
    dispatch_block_t expiration;
    @synchronized (self) {
        if (manager != _continuousManager) return;
        expiration = _continuousExpiration;
        _continuousExpiration = nil;
    }
    // The coordinator's bounded cleanup wait must not block the main delegate queue.
    if (expiration) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), expiration);
}
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    CLAuthorizationStatus auth = manager.authorizationStatus;
    if (auth != kCLAuthorizationStatusAuthorizedWhenInUse && auth != kCLAuthorizationStatusAuthorizedAlways)
        [self interruptContinuousManager:manager];
}
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    (void)manager; (void)locations; // UI observation is separate; no duplicate coordinate log.
}
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    if ([error.domain isEqual:kCLErrorDomain] && error.code == kCLErrorDenied)
        [self interruptContinuousManager:manager];
}
- (void)locationManagerDidPauseLocationUpdates:(CLLocationManager *)manager {
    [self interruptContinuousManager:manager];
}
- (void)endEpoch:(uint64_t)epoch {
    UIBackgroundTaskIdentifier task;
    @synchronized (self) {
        if (_epoch != epoch) return;
        task = _task; _task = UIBackgroundTaskInvalid; _starting = NO; ++_epoch;
    }
    if (task != UIBackgroundTaskInvalid) [UIApplication.sharedApplication endBackgroundTask:task];
}
- (void)end {
    CLLocationManager *manager;
    uint64_t epoch;
    @synchronized (self) {
        epoch = _epoch; manager = _continuousManager;
        _continuousManager = nil; _continuousExpiration = nil;
    }
    if (manager) dispatch_async(dispatch_get_main_queue(), ^{
        manager.delegate = nil;
        [manager stopUpdatingLocation]; manager.allowsBackgroundLocationUpdates = NO;
    });
    [self endEpoch:epoch];
}
@end
