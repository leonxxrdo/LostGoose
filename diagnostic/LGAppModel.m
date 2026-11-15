// SPDX-License-Identifier: GPL-3.0-only
#import "LGAppModel.h"
#include <math.h>
NSNotificationName const LGModelChanged = @"LostGooseModelChanged";
BOOL LGRecent(CLLocation *location) {
    double age = -location.timestamp.timeIntervalSinceNow;
    return location && CLLocationCoordinate2DIsValid(location.coordinate)
        && isfinite(location.horizontalAccuracy) && location.horizontalAccuracy >= 0
        && isfinite(age) && age >= -1 && age <= 5;
}
NSString *LGCoordinates(CLLocationCoordinate2D point) {
    return [NSString stringWithFormat:@"%.7f, %.7f", point.latitude, point.longitude];
}
static id Finite(double value) { return isfinite(value) ? @(value) : NSNull.null; }
@interface LGAppModel ()
@property(nonatomic, strong) ILLDiagnosticSession *session;
@property(nonatomic, strong) NSDictionary *snapshot;
@property(nonatomic, strong) CLLocationManager *manager;
@property(nonatomic, strong) CLLocation *lastLocation, *realReference;
@property(nonatomic) BOOL referenceConfirmed, wantsReadings, recoveryReadStarted;
@property(nonatomic) CLLocationCoordinate2D selected;
@property(nonatomic, copy) NSString *locationNotice, *lastLocationError;
@property(nonatomic, strong) NSTimer *timer;
@end
@implementation LGAppModel
- (instancetype)initWithSession:(ILLDiagnosticSession *)session {
    if ((self = [super init])) {
        _session = session; _selected = CLLocationCoordinate2DMake(35.68126, 139.76671);
        NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"selected_coordinate"];
        if ([saved[@"latitude"] isKindOfClass:NSNumber.class] && [saved[@"longitude"] isKindOfClass:NSNumber.class]) {
            CLLocationCoordinate2D point = CLLocationCoordinate2DMake([saved[@"latitude"] doubleValue], [saved[@"longitude"] doubleValue]);
            if (CLLocationCoordinate2DIsValid(point)) _selected = point;
        }
        _manager = [CLLocationManager new]; _manager.delegate = self;
        _manager.desiredAccuracy = kCLLocationAccuracyBest; _manager.distanceFilter = kCLDistanceFilterNone;
        __weak LGAppModel *weakSelf = self;
        session.onChange = ^(NSDictionary *snapshot) {
            LGAppModel *model = weakSelf; if (!model) return;
            model.snapshot = snapshot;
            if ([snapshot[@"recovery_detected"] boolValue] && [snapshot[@"recovery_stop_report_unix"] doubleValue] > 0
                && !model.recoveryReadStarted && [model hasPermission]
                && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                model.recoveryReadStarted = YES; [model requestReadings];
            }
            [model notify];
        };
        _timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) [weakSelf notify];
        }];
        [session refresh];
        [session recordObservation:@{@"event": @"app_build", @"version": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
            @"received_unix": @(NSDate.date.timeIntervalSince1970)}];
    }
    return self;
}
- (void)dealloc { [_timer invalidate]; }
- (void)notify { [NSNotificationCenter.defaultCenter postNotificationName:LGModelChanged object:self]; }
- (BOOL)canSelect { return self.snapshot && ![self.snapshot[@"needs_execution"] boolValue] && ![self.snapshot[@"needs_cleanup"] boolValue]; }
- (BOOL)selectLatitude:(NSString *)latitude longitude:(NSString *)longitude {
    double lat, lon;
    if (![self canSelect]) { self.issue = @"Turn the session off before changing the selected point."; [self notify]; return NO; }
    if (!ILLParseCoordinateText(latitude, &lat) || !ILLParseCoordinateText(longitude, &lon)
        || !CLLocationCoordinate2DIsValid(CLLocationCoordinate2DMake(lat, lon))) {
        self.issue = @"Enter a latitude from −90 to 90 and a longitude from −180 to 180."; [self notify]; return NO;
    }
    self.selected = CLLocationCoordinate2DMake(lat, lon); self.issue = nil;
    [NSUserDefaults.standardUserDefaults setObject:@{@"latitude": @(lat), @"longitude": @(lon)} forKey:@"selected_coordinate"];
    [self notify]; return YES;
}
- (BOOL)canSaveReference {
    return [self canSelect] && LGRecent(self.lastLocation) && self.lastLocation.sourceInformation
        && !self.lastLocation.sourceInformation.isSimulatedBySoftware;
}
- (void)saveRealReference {
    if (![self canSaveReference]) return;
    self.realReference = self.lastLocation; self.referenceConfirmed = YES; [self notify];
}
- (BOOL)preflight {
    NSDictionary *inspection = ILLInspectSimulationAPI();
    [self.session recordObservation:@{@"event": @"api_inspection", @"inspection": inspection,
        @"received_unix": @(NSDate.date.timeIntervalSince1970)}];
    if ([inspection[@"injection_related_images"] count]) self.issue = @"Disable tweak injection for LostGoose in Choicy, then reopen the app.";
    else if (![inspection[@"signature_shapes_match"] boolValue]) self.issue = @"The simulation API does not have the expected signatures.";
    else return YES;
    [self notify]; return NO;
}
- (void)activateTimed:(BOOL)timed {
    if (![self.snapshot[@"can_activate"] boolValue] || ![self preflight]) return;
    if (![self hasPermission]) {
        [self requestReadings]; self.issue = @"Allow location access, then turn the session on again."; [self notify]; return;
    }
    // An automatic pre-ON reference is historical and unconfirmed, never live GPS.
    if (!self.referenceConfirmed && [self canSaveReference]) self.realReference = self.lastLocation;
    [self requestReadings]; self.issue = nil;
    if (timed) [self.session activateLatitude:self.selected.latitude longitude:self.selected.longitude duration:30];
    else [self.session activateContinuouslyAtLatitude:self.selected.latitude longitude:self.selected.longitude];
}
- (void)stop { self.issue = nil; [self.session stopWithReason:@"user_off" completion:nil]; }
- (BOOL)hasPermission {
    CLAuthorizationStatus auth = self.manager.authorizationStatus;
    return auth == kCLAuthorizationStatusAuthorizedWhenInUse || auth == kCLAuthorizationStatusAuthorizedAlways;
}
- (void)requestReadings {
    self.wantsReadings = YES;
    if (self.manager.authorizationStatus == kCLAuthorizationStatusNotDetermined) [self.manager requestWhenInUseAuthorization];
    else [self resumeReadings];
}
- (void)resumeReadings {
    if (!self.wantsReadings) return;
    if ([self hasPermission]) {
        if ([ILLInspectSimulationAPI()[@"injection_related_images"] count]) {
            self.locationNotice = @"Readings stopped: disable tweak injection for LostGoose in Choicy."; [self notify]; return;
        }
        self.locationNotice = @"Waiting for new readings…"; [self.manager startUpdatingLocation];
    } else self.locationNotice = @"Allow location access while using the app and enable Precise Location.";
    [self notify];
}
- (void)enteredBackground { [self.manager stopUpdatingLocation]; [self.session applicationEnteredBackground]; }
- (void)becameActive { [self.session applicationBecameActive]; [self resumeReadings]; }
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager { (void)manager; [self resumeReadings]; }
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    if (!self.wantsReadings) return;
    for (CLLocation *location in locations) {
        self.lastLocation = location;
        // While OFF, keep an unconfirmed candidate. Freeze it during simulation;
        // only the user's Save action marks a reference as confirmed.
        if (!self.referenceConfirmed && [self canSaveReference]) self.realReference = location;
        CLLocationSourceInformation *source = location.sourceInformation;
        [self.session recordObservation:@{@"event": @"local_location", @"latitude": Finite(location.coordinate.latitude),
            @"longitude": Finite(location.coordinate.longitude), @"timestamp_unix": Finite(location.timestamp.timeIntervalSince1970),
            @"received_unix": @(NSDate.date.timeIntervalSince1970), @"age_seconds": Finite(-location.timestamp.timeIntervalSinceNow),
            @"fresh": @(LGRecent(location)), @"horizontal_accuracy_m": Finite(location.horizontalAccuracy),
            @"accuracy_authorization": @(manager.accuracyAuthorization), @"source_information": source ?
                @{@"simulated_by_software": @(source.isSimulatedBySoftware), @"produced_by_accessory": @(source.isProducedByAccessory)} : (id)NSNull.null}];
    }
    self.locationNotice = nil; [self notify];
}
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    [self.session recordObservation:@{@"event": @"location_error", @"domain": error.domain, @"code": @(error.code),
        @"received_unix": @(NSDate.date.timeIntervalSince1970)}];
    self.lastLocationError = [NSString stringWithFormat:@"Last notice: %@ (%ld)", error.domain, (long)error.code];
    if ([error.domain isEqual:kCLErrorDomain] && error.code == kCLErrorDenied) [manager stopUpdatingLocation];
    [self notify];
}
- (NSString *)statusText {
    NSDictionary *labels = @{@"idle": @"No active session.", @"start_pending": @"Sending fixed location request…",
        @"activation_requested_unverified": @"Fixed location requested.", @"stop_pending": @"Sending stop request…",
        @"deactivation_requested_unverified": @"Stop requested. Check the location received.",
        @"recovery_required": @"A previous session needs cleanup.", @"cleanup_required": @"Cleanup pending. Request a stop again."};
    NSMutableString *text = [NSMutableString stringWithString:labels[self.snapshot[@"phase"] ?: @"idle"] ?: @"Preparing session…"];
    if ([self.snapshot[@"active_request"] boolValue]) {
        if ([self.snapshot[@"has_deadline"] boolValue]) [text appendFormat:@"\nTest: %.0f s remaining", ceil(MAX(0, [self.snapshot[@"wall_deadline"] doubleValue] - NSDate.date.timeIntervalSince1970))];
        else [text appendString:@"\nON · no time limit"];
    }
    for (NSString *key in @[@"last_issue", @"storage_error"]) if ([self.snapshot[key] length]) [text appendFormat:@"\n%@", self.snapshot[key]];
    if (self.issue.length) [text appendFormat:@"\n%@", self.issue];
    return text;
}
- (NSString *)readingText {
    CLLocation *location = self.lastLocation;
    if (!location) return self.locationNotice ?: @"No readings. Tap Read location.";
    return [NSString stringWithFormat:@"%@\n%@\nAccuracy: ±%.1f m · Age: %.2f s\n%@",
        LGRecent(location) ? @"Recent reading" : @"Stale or invalid reading", LGCoordinates(location.coordinate),
        location.horizontalAccuracy, -location.timestamp.timeIntervalSinceNow, self.lastLocationError ?: @""];
}
- (NSString *)recoveryText {
    if (![self.snapshot[@"recovery_detected"] boolValue] || [self.snapshot[@"active_request"] boolValue]) return nil;
    NSString *detail;
    if ([self.snapshot[@"stopping"] boolValue]) detail = @"Requesting stop…";
    else if ([self.snapshot[@"needs_cleanup"] boolValue]) detail = @"Stop pending. Use Request stop in Diagnostics.";
    else if (!LGRecent(self.lastLocation) || self.lastLocation.timestamp.timeIntervalSince1970 < [self.snapshot[@"recovery_stop_report_unix"] doubleValue])
        detail = @"Stop requested. Waiting for a new reading.";
    else if (self.lastLocation.sourceInformation.isSimulatedBySoftware) detail = @"Stop requested. The reading is still marked as simulated.";
    else if (self.lastLocation.horizontalAccuracy > 50) detail = [NSString stringWithFormat:@"Stop requested. Accuracy is still low: ±%.0f m.", self.lastLocation.horizontalAccuracy];
    else detail = [NSString stringWithFormat:@"Stop requested. Recent reading: ±%.1f m. Check your position.", self.lastLocation.horizontalAccuracy];
    return [@"Previous session interrupted.\n" stringByAppendingString:detail];
}
@end
