// SPDX-License-Identifier: GPL-3.0-only
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import "ILLDiagnosticSession.h"
FOUNDATION_EXPORT NSNotificationName const LGModelChanged;
FOUNDATION_EXPORT BOOL LGRecent(CLLocation *location);
FOUNDATION_EXPORT NSString *LGCoordinates(CLLocationCoordinate2D point);
@interface LGAppModel : NSObject <CLLocationManagerDelegate>
@property(nonatomic, strong, readonly) ILLDiagnosticSession *session;
@property(nonatomic, strong, readonly) NSDictionary *snapshot;
@property(nonatomic, strong, readonly) CLLocation *lastLocation, *realReference;
@property(nonatomic, readonly) BOOL referenceConfirmed, wantsReadings;
@property(nonatomic, readonly) CLLocationCoordinate2D selected;
@property(nonatomic, copy) NSString *issue;
@property(nonatomic, copy, readonly) NSString *locationNotice, *lastLocationError;
- (instancetype)initWithSession:(ILLDiagnosticSession *)session;
- (void)notify;
- (BOOL)canSelect;
- (BOOL)selectLatitude:(NSString *)latitude longitude:(NSString *)longitude;
- (BOOL)canSaveReference;
- (void)saveRealReference;
- (void)activateTimed:(BOOL)timed;
- (void)stop;
- (void)requestReadings;
- (BOOL)hasPermission;
- (void)enteredBackground;
- (void)becameActive;
- (NSString *)statusText;
- (NSString *)recoveryText;
- (NSString *)readingText;
@end
