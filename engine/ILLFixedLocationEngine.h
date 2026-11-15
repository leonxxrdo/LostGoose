// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <dispatch/dispatch.h>

NS_ASSUME_NONNULL_BEGIN
typedef void (^ILLCompletion)(NSDictionary *report);

// Backend seam permits lifecycle tests without invoking Apple's private service.
@protocol ILLLocationBackend <NSObject>
- (BOOL)validateForStart:(BOOL)starting error:(NSError **)error;
- (void)performStep:(NSString *)step location:(nullable CLLocation *)location;
@end

FOUNDATION_EXPORT NSDictionary *ILLInspectSimulationAPI(void);
FOUNDATION_EXPORT BOOL ILLMethodMatches(Class target, SEL selector,
                                      NSString *returnType, NSArray<NSString *> *arguments);

@interface ILLFixedLocationEngine : NSObject
- (instancetype)init;
- (instancetype)initWithBackend:(id<ILLLocationBackend>)backend NS_DESIGNATED_INITIALIZER;
// Completion runs on the private serial worker, never on the main thread.
// Calling stop immediately invalidates previously submitted starts, even if
// their worker blocks have not run. A later explicit start is a new request.
- (uint64_t)startAtLatitude:(double)latitude longitude:(double)longitude
                completion:(ILLCompletion)completion;
- (uint64_t)stopWithCompletion:(ILLCompletion)completion;
@end
NS_ASSUME_NONNULL_END
