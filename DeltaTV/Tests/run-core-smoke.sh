#!/usr/bin/env bash
# Portable Linux/macOS test of the exact pinned C++ core selected by DeltaTV.
# Does not use an Apple SDK, run an Xcode build, or validate Apple TV UI/audio output.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/delta-tv-core-smoke.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
SOURCES=()
while IFS= read -r source; do
    SOURCES+=("$source")
done < <(python3 - <<'PY'
import json
with open('DeltaTV/Compatibility/sources.json') as file:
    manifest = json.load(file)
for path in manifest['GBCDeltaCore']['sources']:
    if path.endswith('.cpp'):
        print(path)
PY
)
"${CXX:-c++}" -std=c++14 -O1 -DHAVE_CSTDINT \
    -I Cores/GBCDeltaCore/gambatte/libgambatte/include \
    -I Cores/GBCDeltaCore/gambatte/libgambatte/src \
    -I Cores/GBCDeltaCore/gambatte/common \
    -I Cores/GBCDeltaCore/GBCDeltaCore/Bridge \
    "${SOURCES[@]}" DeltaTV/Tests/core-smoke.cpp -o "$BUILD/core-smoke"
"$BUILD/core-smoke" "$BUILD"
