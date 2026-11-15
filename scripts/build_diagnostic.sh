#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sdk_path="$project_root/.tooling/theos/sdks/iPhoneOS16.5.sdk"
output_dir="${ILL_DIAGNOSTIC_OUTPUT_DIR:-$project_root/build/diagnostic}"
app_path="$output_dir/Payload/LocationLabDiagnostic.app"
mkdir -p "$app_path"
flags=(-target arm64-apple-ios16.0 -isysroot "$sdk_path" -fobjc-arc -fblocks
    -Wall -Wextra -Werror --ld-path=/usr/bin/ld64.lld -mlinker-version=820
    -I"$project_root/engine" -I"$project_root/diagnostic"
    -framework Foundation -framework CoreLocation)
/usr/bin/clang "${flags[@]}" -framework UIKit -framework MapKit \
    "$project_root/engine/ILLFixedLocationEngine.m" \
    "$project_root/diagnostic/ILLDiagnosticSession.m" \
    "$project_root/diagnostic/ILLUIKitExecutionGuard.m" \
    "$project_root/diagnostic/LGAppModel.m" "$project_root/diagnostic/LGMapController.m" \
    "$project_root/diagnostic/LGDiagnosticController.m" "$project_root/diagnostic/LGMoreController.m" \
    "$project_root/diagnostic/LGSearchController.m" "$project_root/diagnostic/main.m" \
    -o "$app_path/LocationLabDiagnostic" 2> "$output_dir/build.log"
/usr/bin/clang "${flags[@]}" "$project_root/engine/ILLFixedLocationEngine.m" \
    "$project_root/diagnostic/ILLDiagnosticSession.m" "$project_root/tests/diagnostic-session-tests.m" \
    -o "$output_dir/diagnostic-session-tests" 2> "$output_dir/tests-build.log"
/usr/bin/python3 - "$app_path" <<'PY'
import plistlib,sys
from pathlib import Path
app=Path(sys.argv[1])
info={'CFBundleIdentifier':'org.ioslocationlab.diagnostic','CFBundleDisplayName':'LostGoose',
      'CFBundleName':'LostGoose','CFBundleExecutable':'LocationLabDiagnostic',
      'CFBundlePackageType':'APPL','CFBundleVersion':'12','CFBundleShortVersionString':'0.3.7',
      'CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en'],
      'CFBundleSupportedPlatforms':['iPhoneOS'],'LSRequiresIPhoneOS':True,
      'MinimumOSVersion':'16.0','UIDeviceFamily':[1,2],'UIRequiredDeviceCapabilities':['arm64'],
      'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait'],'UILaunchScreen':{},
      'UIBackgroundModes':['location'],
      'NSLocationWhenInUseUsageDescription':'Shows the location received and keeps your ON session running when switching apps, with a visible location indicator. Logs stay on this iPhone.'}
(app/'Info.plist').write_bytes(plistlib.dumps(info))
PY
cp "$project_root/diagnostic/Branding.plist" "$app_path/Branding.plist"
/usr/bin/python3 "$project_root/scripts/build_app_icons.py" \
    --source "$project_root/icon.png" --app "$app_path" --manifest "$output_dir/app-icons.json"
"$project_root/.tooling/ldid/ldid" -S"$project_root/diagnostic/entitlements.plist" "$app_path"
"$project_root/.tooling/ldid/ldid" -e "$app_path/LocationLabDiagnostic" > "$output_dir/embedded-entitlements.plist"
"$project_root/.tooling/ldid/ldid" -S "$output_dir/diagnostic-session-tests"
/usr/bin/python3 - "$output_dir" <<'PY'
import zipfile,sys
from pathlib import Path
root=Path(sys.argv[1])
with zipfile.ZipFile(root/'LocationLabDiagnostic.ipa','w',compression=zipfile.ZIP_DEFLATED) as z:
    for p in sorted((root/'Payload').rglob('*')):
        if p.is_file():z.write(p,p.relative_to(root))
(root/'LostGoose-0.3.7.ipa').write_bytes((root/'LocationLabDiagnostic.ipa').read_bytes())
PY
sha256sum "$output_dir/LocationLabDiagnostic.ipa" "$output_dir/diagnostic-session-tests"
