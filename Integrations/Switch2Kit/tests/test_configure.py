import copy
import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "configure.py"
spec = importlib.util.spec_from_file_location("configure", SCRIPT)
configure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configure)


def fixture():
    return {"rootObject": "project", "objects": {
        "project": {"isa": "PBXProject", "targets": ["delta", "other"], "mainGroup": "group", "buildConfigurationList": "project-configs"},
        "delta": {"isa": "PBXNativeTarget", "name": "Delta", "productType": "com.apple.product-type.application", "buildPhases": ["sources", "frameworks"], "buildConfigurationList": "configs"},
        "other": {"isa": "PBXNativeTarget", "name": "DeltaPreviews", "buildConfigurationList": "other-configs"},
        "group": {"isa": "PBXGroup", "children": []},
        "sources": {"isa": "PBXSourcesBuildPhase", "files": ["existing-source"]},
        "frameworks": {"isa": "PBXFrameworksBuildPhase", "files": []},
        "configs": {"buildConfigurations": ["debug", "release"]},
        "debug": {"name": "Debug", "buildSettings": {"INFOPLIST_FILE": "Info.plist", "IPHONEOS_DEPLOYMENT_TARGET": "14.0", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": ["$(inherited)", "DEBUG", "BETA"]}},
        "release": {"name": "Release", "buildSettings": {"INFOPLIST_FILE": "$(SRCROOT)/Info.plist", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) BETA"}},
        "other-configs": {"buildConfigurations": ["preview"]},
        "preview": {"buildSettings": {"IPHONEOS_DEPLOYMENT_TARGET": "14.0"}},
        "project-configs": {"buildConfigurations": ["project-debug"]},
        "project-debug": {"name": "Debug", "buildSettings": {"IPHONEOS_DEPLOYMENT_TARGET": "14.0"}}
    }}


class ConfigureTests(unittest.TestCase):
    def test_baseline_and_other_targets_are_untouched(self):
        original = fixture()
        saved = copy.deepcopy(original)
        result = configure.make_project(original)
        self.assertEqual(original, saved)
        for key in ["other", "preview", "project-debug"]:
            self.assertEqual(result["objects"][key], original["objects"][key])
        self.assertEqual(result["objects"]["debug"]["buildSettings"]["IPHONEOS_DEPLOYMENT_TARGET"], "18.0")

    def test_preserves_existing_flags(self):
        objects = configure.make_project(fixture())["objects"]
        self.assertEqual(objects["debug"]["buildSettings"]["SWIFT_ACTIVE_COMPILATION_CONDITIONS"], ["$(inherited)", "DEBUG", "BETA", "DELTA_SWITCH2KIT"])
        self.assertEqual(objects["release"]["buildSettings"]["SWIFT_ACTIVE_COMPILATION_CONDITIONS"], "$(inherited) BETA DELTA_SWITCH2KIT")

    def test_real_sources_and_products_are_wired_once(self):
        result = configure.make_project(fixture())
        objects = result["objects"]
        self.assertEqual(len(objects["sources"]["files"]), 4)
        self.assertEqual(len(objects["frameworks"]["files"]), 3)
        self.assertEqual(len(objects["project"]["packageReferences"]), 2)
        products = {objects[key]["productName"] for key in objects["delta"]["packageProductDependencies"]}
        self.assertEqual(products, {"DeltaSwitch2Input", "Switch2Kit", "DeltaSwitch2Bridge"})
        self.assertEqual(configure.make_project(result), result)
        self.assertEqual(plistlib.loads(plistlib.dumps(result)), result)

    def test_unexpected_targets_or_identifier_collisions_fail(self):
        original = fixture()
        original["objects"]["delta"]["name"] = "Unknown"
        with self.assertRaises(ValueError):
            configure.make_project(original)
        original = fixture()
        original["objects"][configure.identifier("Switch2Kit")] = {"isa": "unexpected"}
        with self.assertRaises(ValueError):
            configure.make_project(original)

    def test_overlay_is_reversible_and_rejects_edits(self):
        original = b"original registry\n"
        overlay = b"\npublic extension registry {}\n"
        with patch.object(configure, "CORE_BLOB", configure.git_blob(original)):
            applied = configure.overlay_core(original, overlay)
            self.assertEqual(applied, original + overlay)
            self.assertEqual(configure.overlay_core(applied, overlay), applied)
            self.assertEqual(configure.overlay_core(applied, overlay, True), original)
            self.assertEqual(configure.overlay_core(original, overlay, True), original)
            for modified in [b"edited\n" + applied, applied + b"user edit", original + b"unrelated"]:
                with self.assertRaises(ValueError):
                    configure.overlay_core(modified, overlay)

    def test_generated_output_refuses_unknown_directory_or_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(ValueError):
                configure.prepare_directory(root)
            generated = root / "generated"
            configure.prepare_directory(generated)
            configure.prepare_directory(generated)
            file = generated / "test"
            configure.write_unchanged_or_new(file, b"expected")
            configure.write_unchanged_or_new(file, b"expected")
            file.write_bytes(b"user edit")
            with self.assertRaises(ValueError):
                configure.write_unchanged_or_new(file, b"expected")
            self.assertEqual(file.read_bytes(), b"user edit")

    def test_bluetooth_privacy_does_not_edit_original_plist(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = plistlib.dumps({"CFBundleName": "Delta", "ExistingKey": True})
            (root / "Info.plist").write_bytes(source)
            result = configure.make_project(fixture())
            configure.add_privacy_plists(root, result)
            self.assertEqual((root / "Info.plist").read_bytes(), source)
            for key in ["debug", "release"]:
                path = root / result["objects"][key]["buildSettings"]["INFOPLIST_FILE"]
                plist = plistlib.loads(path.read_bytes())
                self.assertIn("NSBluetoothAlwaysUsageDescription", plist)
                self.assertTrue(plist["ExistingKey"])

    def test_paths_cannot_escape_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(ValueError):
                configure.confined(root, "../outside")
            (root / "escape").symlink_to(root.parent, target_is_directory=True)
            with self.assertRaises(ValueError):
                configure.confined(root, "escape/outside")

    def test_scheme_redirect_preserves_original_and_package_resolution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shared = root / "Delta.xcodeproj/xcshareddata/xcschemes"
            shared.mkdir(parents=True)
            source = b'<BuildableReference ReferencedContainer="container:Delta.xcodeproj"/>'
            (shared / "Delta.xcscheme").write_bytes(source)
            output = root / configure.PROJECT_NAME
            configure.copy_shared(root / "Delta.xcodeproj", output, replace_project=True)
            self.assertEqual((shared / "Delta.xcscheme").read_bytes(), source)
            self.assertIn(b"container:Delta-Switch2Kit.xcodeproj", (output / "xcshareddata/xcschemes/Delta.xcscheme").read_bytes())

    def test_repository_source_contract(self):
        integration = SCRIPT.parent
        self.assertEqual(configure.CORE_REVISION, "633dfa86967816315fe19b482511dab1ce517f28")
        self.assertEqual(configure.SDK_REVISION, "6b5cba6233b21fca1020570e96b1bf247ba21f1e")
        root = integration.parents[1]
        for filename in configure.APP_SOURCES:
            self.assertTrue((root / "Delta/Emulation/Switch2" / filename).is_file())
        self.assertIn(".iOS(.v18)", (integration / "Engine/Package.swift").read_text())
        self.assertIn("Vendor/Switch2Kit/Sources/Switch2Kit", (integration / "Engine/Package.swift").read_text())


if __name__ == "__main__":
    unittest.main()
