#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
signer="$project_root/.tooling/ldid/ldid"
unsigned="$project_root/build/sdk-smoke/sdk-smoke"
signed="$project_root/build/sdk-smoke/sdk-smoke.signed"
test -x "$signer"
test -f "$unsigned"
cp -- "$unsigned" "$signed"
"$signer" -S "$signed"
"$signer" -h "$signed" > "$project_root/build/sdk-smoke/signature.txt"
sha256sum "$signed"
