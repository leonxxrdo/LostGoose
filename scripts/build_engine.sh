#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sdk_path="$project_root/.tooling/theos/sdks/iPhoneOS16.5.sdk"
output_dir="$project_root/build/engine"
mkdir -p "$output_dir"
flags=(-target arm64-apple-ios16.0 -isysroot "$sdk_path" -fobjc-arc -fblocks
    -Wall -Wextra -Werror --ld-path=/usr/bin/ld64.lld -mlinker-version=820
    -I"$project_root/engine" -framework Foundation -framework CoreLocation)
/usr/bin/clang "${flags[@]}" "$project_root/engine/ILLFixedLocationEngine.m" \
    "$project_root/console/main.m" -o "$output_dir/location-lab" 2> "$output_dir/build.log"
/usr/bin/clang "${flags[@]}" "$project_root/engine/ILLFixedLocationEngine.m" \
    "$project_root/tests/engine-tests.m" -o "$output_dir/engine-tests" 2> "$output_dir/tests-build.log"
/usr/bin/clang "${flags[@]}" -DILL_CONSOLE_FAKE_BACKEND=1 \
    "$project_root/engine/ILLFixedLocationEngine.m" "$project_root/console/main.m" \
    "$project_root/tests/console-fake-backend.m" -o "$output_dir/console-fake" 2> "$output_dir/fake-build.log"
cp -- "$output_dir/location-lab" "$output_dir/location-lab.signed"
cp -- "$output_dir/engine-tests" "$output_dir/engine-tests.signed"
cp -- "$output_dir/console-fake" "$output_dir/console-fake.signed"
"$project_root/.tooling/ldid/ldid" -S"$project_root/console/entitlements.plist" "$output_dir/location-lab.signed"
"$project_root/.tooling/ldid/ldid" -S "$output_dir/engine-tests.signed"
"$project_root/.tooling/ldid/ldid" -S "$output_dir/console-fake.signed"
"$project_root/.tooling/ldid/ldid" -e "$output_dir/location-lab.signed" > "$output_dir/embedded-entitlements.plist"
sha256sum "$output_dir/location-lab.signed" "$output_dir/engine-tests.signed"
