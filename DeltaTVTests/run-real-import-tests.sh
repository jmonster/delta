#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT
"${SWIFTC:-swiftc}" -swift-version 6 -strict-concurrency=complete -warnings-as-errors -module-cache-path "$temporary_directory/modules" -parse-as-library \
  DeltaTV/Storage/TVCloudModel.swift DeltaTV/UI/TVROMImportPolicy.swift DeltaTVTests/TVRealROMImportPolicyTests.swift \
  -o "$temporary_directory/real-import-tests"
"$temporary_directory/real-import-tests"
