"""Exercise the real build wrapper with an argv-recording compiler double.

These tests check command selection and failure propagation, not compilation.
The two native CI steps run the same wrapper using the real Xcode toolchain.
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "build-app.sh"


class BuildAppTests(unittest.TestCase):
    def invoke(self, platform, status=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "Integrations/Switch2Kit/build-app.sh"
            script.parent.mkdir(parents=True)
            shutil.copyfile(SCRIPT, script)
            bin_path = root / "bin"
            bin_path.mkdir()
            compiler = bin_path / "xcodebuild"
            compiler.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
Path("argv.json").write_text(json.dumps(sys.argv[1:]))
status = int(os.environ["BUILD_FIXTURE_STATUS"])
print("error: fixture compilation failed" if status else "BUILD SUCCEEDED")
sys.exit(status)
''')
            compiler.chmod(0o755)
            env = dict(os.environ, PATH=str(bin_path) + os.pathsep + os.environ["PATH"],
                       BUILD_FIXTURE_STATUS=str(status))
            result = subprocess.run(["bash", str(script), platform], env=env,
                                    text=True, capture_output=True, timeout=15)
            args = json.loads((root / "argv.json").read_text()) if (root / "argv.json").exists() else None
            logs = {p.name: p.read_text() for p in (root / "build").glob("*.log")}
            return result, args, logs

    def test_simulator_builds_complete_arm64_application(self):
        result, args, logs = self.invoke("simulator")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args[args.index("-workspace") + 1], "Delta-Switch2Kit.xcworkspace")
        self.assertEqual(args[args.index("-scheme") + 1], "Delta")
        self.assertEqual(args[args.index("-destination") + 1], "generic/platform=iOS Simulator")
        self.assertIn("ARCHS=arm64", args)
        self.assertIn("ONLY_ACTIVE_ARCH=YES", args)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", args)
        self.assertEqual(args[-1], "build")
        self.assertIn("switch2kit-simulator-app.log", logs)

    def test_device_build_uses_real_ios_destination(self):
        result, args, logs = self.invoke("device")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args[args.index("-destination") + 1], "generic/platform=iOS")
        self.assertIn("ARCHS=arm64", args)
        self.assertIn("switch2kit-device-app.log", logs)

    def test_simulator_compiler_failure_remains_failure(self):
        result, _, logs = self.invoke("simulator", status=65)
        self.assertEqual(result.returncode, 65)
        self.assertIn("fixture compilation failed", result.stdout)
        self.assertIn("fixture compilation failed", logs["switch2kit-simulator-app.log"])

    def test_device_compiler_failure_remains_failure(self):
        result, _, logs = self.invoke("device", status=23)
        self.assertEqual(result.returncode, 23)
        self.assertIn("fixture compilation failed", logs["switch2kit-device-app.log"])

    def test_invalid_destination_does_not_invoke_compiler(self):
        result, args, _ = self.invoke("invalid")
        self.assertEqual(result.returncode, 64)
        self.assertIsNone(args)


if __name__ == "__main__":
    unittest.main()
