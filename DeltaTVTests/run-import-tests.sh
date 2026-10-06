#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT
"${SWIFTC:-swiftc}" -swift-version 6 -strict-concurrency=complete -warnings-as-errors -module-cache-path "$temporary_directory/module-cache" \
  DeltaTV/Storage/TVCloudModel.swift DeltaTV/UI/TVROMImportPolicy.swift DeltaTVTests/TVROMImportPolicyTests.swift \
  -o "$temporary_directory/import-tests"
"$temporary_directory/import-tests"
