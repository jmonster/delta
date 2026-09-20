"""Source-generation regressions; actual Apple SDK builds remain separate gates."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Engine/Compatibility/patch_session.py"
spec = importlib.util.spec_from_file_location("patch_session", SCRIPT)
compatibility = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compatibility)
# Verbatim helper from SDK 6b5cba6, ControllerSession.swift (blob 8e38031a),
# retained to exercise the small transform without initializing submodules.
ORIGINAL = (ROOT / "tests/fixtures/HostBluetooth.swift.txt").read_bytes()


class CompatibilityTests(unittest.TestCase):
    def transformed(self, source=ORIGINAL):
        with patch.object(compatibility, "SESSION_BLOB", compatibility.git_blob(source)):
            return compatibility.patch_session(source)

    def test_only_import_and_host_address_availability_change(self):
        result = self.transformed()
        self.assertIn(b"#if canImport(IOBluetooth)\nimport IOBluetooth\n#endif", result)
        self.assertIn(b"macAddressBytesLE: Data? {\n        #if canImport(IOBluetooth)", result)
        self.assertIn(b"        #else\n        // iOS has no public host-adapter address API. Do not invent a bond.\n        return nil\n        #endif", result)
        self.assertIn(b"IOBluetoothHostController.default()?.addressAsString()", result)
        self.assertIn(b"return Data(parts.reversed())", result)
        # Protocol/session code outside the helper is not touched.
        prefix = b"// retained session and bonding implementation\n"
        suffix = b"// retained tail\n"
        self.assertEqual(self.transformed(prefix + ORIGINAL + suffix), prefix + result + suffix)

    def test_wrong_source_revision_is_rejected(self):
        for source in [b"", ORIGINAL, ORIGINAL + b"// edited"]:
            with self.assertRaises(ValueError):
                compatibility.patch_session(source)

    def test_missing_or_duplicate_patch_site_is_rejected(self):
        for source in [ORIGINAL.replace(b"import IOBluetooth", b"import SomethingElse"), ORIGINAL * 2]:
            with self.assertRaises(ValueError):
                self.transformed(source)

    def test_source_is_unchanged_and_generation_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output = root / "source.swift", root / "derived/ControllerSession.swift"
            source.write_bytes(ORIGINAL)
            with patch.object(compatibility, "SESSION_BLOB", compatibility.git_blob(ORIGINAL)):
                compatibility.generate(source, output)
                first = output.stat().st_mtime_ns
                compatibility.generate(source, output)
            self.assertEqual(source.read_bytes(), ORIGINAL)
            self.assertEqual(output.read_bytes(), self.transformed())
            self.assertEqual(output.stat().st_mtime_ns, first)

    def test_failed_generation_does_not_replace_existing_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output = root / "source.swift", root / "output.swift"
            source.write_bytes(b"unexpected SDK")
            output.write_bytes(b"previous output")
            with self.assertRaises(ValueError):
                compatibility.generate(source, output)
            self.assertEqual(output.read_bytes(), b"previous output")

    def test_symlinks_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output, link = root / "source", root / "output", root / "link"
            source.write_bytes(ORIGINAL)
            link.symlink_to(source)
            with self.assertRaises(ValueError):
                compatibility.generate(link, output)
            with self.assertRaises(ValueError):
                compatibility.generate(source, link)
            self.assertEqual(source.read_bytes(), ORIGINAL)

    def test_plugin_builds_generated_source_and_rejects_drift(self):
        # Exercise the real plugin/command in SwiftPM, not a second plugin mock.
        # The fixture substitutes ONLY the expected source hash in a private copy
        # of the generator; the production generator stays pinned to the SDK.
        swift = shutil.which("swift")
        self.assertIsNotNone(swift, "Swift 6.2+ is required")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "Engine/Plugins", root / "Plugins")
            (root / "Compatibility").mkdir()
            (root / "Compatibility/patch_session.py").write_text(
                SCRIPT.read_text().replace(compatibility.SESSION_BLOB, compatibility.git_blob(b"import Foundation\n" + ORIGINAL)))
            sources = root / "Vendor/Switch2Kit/Sources/Switch2Kit"
            (sources / "Bluetooth").mkdir(parents=True)
            session = sources / "Bluetooth/ControllerSession.swift"
            session.write_bytes(b"import Foundation\n" + ORIGINAL)
            (sources / "Probe.swift").write_text("import Foundation\npublic func probe() -> Data? { HostBluetooth.macAddressBytesLE }\n")
            (root / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "CompatibilityProbe", targets: [
    .target(name: "Probe", path: "Vendor/Switch2Kit/Sources/Switch2Kit",
            exclude: ["Bluetooth/ControllerSession.swift"],
            swiftSettings: [.define("S2K_RADIO_FIXTURE")],
            plugins: [.plugin(name: "Switch2IOSCompatibility")]),
    .plugin(name: "Switch2IOSCompatibility", capability: .buildTool())
])
''')
            command = [swift, "build", "--package-path", str(root)]
            good = subprocess.run(command, capture_output=True, text=True, timeout=120)
            self.assertEqual(good.returncode, 0, good.stdout + good.stderr)
            session.write_bytes(session.read_bytes() + b"\n// unexpected upstream edit\n")
            bad = subprocess.run(command, capture_output=True, text=True, timeout=120)
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn("differs from the pinned SDK", bad.stdout + bad.stderr)


if __name__ == "__main__":
    unittest.main()
