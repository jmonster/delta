#!/bin/bash
set -euo pipefail
# Prefer the newest installed Xcode with the SDK/toolchain this engine needs.
# Do not download or execute an unpinned third-party toolchain installer.
selected="$(python3 - <<'PY'
import pathlib, re, subprocess
candidates = []
for app in pathlib.Path('/Applications').glob('Xcode*.app'):
    developer = str(app / 'Contents/Developer')
    swift = app / 'Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift'
    if not swift.is_file():
        continue
    result = subprocess.run([str(swift), '--version'], capture_output=True, text=True)
    match = re.search(r'Swift version (\d+)\.(\d+)', result.stdout)
    if match and tuple(map(int, match.groups())) >= (6, 2):
        candidates.append((tuple(map(int, match.groups())), developer))
if not candidates:
    raise SystemExit('Install Xcode 26 or newer (Swift 6.2+) before building Switch2Kit.')
print(max(candidates)[1])
PY
)"
# GitHub Actions consumes GITHUB_ENV on the next step. For local use, print an
# export command; this helper never changes the machine-wide xcode-select path.
if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "DEVELOPER_DIR=$selected" >> "$GITHUB_ENV"
fi
printf 'export DEVELOPER_DIR=%q\n' "$selected"
DEVELOPER_DIR="$selected" xcodebuild -version
