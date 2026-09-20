#!/usr/bin/env python3
"""Create an opt-in iOS 18 workspace without rewriting Delta's normal project.

Run on macOS after initializing submodules. The DeltaCore overlay is an exact,
reversible same-file API extension; dirty/unexpected dependency sources fail
closed. --restore-core removes only this script's unchanged overlay.
"""
from __future__ import annotations
import argparse
import copy
import hashlib
import plistlib
import subprocess
from pathlib import Path

SDK_REVISION = "6b5cba6233b21fca1020570e96b1bf247ba21f1e"
CORE_REVISION = "633dfa86967816315fe19b482511dab1ce517f28"
CORE_BLOB = "740102e4e0a4052014d1b9e123822a41e8521a45"
SDK_PATH = "Integrations/Switch2Kit/Engine/Vendor/Switch2Kit"
CORE_SOURCE = "Cores/DeltaCore/DeltaCore/Game Controllers/ExternalGameControllerManager.swift"
PROJECT_NAME = "Delta-Switch2Kit.xcodeproj"
WORKSPACE_NAME = "Delta-Switch2Kit.xcworkspace"
APP_SOURCES = ["Switch2GameController.swift", "Switch2ControllerService.swift", "Switch2ControllersView.swift"]
GENERATED = "Integrations/Switch2Kit/Generated"
MARKER = b"Delta Switch2Kit generated workspace v1\n"


def git_blob(data: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def overlay_core(original: bytes, overlay: bytes, restore: bool = False) -> bytes:
    if git_blob(original) == CORE_BLOB:
        return original if restore else original + overlay
    if original.endswith(overlay) and git_blob(original[:-len(overlay)]) == CORE_BLOB:
        return original[:-len(overlay)] if restore else original
    raise ValueError("DeltaCore controller registry differs from the pinned source; refusing to overwrite it.")


def identifier(label: str) -> str:
    return hashlib.sha256(("DeltaSwitch2Kit:" + label).encode()).hexdigest()[:24].upper()


def make_project(source: dict) -> dict:
    """Pure, deterministic project transform; the input dictionary is untouched."""
    project = copy.deepcopy(source)
    objects = project["objects"]
    root = objects[project["rootObject"]]
    targets = [objects[key] for key in root["targets"] if objects[key].get("name") == "Delta"]
    if len(targets) != 1:
        raise ValueError("Expected exactly one Delta application target")
    target = targets[0]
    if target.get("productType") != "com.apple.product-type.application":
        raise ValueError("Delta target is not an application")

    def add(label: str, value: dict) -> str:
        key = identifier(label)
        if key in objects and objects[key] != value:
            raise ValueError(f"Generated project identifier collision: {label}")
        objects[key] = value
        return key

    def append_unique(array: list, item: str) -> None:
        if item not in array:
            array.append(item)

    def phase(isa: str) -> dict:
        matches = [objects[key] for key in target["buildPhases"] if objects[key]["isa"] == isa]
        if len(matches) != 1:
            raise ValueError(f"Expected one {isa}")
        return matches[0]

    for package_path, products in [
        ("Integrations/Switch2Kit", ["DeltaSwitch2Input"]),
        ("Integrations/Switch2Kit/Engine", ["Switch2Kit", "DeltaSwitch2Bridge"]),
    ]:
        package = add(package_path, {"isa": "XCLocalSwiftPackageReference", "relativePath": package_path})
        append_unique(root.setdefault("packageReferences", []), package)
        for product in products:
            dependency = add(product, {"isa": "XCSwiftPackageProductDependency", "package": package, "productName": product})
            append_unique(target.setdefault("packageProductDependencies", []), dependency)
            build = add(product + " framework", {"isa": "PBXBuildFile", "productRef": dependency})
            append_unique(phase("PBXFrameworksBuildPhase").setdefault("files", []), build)

    files = []
    for filename in APP_SOURCES:
        reference = add(filename, {"isa": "PBXFileReference", "lastKnownFileType": "sourcecode.swift",
                                  "path": "Delta/Emulation/Switch2/" + filename, "sourceTree": "SOURCE_ROOT"})
        files.append(reference)
        build = add(filename + " source", {"isa": "PBXBuildFile", "fileRef": reference})
        append_unique(phase("PBXSourcesBuildPhase")["files"], build)
    group = add("source group", {"isa": "PBXGroup", "children": files, "name": "Switch2Kit", "sourceTree": "<group>"})
    append_unique(objects[root["mainGroup"]]["children"], group)

    for key in objects[target["buildConfigurationList"]]["buildConfigurations"]:
        settings = objects[key].setdefault("buildSettings", {})
        settings["IPHONEOS_DEPLOYMENT_TARGET"] = "18.0"
        flags = settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "$(inherited)")
        if isinstance(flags, list):
            if "DELTA_SWITCH2KIT" not in flags:
                flags.append("DELTA_SWITCH2KIT")
        elif "DELTA_SWITCH2KIT" not in flags.split():
            flags += " DELTA_SWITCH2KIT"
        settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = flags
    return project


def read_plist(path: Path) -> dict:
    data = path.read_bytes()
    try:
        return plistlib.loads(data)
    except plistlib.InvalidFileException:
        result = subprocess.run(["plutil", "-convert", "xml1", "-o", "-", str(path)], check=True, capture_output=True)
        return plistlib.loads(result.stdout)


def confined(root: Path, relative: str) -> Path:
    path = root / relative
    if not path.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"Path leaves checkout: {relative}")
    return path


