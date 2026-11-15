// SPDX-License-Identifier: GPL-3.0-only
#import "ILLFixedLocationEngine.h"
#import "ILLTiming.h"
#import <objc/runtime.h>
#include <mach-o/dyld.h>
#include <math.h>
#include <stdatomic.h>

static NSString *ILLString(const char *s) {
    return s ? [NSString stringWithUTF8String:s] : @"";
}

BOOL ILLMethodMatches(Class target, SEL selector, NSString *returnType, NSArray *arguments) {
    Method m = target ? class_getInstanceMethod(target, selector) : NULL;
    if (!m || method_getNumberOfArguments(m) != arguments.count) return NO;
    char *r = method_copyReturnType(m);
    BOOL matches = [ILLString(r) isEqual:returnType];
    free(r);
    for (unsigned int i = 0; matches && i < arguments.count; i++) {
        char *a = method_copyArgumentType(m, i);
        matches = [ILLString(a) isEqual:arguments[i]];
        free(a);
    }
    return matches;
}

static NSArray *ILLSignatures(BOOL starting) {
    NSMutableArray *specs = [@[
        @[@"init", @"@", @[@"@", @":"]],
        @[@"stopLocationSimulation", @"v", @[@"@", @":"]],
        @[@"clearSimulatedLocations", @"v", @[@"@", @":"]],
        @[@"flush", @"v", @[@"@", @":"]]
    ] mutableCopy];
    if (starting) [specs addObjectsFromArray:@[
        @[@"appendSimulatedLocation:", @"v", @[@"@", @":", @"@"]],
        @[@"startLocationSimulation", @"v", @[@"@", @":"]],
        @[@"setLocationRepeatBehavior:", @"v", @[@"@", @":", @"C"]],
        @[@"setLocationDeliveryBehavior:", @"v", @[@"@", @":", @"C"]]
    ]];
    return specs;
}

NSDictionary *ILLInspectSimulationAPI(void) {
    Class target = objc_lookUpClass("CLSimulationManager");
    NSMutableArray *checks = [NSMutableArray array];
    BOOL valid = target != Nil;
    for (NSArray *spec in ILLSignatures(YES)) {
        SEL sel = sel_registerName([spec[0] UTF8String]);
        Method method = target ? class_getInstanceMethod(target, sel) : NULL;
        BOOL match = ILLMethodMatches(target, sel, spec[1], spec[2]);
        [checks addObject:@{@"selector": spec[0], @"matches": @(match),
                           @"encoding": method ? ILLString(method_getTypeEncoding(method)) : @""}];
        valid = valid && match;
    }
    NSMutableArray *injections = [NSMutableArray array];
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        NSString *name = ILLString(_dyld_get_image_name(i)).lastPathComponent;
        NSString *lower = name.lowercaseString;
        if ([lower containsString:@"gpsmaster"] || [lower containsString:@"ellekit"]
            || [lower containsString:@"substrate"] || [lower containsString:@"libhooker"])
            [injections addObject:name];
    }
    return @{@"class_present": target ? @YES : @NO, @"signature_shapes_match": @(valid),
             @"checks": checks, @"injection_related_images": injections,
             @"injection_scan_exhaustive": @NO, @"manager_instantiated": @NO,
             @"backend_authorization_verified": @NO};
}

// ABI declarations follow the types measured on iOS 17.3.1 (21D61).
// Runtime validation remains mandatory before any of these messages are sent.
@protocol ILLSimulationSurface <NSObject>
- (void)stopLocationSimulation;
- (void)clearSimulatedLocations;
- (void)appendSimulatedLocation:(CLLocation *)location;
- (void)startLocationSimulation;
- (void)flush;
- (void)setLocationRepeatBehavior:(unsigned char)value;
- (void)setLocationDeliveryBehavior:(unsigned char)value;
@end

@interface ILLAppleLocationBackend : NSObject <ILLLocationBackend>
@property(nonatomic, strong) id<ILLSimulationSurface> manager;
@end

