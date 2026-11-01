#!/usr/bin/env bash
# Production packaging of the Q706F device repository, Linux runner.
#
#   scripts/package.sh [--os 17|26|27|PROFILE] [--no-deps] [--check] [unixnu options]
#
# ============================================================================
# THIS FILE IS A SPECIMEN, NOT THE SCRIPT.
#
# docs/porting/packaging.md, rule 3: "The script is fixed. templates/package.sh
# in the UniXNU repository is the only source. A device repository copies it
# unchanged. The one board value it reads itself is [package] unixnu."
#
# The real device repository must copy UniXNU/templates/package.sh verbatim:
#
#   curl -fsSL https://raw.githubusercontent.com/UniXNU/UniXNU/main/templates/package.sh \
#     -o scripts/package.sh && chmod +x scripts/package.sh
#
# Editing this file instead, or copying this file, breaks that rule and the
# unixnu release pipeline's assumption that one script serves every device.
# Nothing here may be needed: every value this board differs by belongs in
# board.toml, not in a script.
# ============================================================================
#
# What follows is the upstream script verbatim, annotated so the reason each
# line exists is visible. Copy it from UniXNU, not from here.

set -euo pipefail

# The device repository root: the script lives in <device>/scripts/.
DEVICE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# [package] unixnu is the one board value the script reads itself: the path of
# the UniXNU checkout, relative to the device repository. board.toml is parsed
# with tomllib so the shell never needs a TOML parser of its own.
UNIXNU=$(python3 - "$DEVICE/board.toml" <<'PY'
import sys, tomllib
package = tomllib.load(open(sys.argv[1], 'rb')).get('package', {})
if 'unixnu' not in package:
    sys.exit('board.toml needs [package] unixnu = "<path of the UniXNU checkout, relative to this repository>"')
print(package['unixnu'])
PY
)

# Absolute stays absolute; relative resolves against the device repository.
case "$UNIXNU" in /*) ROOT=$UNIXNU ;; *) ROOT=$(cd "$DEVICE/$UNIXNU" && pwd) ;; esac

# unixnu release runs deps, preflight, patches, build, pack, verify and then
# writes out/<device>/<os_profile>/<config>/package.manifest.json. Every
# remaining argument is passed through: --os, --no-deps, --check, --uefi,
# --kernelcache, --dtb, --out, -j.
exec python3 "$ROOT/unixnu" release -D "$DEVICE" "$@"
