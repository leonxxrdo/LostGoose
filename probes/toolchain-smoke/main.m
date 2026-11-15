// SPDX-License-Identifier: GPL-3.0-only
// Compile-only check: no SDK headers, no location API and no device access.
// Linking requires the iOS runtime libraries and is a separate validation.
int main(void) {
    @autoreleasepool {
        return 0;
    }
}