@implementation ILLAppleLocationBackend
- (BOOL)validateForStart:(BOOL)starting error:(NSError **)error {
    Class cls = objc_lookUpClass("CLSimulationManager");
    for (NSArray *spec in ILLSignatures(starting)) {
        if (!ILLMethodMatches(cls, sel_registerName([spec[0] UTF8String]), spec[1], spec[2])) {
            if (error) *error = [NSError errorWithDomain:@"ILLRuntime" code:1
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Missing class or incompatible signature: %@", spec[0]]}];
            return NO;
        }
    }
    return YES;
}
- (void)performStep:(NSString *)step location:(CLLocation *)location {
    if ([step isEqual:@"prepare"]) {
        if (!self.manager) {
            Class cls = objc_lookUpClass("CLSimulationManager");
            self.manager = [[cls alloc] init];
            if (!self.manager) [NSException raise:@"ILLInitFailed" format:@"Manager initialization returned nil"];
        }
    } else if ([step isEqual:@"stop"]) [self.manager stopLocationSimulation];
    else if ([step isEqual:@"clear"]) [self.manager clearSimulatedLocations];
    else if ([step isEqual:@"flush"]) [self.manager flush];
    else if ([step isEqual:@"repeat-last"]) [self.manager setLocationRepeatBehavior:1];
    else if ([step isEqual:@"delivery-as-is"]) [self.manager setLocationDeliveryBehavior:0];
    else if ([step isEqual:@"append"]) [self.manager appendSimulatedLocation:location];
    else if ([step isEqual:@"start"]) [self.manager startLocationSimulation];
    else [NSException raise:@"ILLUnknownStep" format:@"Unknown operation"];
}
@end

@implementation ILLFixedLocationEngine {
    dispatch_queue_t _worker;
    id<ILLLocationBackend> _backend;
    atomic_uint_fast64_t _generation;
}
- (instancetype)init {
    return [self initWithBackend:[ILLAppleLocationBackend new]];
}
- (instancetype)initWithBackend:(id<ILLLocationBackend>)backend {
    self = [super init];
    if (self) {
        _backend = backend;
        _worker = dispatch_queue_create("org.ios-location-lab.engine", DISPATCH_QUEUE_SERIAL);
        atomic_init(&_generation, 0);
    }
    return self;
}
- (NSMutableDictionary *)reportForAction:(NSString *)action generation:(uint64_t)generation requested:(double)requested {
    return [@{@"action": action, @"generation": @(generation),
              @"state": @"pending", @"steps_returned": [NSMutableArray array],
              @"request_sent": @NO, @"location_observed": NSNull.null,
              @"restoration_confirmed": NSNull.null,
              @"backend_authorization_verified": @NO,
              @"requested_monotonic_seconds": @(requested),
              @"worker_started_monotonic_seconds": @(ILLMonotonicSeconds()),
              @"step_timings": [NSMutableArray array],
              @"on_main_thread": @(NSThread.isMainThread)} mutableCopy];
}
- (void)performTimedStep:(NSString *)step location:(CLLocation *)location report:(NSMutableDictionary *)report {
    double began = ILLMonotonicSeconds();
    BOOL returned = NO;
    @try {
        [_backend performStep:step location:location];
        returned = YES;
    } @finally {
        double ended = ILLMonotonicSeconds();
        [report[@"step_timings"] addObject:@{@"step": step,
            @"began_monotonic_seconds": @(began), @"ended_monotonic_seconds": @(ended),
            @"elapsed_seconds": @(ended - began), @"returned": @(returned)}];
    }
}
- (uint64_t)startAtLatitude:(double)latitude longitude:(double)longitude completion:(ILLCompletion)completion {
    double requested = ILLMonotonicSeconds();
    BOOL valid = isfinite(latitude) && isfinite(longitude) && latitude >= -90 && latitude <= 90
        && longitude >= -180 && longitude <= 180;
    uint64_t generation = valid
        ? atomic_fetch_add_explicit(&_generation, 1, memory_order_seq_cst) + 1
        : atomic_load_explicit(&_generation, memory_order_seq_cst);
    dispatch_async(_worker, ^{
        @autoreleasepool {
            NSMutableDictionary *report = [self reportForAction:@"start" generation:generation requested:requested];
            if (!valid) {
                report[@"state"] = @"invalid_coordinates";
                completion(report);
                return;
            }
            report[@"selected"] = @{@"latitude": @(latitude), @"longitude": @(longitude)};
            if (generation != atomic_load_explicit(&self->_generation, memory_order_seq_cst)) {
                report[@"state"] = @"superseded";
                completion(report);
                return;
            }
            NSError *error = nil;
            if (![self->_backend validateForStart:YES error:&error]) {
                report[@"state"] = @"incompatible_api";
                report[@"error"] = error.localizedDescription ?: @"Backend validation failed";
                completion(report);
                return;
            }
            CLLocation *location = [[CLLocation alloc]
                initWithCoordinate:CLLocationCoordinate2DMake(latitude, longitude)
                altitude:0 horizontalAccuracy:5 verticalAccuracy:-1
                course:-1 speed:0 timestamp:NSDate.date];
            for (NSString *step in @[@"prepare", @"stop", @"clear", @"repeat-last",
                                     @"delivery-as-is", @"append", @"flush", @"start", @"flush"]) {
                if (generation != atomic_load_explicit(&self->_generation, memory_order_seq_cst)) {
                    report[@"state"] = @"superseded";
                    completion(report);
                    return;
                }
                @try {
                    [self performTimedStep:step location:location report:report];
                    [report[@"steps_returned"] addObject:step];
                    if ([step isEqual:@"start"]) report[@"request_sent"] = @YES;
                } @catch (NSException *exception) {
                    report[@"state"] = @"backend_exception";
                    report[@"failed_step"] = step;
                    report[@"error"] = exception.name;
                    completion(report);
                    return;
                }
            }
            BOOL current = generation == atomic_load_explicit(&self->_generation, memory_order_seq_cst);
            report[@"state"] = current ? @"activation_requested_unverified" : @"superseded";
            report[@"request_sent"] = @YES; // Calls returned; service may still reject internally.
            completion(report);
        }
    });
    return generation;
}
- (uint64_t)stopWithCompletion:(ILLCompletion)completion {
    double requested = ILLMonotonicSeconds();
    uint64_t generation = atomic_fetch_add_explicit(&_generation, 1, memory_order_seq_cst) + 1;
    dispatch_async(_worker, ^{
        @autoreleasepool {
            NSMutableDictionary *report = [self reportForAction:@"stop" generation:generation requested:requested];
            if (generation != atomic_load_explicit(&self->_generation, memory_order_seq_cst)) {
                report[@"state"] = @"superseded";
                completion(report);
                return;
            }
            NSError *error = nil;
            if (![self->_backend validateForStart:NO error:&error]) {
                report[@"state"] = @"incompatible_api";
                report[@"error"] = error.localizedDescription ?: @"Backend validation failed";
                completion(report);
                return;
            }
            NSMutableArray *errors = [NSMutableArray array];
            // Each cleanup operation is attempted even if a preceding one throws.
            for (NSString *step in @[@"prepare", @"stop", @"clear", @"flush"]) {
                @try {
                    [self performTimedStep:step location:nil report:report];
                    [report[@"steps_returned"] addObject:step];
                } @catch (NSException *exception) {
                    [errors addObject:@{@"step": step, @"exception": exception.name}];
                    if ([step isEqual:@"prepare"]) break;
                }
            }
            report[@"state"] = errors.count ? @"cleanup_incomplete" : @"deactivation_requested_unverified";
            report[@"request_sent"] = @(errors.count == 0);
            if (errors.count) report[@"errors"] = errors;
            completion(report);
        }
    });
    return generation;
}
@end
