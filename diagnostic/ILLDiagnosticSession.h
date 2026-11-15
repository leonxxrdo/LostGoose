// SPDX-License-Identifier: GPL-3.0-only
#import "ILLFixedLocationEngine.h"

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT BOOL ILLParseCoordinateText(NSString *text, double *value);

@protocol ILLExecutionGuard <NSObject>
// Called on the session's control queue. begin is idempotent until end.
// Continuous mode uses a user-started background location activity; cleanup uses
// finite UIKit time. A guard invokes expiration outside the control queue.
- (BOOL)beginWithExpiration:(dispatch_block_t)expiration continuous:(BOOL)continuous;
- (void)end;
@end

@interface ILLDiagnosticSession : NSObject
@property(atomic, copy, nullable) void (^onChange)(NSDictionary *snapshot);
@property(nonatomic, readonly) NSURL *logURL;
- (instancetype)initWithEngine:(ILLFixedLocationEngine *)engine
                         guard:(id<ILLExecutionGuard>)guard directory:(NSURL *)directory;
- (void)activateLatitude:(double)latitude longitude:(double)longitude duration:(double)seconds;
- (void)activateContinuouslyAtLatitude:(double)latitude longitude:(double)longitude;
- (void)stopWithReason:(NSString *)reason completion:(nullable dispatch_block_t)completion;
- (void)applicationEnteredBackground;
- (void)applicationBecameActive;
- (void)refresh;
- (void)recordObservation:(NSDictionary *)observation;
- (void)exportLogWithCompletion:(void (^)(NSURL * _Nullable file))completion;
@end
NS_ASSUME_NONNULL_END
