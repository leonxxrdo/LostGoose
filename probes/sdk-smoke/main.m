// SPDX-License-Identifier: GPL-3.0-only
// Build/link probe only. Creates an in-memory value; requests no device location.
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        CLLocation *sample = [[CLLocation alloc] initWithLatitude:0 longitude:0];
        CLLocationCoordinate2D coordinate = sample.coordinate;
        BOOL valid = CLLocationCoordinate2DIsValid(coordinate)
            && coordinate.latitude == 0 && coordinate.longitude == 0;
        if (!valid) {
            fputs("SDK_SMOKE_FAILED: unexpected in-memory coordinate\n", stderr);
            return 1;
        }
        puts("SDK_SMOKE_OK: Foundation + CoreLocation; in-memory coordinate valid");
        return 0;
    }
}
