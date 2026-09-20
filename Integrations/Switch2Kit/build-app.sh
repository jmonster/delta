#!/bin/bash
set -euo pipefail

# Delta's pinned melonDS project includes the ARM64 JIT assembly. Build the
# complete application for the matching simulator/device architecture; the
# standalone engine check separately retains both simulator architectures.
case "${1:-}" in
  simulator) destination='generic/platform=iOS Simulator' ;;
  device) destination='generic/platform=iOS' ;;
  *) echo 'Usage: build-app.sh simulator|device' >&2; exit 64 ;;
esac

cd "$(dirname "$0")/../.."
mkdir -p build
log="build/switch2kit-$1-app.log"
if xcodebuild -workspace Delta-Switch2Kit.xcworkspace -scheme Delta \
  -configuration Debug -destination "$destination" \
  -derivedDataPath build/switch2kit-app ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO build > "$log" 2>&1; then
  tail -n 20 "$log"
else
  status=$?
  grep -n -B 4 -A 8 -E 'error:|BUILD FAILED|failed:' "$log" || true
  tail -n 80 "$log"
  exit "$status"
fi
