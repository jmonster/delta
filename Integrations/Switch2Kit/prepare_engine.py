#!/usr/bin/env python3
"""Stage the pinned Swift engine with its narrowly scoped Apple portability fix.

The vendor checkout is never edited. Both desktop and iOS builds consume this
same copy, so native bridge tests exercise the source used in the application.
"""
from __future__ import annotations
import argparse
import subprocess
from pathlib import Path

SESSION = Path("Bluetooth/ControllerSession.swift")


def portable_session(source: str) -> str:
    if "#if canImport(IOBluetooth)" in source:
        raise ValueError("The host-address portability fix is already present; review the dependency update.")
    replacements = [
        ("import IOBluetooth\n", "#if canImport(IOBluetooth)\nimport IOBluetooth\n#endif\n"),
        ("        guard let addr = IOBluetoothHostController.default()?.addressAsString() else {",
         "        #if canImport(IOBluetooth)\n        guard let addr = IOBluetoothHostController.default()?.addressAsString() else {"),
        ("        return Data(parts.reversed())\n",
         "        return Data(parts.reversed())\n        #else\n        // iOS has no public adapter address API. Preserve the existing\n        // unknown-address path; never invent an address or a successful bond.\n        return nil\n        #endif\n"),
    ]
    for before, after in replacements:
        if source.count(before) != 1:
            raise ValueError("The engine's host-address implementation changed; review the portability fix.")
        source = source.replace(before, after, 1)
    return source


def stage_sources(source: Path, destination: Path) -> None:
    if source.is_symlink() or destination.is_symlink():
        raise ValueError("Engine directories must not be symbolic links")
    expected = {}
    for path in sorted(source.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Unexpected engine source symlink: {path}")
        if path.is_file():
            relative = path.relative_to(source)
            data = path.read_bytes()
            if relative == SESSION:
                data = portable_session(data.decode("utf-8")).encode("utf-8")
            expected[relative] = data
    if SESSION not in expected:
        raise ValueError("Initialize the Switch2Kit submodule before preparing the engine")
    if destination.exists():
        # Refuse stale or hand-edited output rather than silently replacing it.
        actual = {}
        for path in destination.rglob("*"):
            if path.is_symlink():
                raise ValueError(f"Unexpected generated engine symlink: {path}")
            if path.is_file():
                actual[path.relative_to(destination)] = path.read_bytes()
        if actual != expected:
            raise ValueError("Generated engine differs; move Engine/Generated aside and run configuration again")
        return
    for relative, data in expected.items():
        path = destination / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


def prepare(root: Path) -> None:
    engine = root / "Integrations/Switch2Kit/Engine"
    vendor = engine / "Vendor/Switch2Kit"
    if not (vendor / ".git").exists():
        raise ValueError("Initialize the Switch2Kit submodule first")
    changed = subprocess.run(["git", "-C", str(vendor), "status", "--porcelain", "--untracked-files=all"],
                             check=True, capture_output=True, text=True)
    if changed.stdout.strip():
        raise ValueError("Switch2Kit checkout has changes; refusing to stage an altered dependency")
    for path in [vendor, engine / "Generated"]:
        if not path.resolve().is_relative_to(root.resolve()):
            raise ValueError("Engine path leaves the checkout")
    stage_sources(vendor / "Sources/Switch2Kit", engine / "Generated/Switch2Kit")
    print("Prepared shared Apple engine; vendor checkout is unchanged.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    try:
        prepare(args.root.resolve())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Switch2Kit engine preparation failed: {error}\n")
