#!/usr/bin/env python3
"""Generate the iOS-compatible session in SwiftPM's derived-source directory.

The vendored SDK is never edited. Only the pinned ControllerSession.swift is
accepted; all protocol/session code stays byte-identical except for the two
IOBluetooth availability guards and the existing no-address fallback.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

SESSION_BLOB = "8e38031a7699c039c8f3f5b14c3d7fbad32e15a0"


def git_blob(data: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def patch_session(source: bytes) -> bytes:
    if git_blob(source) != SESSION_BLOB:
        raise ValueError("ControllerSession.swift differs from the pinned SDK; review the compatibility patch before updating the pin")
    replacements = [
        (b"#if canImport(CoreBluetooth) || S2K_RADIO_FIXTURE\nimport IOBluetooth\n",
         b"#if canImport(CoreBluetooth) || S2K_RADIO_FIXTURE\n#if canImport(IOBluetooth)\nimport IOBluetooth\n#endif\n"),
        (b"    package static var macAddressBytesLE: Data? {\n",
         b"    package static var macAddressBytesLE: Data? {\n        #if canImport(IOBluetooth)\n"),
        (b"        return Data(parts.reversed())\n    }\n}\n",
         b"        return Data(parts.reversed())\n        #else\n        // iOS has no public host-adapter address API. Do not invent a bond.\n        return nil\n        #endif\n    }\n}\n"),
    ]
    for old, new in replacements:
        if source.count(old) != 1:
            raise ValueError("Expected exactly one pinned HostBluetooth compatibility site")
        source = source.replace(old, new, 1)
    return source


def generate(source: Path, output: Path) -> None:
    if source.is_symlink() or output.is_symlink():
        raise ValueError("Compatibility source/output must not be symlinks")
    result = patch_session(source.read_bytes())
    output.parent.mkdir(parents=True, exist_ok=True)
    if not output.exists() or output.read_bytes() != result:
        output.write_bytes(result)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        generate(args.source, args.output)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Switch2Kit compatibility generation failed: {error}\n")


if __name__ == "__main__":
    main()
