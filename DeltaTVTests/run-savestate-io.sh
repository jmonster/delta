#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:?Pass a task-local output directory}"
mkdir -p "$OUTPUT"
xcrun --sdk macosx clang++ -std=c++17 \
    -I "$ROOT/Cores/MelonDSDeltaCore/melonDS/src" \
    -include "$ROOT/DeltaTV/Compatibility/MelonDSDeltaCore/melonDS/src/Savestate.h" \
    "$ROOT/DeltaTV/Compatibility/MelonDSDeltaCore/melonDS/src/Savestate.cpp" \
    "$ROOT/DeltaTVTests/SavestateIOTests.cpp" -o "$OUTPUT/savestate-io-tests"
"$OUTPUT/savestate-io-tests" "$OUTPUT/state-io-test.tmp"
