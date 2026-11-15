#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sdk_path="$project_root/.tooling/theos/sdks/iPhoneOS16.5.sdk"
output_dir="$project_root/build/sdk-smoke"
test -f "$sdk_path/SDKSettings.json"
mkdir -p "$output_dir"
/usr/bin/clang -target arm64-apple-ios16.0 \
    -isysroot "$sdk_path" -fobjc-arc -fblocks \
    -Wall -Wextra -Werror \
    --ld-path=/usr/bin/ld64.lld -mlinker-version=820 \
    "$project_root/probes/sdk-smoke/main.m" \
    -framework Foundation -framework CoreLocation \
    -o "$output_dir/sdk-smoke" 2> "$output_dir/build.log"
/usr/bin/file "$output_dir/sdk-smoke"
/usr/bin/llvm-objdump --macho --dylibs-used "$output_dir/sdk-smoke"
