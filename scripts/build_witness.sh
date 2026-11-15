#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sdk_path="$project_root/.tooling/theos/sdks/iPhoneOS16.5.sdk"
output_dir="$project_root/build/witness"
app_path="$output_dir/Payload/LocationWitness.app"
mkdir -p "$app_path"
/usr/bin/clang -target arm64-apple-ios16.0 -isysroot "$sdk_path" \
    -fobjc-arc -fblocks -Wall -Wextra -Werror \
    --ld-path=/usr/bin/ld64.lld -mlinker-version=820 \
    "$project_root/witness/main.m" -framework UIKit -framework Foundation -framework CoreLocation \
    -o "$app_path/LocationWitness" 2> "$output_dir/build.log"
/usr/bin/python3 - "$app_path" <<'PY'
import plistlib,sys
from pathlib import Path
app=Path(sys.argv[1])
info={'CFBundleIdentifier':'org.ioslocationlab.witness','CFBundleDisplayName':'Location Witness',
      'CFBundleName':'LocationWitness','CFBundleExecutable':'LocationWitness',
      'CFBundlePackageType':'APPL','CFBundleVersion':'2','CFBundleShortVersionString':'0.1.1',
      'CFBundleSupportedPlatforms':['iPhoneOS'],'LSRequiresIPhoneOS':True,
      'MinimumOSVersion':'16.0','UIDeviceFamily':[1,2],'UIRequiredDeviceCapabilities':['arm64'],
      'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait'],'UILaunchScreen':{},
      'NSLocationWhenInUseUsageDescription':'Permite registrar lecturas de ubicación para comprobar la prueba de simulación y su restauración. Los datos se guardan solo en este dispositivo.'}
(app/'Info.plist').write_bytes(plistlib.dumps(info))
PY
"$project_root/.tooling/ldid/ldid" -S "$app_path/LocationWitness"
/usr/bin/python3 - "$output_dir" <<'PY'
import zipfile,sys
from pathlib import Path
root=Path(sys.argv[1])
with zipfile.ZipFile(root/'LocationWitness.ipa','w',compression=zipfile.ZIP_DEFLATED) as z:
    for p in sorted((root/'Payload').rglob('*')):
        if p.is_file():z.write(p,p.relative_to(root))
(root/'LocationWitness-0.1.1.ipa').write_bytes((root/'LocationWitness.ipa').read_bytes())
PY
sha256sum "$output_dir/LocationWitness.ipa"