def prepare_directory(path: Path) -> None:
    marker = path / ".delta-switch2kit-generated"
    if path.exists():
        if not marker.is_file() or marker.read_bytes() != MARKER:
            raise ValueError(f"Refusing to overwrite unrecognized directory: {path}")
    else:
        path.mkdir(parents=True)
        marker.write_bytes(MARKER)


def write_unchanged_or_new(path: Path, content: bytes) -> None:
    if path.is_symlink():
        raise ValueError(f"Refusing to follow output symlink: {path}")
    if path.exists() and path.read_bytes() != content:
        raise ValueError(f"Generated file was changed: {path}. Move the generated directory aside and configure again.")
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        path.write_bytes(content)


def add_privacy_plists(root: Path, project: dict) -> None:
    objects = project["objects"]
    project_object = objects[project["rootObject"]]
    target = next(objects[key] for key in project_object["targets"] if objects[key].get("name") == "Delta")
    project_configs = {
        objects[key]["name"]: objects[key].get("buildSettings", {})
        for key in objects[project_object["buildConfigurationList"]]["buildConfigurations"]
    }
    for key in objects[target["buildConfigurationList"]]["buildConfigurations"]:
        config = objects[key]
        settings = config["buildSettings"]
        source = settings.get("INFOPLIST_FILE", project_configs.get(config["name"], {}).get("INFOPLIST_FILE"))
        if not isinstance(source, str):
            raise ValueError("Expected an explicit Delta Info.plist path")
        source = source.strip('"').replace("$(SRCROOT)/", "").replace("$(PROJECT_DIR)/", "")
        if "$" in source:
            raise ValueError(f"Unresolved Info.plist build variable: {source}")
        plist = read_plist(confined(root, source))
        plist["NSBluetoothAlwaysUsageDescription"] = "Delta uses Bluetooth to connect to your Nintendo Switch 2 controllers."
        destination = f"{GENERATED}/Info-{key}.plist"
        write_unchanged_or_new(confined(root, destination), plistlib.dumps(plist, sort_keys=False))
        settings["INFOPLIST_FILE"] = destination


def copy_shared(source: Path, destination: Path, replace_project: bool = False) -> None:
    shared = source / "xcshareddata"
    if not shared.exists():
        return
    for path in sorted(shared.rglob("*")):
        if not path.is_file():
            continue
        if path.is_symlink():
            raise ValueError(f"Unexpected shared-data symlink: {path}")
        content = path.read_bytes()
        if replace_project and path.suffix == ".xcscheme":
            content = content.replace(b"container:Delta.xcodeproj", ("container:" + PROJECT_NAME).encode())
        output = destination / path.relative_to(source)
        # Xcode owns a generated workspace's package lock after initial creation.
        # Preserve its resolved state on subsequent configure invocations.
        if path.name == "Package.resolved" and output.exists():
            continue
        write_unchanged_or_new(output, content)


def check_revision(root: Path, path: str, expected: str) -> None:
    result = subprocess.run(["git", "-C", str(root / path), "rev-parse", "HEAD"], check=True, capture_output=True, text=True)
    if result.stdout.strip() != expected:
        raise ValueError(f"Initialize {path} at pinned revision {expected}")


def configure(root: Path, restore: bool = False) -> None:
    core_path = confined(root, CORE_SOURCE)
    overlay = (root / "Integrations/Switch2Kit/DeltaCoreRegistration.swift.inc").read_bytes()
    original_core = core_path.read_bytes()
    updated_core = overlay_core(original_core, overlay, restore)
    if restore:
        if updated_core != original_core:
            core_path.write_bytes(updated_core)
        print("Restored the pinned DeltaCore registry; normal Delta project is unchanged.")
        return
    check_revision(root, "Cores/DeltaCore", CORE_REVISION)
    check_revision(root, SDK_PATH, SDK_REVISION)
    sdk_changes = subprocess.run(["git", "-C", str(root / SDK_PATH), "status", "--porcelain", "--untracked-files=no"], check=True, capture_output=True, text=True)
    if sdk_changes.stdout.strip():
        raise ValueError("Switch2Kit has tracked changes; refusing to label an altered engine as the pinned source")

    project = make_project(read_plist(root / "Delta.xcodeproj/project.pbxproj"))
    for relative in [PROJECT_NAME, WORKSPACE_NAME, GENERATED]:
        prepare_directory(confined(root, relative))
    add_privacy_plists(root, project)
    write_unchanged_or_new(root / PROJECT_NAME / "project.pbxproj", plistlib.dumps(project, sort_keys=False))
    copy_shared(root / "Delta.xcodeproj", root / PROJECT_NAME, replace_project=True)
    original_workspace = (root / "Delta.xcworkspace/contents.xcworkspacedata").read_bytes()
    if b"group:Delta.xcodeproj" not in original_workspace:
        raise ValueError("Original workspace no longer references Delta.xcodeproj")
    write_unchanged_or_new(root / WORKSPACE_NAME / "contents.xcworkspacedata",
                           original_workspace.replace(b"group:Delta.xcodeproj", ("group:" + PROJECT_NAME).encode()))
    copy_shared(root / "Delta.xcworkspace", root / WORKSPACE_NAME)
    # Modify the dependency only after project generation has succeeded.
    if updated_core != original_core:
        core_path.write_bytes(updated_core)
    print(f"Open {WORKSPACE_NAME}. Only this generated application target requires iOS 18.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--restore-core", action="store_true")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    try:
        configure(args.root.resolve(), args.restore_core)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Switch2Kit configuration failed: {error}\n")


if __name__ == "__main__":
    main()
