// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <time.h>

// Local durations only. This clock does not certify when locationd applies an effect.
static inline double ILLMonotonicSeconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1e9;
}
