// SPDX-License-Identifier: GPL-3.0-only
// Linked only into the test console. It cannot access CLSimulationManager.
#import "ILLFixedLocationEngine.h"
@interface ILLConsoleFakeBackend : NSObject <ILLLocationBackend>
@end
@implementation ILLConsoleFakeBackend
- (BOOL)validateForStart:(BOOL)starting error:(NSError **)error {
    (void)starting; (void)error;
    return YES;
}
- (void)performStep:(NSString *)step location:(CLLocation *)location {
    (void)step; (void)location;
    if (NSThread.isMainThread) [NSException raise:@"TestMainThread" format:@"Backend ran on main thread"];
}
@end
ILLFixedLocationEngine *ILLCreateFakeConsoleEngine(void) {
    return [[ILLFixedLocationEngine alloc] initWithBackend:[ILLConsoleFakeBackend new]];
}
