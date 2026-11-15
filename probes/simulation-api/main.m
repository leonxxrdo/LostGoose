// SPDX-License-Identifier: GPL-3.0-only
// Reflection only: never allocates CLSimulationManager or invokes its methods.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static NSString *Text(const char *value) {
    return value ? [NSString stringWithUTF8String:value] : @"";
}

static NSDictionary *DescribeMethod(Method method) {
    if (!method) return @{@"present": @NO};
    char *returnType = method_copyReturnType(method);
    NSMutableArray *arguments = [NSMutableArray array];
    for (unsigned int i = 0; i < method_getNumberOfArguments(method); i++) {
        char *argumentType = method_copyArgumentType(method, i);
        [arguments addObject:Text(argumentType)];
        free(argumentType);
    }
    Dl_info origin = {0};
    dladdr((const void *)method_getImplementation(method), &origin);
    NSDictionary *result = @{
        @"present": @YES,
        @"selector": Text(sel_getName(method_getName(method))),
        @"encoding": Text(method_getTypeEncoding(method)),
        @"return_type": Text(returnType),
        @"argument_types": arguments,
        @"implementation_image_basename": Text(origin.dli_fname).lastPathComponent
    };
    free(returnType);
    return result;
}

static NSArray *DeclaredMethods(Class target) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(target, &count);
    NSMutableArray *result = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++)
        [result addObject:DescribeMethod(methods[i])];
    free(methods);
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"selector"] compare:b[@"selector"]];
    }];
    return result;
}

static NSDictionary *Probe(void) {
    // objc_lookUpClass and method metadata inspection send no messages to target.
    Class target = objc_lookUpClass("CLSimulationManager");
    NSArray *candidates = @[
        @{@"selector": @"init", @"return": @"@", @"args": @[@"@", @":"]},
        @{@"selector": @"clearSimulatedLocations", @"return": @"v", @"args": @[@"@", @":"]},
        @{@"selector": @"appendSimulatedLocation:", @"return": @"v", @"args": @[@"@", @":", @"@"]},
        @{@"selector": @"startLocationSimulation", @"return": @"v", @"args": @[@"@", @":"]},
        @{@"selector": @"stopLocationSimulation", @"return": @"v", @"args": @[@"@", @":"]},
        @{@"selector": @"flush", @"return": @"v", @"args": @[@"@", @":"]}
    ];
    NSMutableArray *checks = [NSMutableArray array];
    BOOL matched = target != Nil;
    for (NSDictionary *candidate in candidates) {
        SEL selector = sel_registerName([candidate[@"selector"] UTF8String]);
        Method method = target ? class_getInstanceMethod(target, selector) : NULL;
        NSMutableDictionary *check = [DescribeMethod(method) mutableCopy];
        check[@"selector"] = candidate[@"selector"];
        check[@"expected_return_type"] = candidate[@"return"];
        check[@"expected_argument_types"] = candidate[@"args"];
        BOOL shapeMatches = method
            && [check[@"return_type"] isEqual:candidate[@"return"]]
            && [check[@"argument_types"] isEqual:candidate[@"args"]];
        check[@"matches_candidate_shape"] = @(shapeMatches);
        matched = matched && shapeMatches;
        [checks addObject:check];
    }
    NSMutableArray *injectionImages = [NSMutableArray array];
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        NSString *name = Text(_dyld_get_image_name(i)).lastPathComponent;
        NSString *lower = name.lowercaseString;
        if ([lower containsString:@"gpsmaster"] || [lower containsString:@"ellekit"]
            || [lower containsString:@"substrate"] || [lower containsString:@"libhooker"])
            [injectionImages addObject:name];
    }
    return @{
        @"schema": @"ios-location-lab.simulation-api.v1",
        @"scope": @"runtime_metadata_only",
        @"os_version": NSProcessInfo.processInfo.operatingSystemVersionString,
        @"uid": @(getuid()),
        @"class_present": @(target != Nil),
        @"class_image": target ? Text(class_getImageName(target)) : @"",
        @"superclass": target ? Text(class_getName(class_getSuperclass(target))) : @"",
        @"candidate_signature_shapes_match": @(matched),
        @"candidate_checks": checks,
        @"declared_instance_methods": target ? DeclaredMethods(target) : @[],
        @"declared_class_methods": target ? DeclaredMethods(object_getClass(target)) : @[],
        @"injection_related_image_names": injectionImages,
        @"injection_scan_limit": @"Name filter only; no matches does not prove an unmodified process",
        @"manager_instantiated": @NO,
        @"manager_methods_invoked": @NO,
        @"real_location_requested": @NO,
        @"simulation_requested": @NO,
        @"backend_authorization_tested": @NO,
        @"external_effect_tested": @NO
    };
}

int main(void) {
    @autoreleasepool {
        NSDictionary *result = Probe();
        NSError *error = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:result
            options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
        if (!json) {
            fprintf(stderr, "JSON serialization failed: %s\n", error.description.UTF8String);
            return 1;
        }
        if (fwrite(json.bytes, 1, json.length, stdout) != json.length) return 1;
        putchar('\n');
        // A successful probe is not an authorization or simulation success result.
        return 0;
    }
}
