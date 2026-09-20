import importlib.util
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "prepare_engine.py"
spec = importlib.util.spec_from_file_location("prepare_engine", SCRIPT)
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)

HOST = '''#if canImport(CoreBluetooth) || S2K_RADIO_FIXTURE
import IOBluetooth

enum HostBluetooth {
    package static var macAddressBytesLE: Data? {
        guard let addr = IOBluetoothHostController.default()?.addressAsString() else {
            return nil
        }
        let parts = addr.split(whereSeparator: { $0 == ":" || $0 == "-" })
            .compactMap { UInt8($0, radix: 16) }
        guard parts.count == 6 else { return nil }
        return Data(parts.reversed())
    }
}
#endif
'''


class PrepareEngineTests(unittest.TestCase):
    def test_guards_import_and_use_without_replacing_address_conversion(self):
        result = engine.portable_session(HOST)
        self.assertIn("#if canImport(IOBluetooth)\nimport IOBluetooth\n#endif", result)
        self.assertIn("#if canImport(IOBluetooth)\n        guard let addr", result)
        self.assertIn("return Data(parts.reversed())\n        #else", result)
        self.assertIn("return nil\n        #endif", result)
        self.assertIn('addr.split(whereSeparator: { $0 == ":" || $0 == "-" })', result)

    def test_unrelated_session_and_bond_logic_are_preserved(self):
        prefix = "// unrelated protocol source\nfunc stepBond() {}\n"
        suffix = "// unrelated transport source\n"
        result = engine.portable_session(prefix + HOST + suffix)
        self.assertEqual(result, prefix + engine.portable_session(HOST) + suffix)

    def test_changed_or_already_patched_source_is_rejected(self):
        for source in [HOST + HOST, HOST.replace("import IOBluetooth\n", ""), engine.portable_session(HOST)]:
            with self.subTest(source=source):
                with self.assertRaises(ValueError):
                    engine.portable_session(source)

    def fixture(self, directory):
        root = Path(directory)
        source, destination = root / "vendor", root / "generated"
        (source / engine.SESSION).parent.mkdir(parents=True)
        (source / engine.SESSION).write_text(HOST)
        (source / "Other.swift").write_text("// unchanged\n")
        return source, destination

    def test_staging_is_idempotent_and_does_not_edit_vendor(self):
        with tempfile.TemporaryDirectory() as directory:
            source, destination = self.fixture(directory)
            for _ in range(2):
                engine.stage_sources(source, destination)
            self.assertEqual((source / engine.SESSION).read_text(), HOST)
            self.assertEqual((destination / engine.SESSION).read_text(), engine.portable_session(HOST))
            self.assertEqual((destination / "Other.swift").read_bytes(), (source / "Other.swift").read_bytes())

    def test_edited_output_is_preserved_and_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            source, destination = self.fixture(directory)
            engine.stage_sources(source, destination)
            path = destination / "Other.swift"
            path.write_text("user edit\n")
            with self.assertRaises(ValueError):
                engine.stage_sources(source, destination)
            self.assertEqual(path.read_text(), "user edit\n")

    def test_missing_session_fails_before_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            source, destination = self.fixture(directory)
            (source / engine.SESSION).unlink()
            with self.assertRaises(ValueError):
                engine.stage_sources(source, destination)
            self.assertFalse(destination.exists())

    def test_source_and_destination_symlinks_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            source, destination = self.fixture(directory)
            destination.symlink_to(source, target_is_directory=True)
            with self.assertRaises(ValueError):
                engine.stage_sources(source, destination)
            destination.unlink()
            (source / "link.swift").symlink_to(source / "Other.swift")
            with self.assertRaises(ValueError):
                engine.stage_sources(source, destination)

    def test_generated_engine_is_the_native_build_target(self):
        manifest = (SCRIPT.parent / "Engine/Package.swift").read_text()
        self.assertIn('path: "Generated/Switch2Kit"', manifest)
        self.assertNotIn('path: "Vendor/Switch2Kit/Sources/Switch2Kit"', manifest)


if __name__ == "__main__":
    unittest.main()
