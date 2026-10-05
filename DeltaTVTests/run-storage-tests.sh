#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/delta-tv-storage.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
"${SWIFTC:-swiftc}" -swift-version 6 -strict-concurrency=complete -warnings-as-errors -module-cache-path "$BUILD/modules" -parse-as-library \
  "$ROOT/DeltaTV/Storage/TVCloudModel.swift" \
  "$ROOT/DeltaTV/Storage/TVLibraryStore.swift" \
  "$ROOT/DeltaTVTests/StorageTests.swift" -o "$BUILD/storage-tests"
"$BUILD/storage-tests"
