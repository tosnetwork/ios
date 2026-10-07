#!/usr/bin/env python3
"""Build the source-pinned fee state core for device and both simulators."""

import plistlib
import pathlib
import hashlib
import shutil
import subprocess


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.digest()


def unchanged(frameworks, output):
    """Compare actual fresh build bytes, never an mtime or cached success stamp."""
    identifiers = ["ios-arm64", "ios-arm64_x86_64-simulator"]
    try:
        with (output / "Info.plist").open("rb") as file:
            info = plistlib.load(file)
        entries = info["AvailableLibraries"]
        if (
            info.get("CFBundlePackageType") != "XFWK"
            or info.get("XCFrameworkFormatVersion") != "1.0"
        ):
            return False
        if len(entries) != 2 or {
            entry["LibraryIdentifier"] for entry in entries
        } != set(identifiers):
            return False
        for entry in entries:
            if (
                entry["LibraryPath"] != "TOSFeeState.framework"
                or entry["SupportedPlatform"] != "ios"
            ):
                return False
            simulator = entry["LibraryIdentifier"] == identifiers[1]
            if (entry.get("SupportedPlatformVariant") == "simulator") != simulator:
                return False
            if set(entry["SupportedArchitectures"]) != (
                {"arm64", "x86_64"} if simulator else {"arm64"}
            ):
                return False
        for framework, identifier in zip(frameworks, identifiers):
            destination = output / identifier / "TOSFeeState.framework"
            expected = {
                p.relative_to(framework) for p in framework.rglob("*") if p.is_file()
            }
            actual = {
                p.relative_to(destination)
                for p in destination.rglob("*")
                if p.is_file()
            }
            if expected != actual or not expected:
                return False
            for relative in expected:
                path = destination / relative
                if path.is_symlink() or digest(framework / relative) != digest(path):
                    return False
        return True
    except (OSError, KeyError, TypeError, ValueError):
        return False


def main():
    root = pathlib.Path(__file__).resolve().parents[1]
    source = root / "Native/fee-state-bundle"
    build = root / "build/v5r2-fee-state"
    build.mkdir(parents=True, exist_ok=True)
    targets = ["aarch64-apple-ios", "aarch64-apple-ios-sim", "x86_64-apple-ios"]
    for target in targets:
        subprocess.run(
            [
                "cargo",
                "build",
                "--release",
                "--locked",
                "--target",
                target,
                "--target-dir",
                str(build / "target"),
            ],
            cwd=source,
            check=True,
        )
    simulator = build / "liblms_fee_state_sim.a"
    subprocess.run(
        [
            "xcrun",
            "lipo",
            "-create",
            str(build / "target/aarch64-apple-ios-sim/release/liblms_fee_state.a"),
            str(build / "target/x86_64-apple-ios/release/liblms_fee_state.a"),
            "-output",
            str(simulator),
        ],
        check=True,
    )
    frameworks = []
    for variant, library in [
        ("device", build / "target/aarch64-apple-ios/release/liblms_fee_state.a"),
        ("simulator", simulator),
    ]:
        framework = build / variant / "TOSFeeState.framework"
        (framework / "Headers").mkdir(parents=True, exist_ok=True)
        (framework / "Modules").mkdir(exist_ok=True)
        shutil.copyfile(library, framework / "TOSFeeState")
        shutil.copyfile(
            root / "Native/tos_fee_state.h", framework / "Headers/tos_fee_state.h"
        )
        (framework / "Modules/module.modulemap").write_text(
            'framework module TOSFeeState { umbrella header "tos_fee_state.h" export * }\n'
        )
        with (framework / "Info.plist").open("wb") as file:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "network.tos.fee-state",
                    "CFBundleName": "TOSFeeState",
                    "CFBundleExecutable": "TOSFeeState",
                    "CFBundlePackageType": "FMWK",
                    "CFBundleVersion": "1",
                    "CFBundleShortVersionString": "1.0",
                },
                file,
            )
        frameworks.append(framework)
    output = root / "LocalPackages/core-swift/Generated/TOSFeeState.xcframework"
    output.parent.mkdir(parents=True, exist_ok=True)
    if unchanged(frameworks, output):
        print("V5R2 fee XCFramework bytes unchanged; retaining existing outputs")
        return
    if output.exists():
        shutil.rmtree(output)
    subprocess.run(
        [
            "xcodebuild",
            "-create-xcframework",
            "-framework",
            str(frameworks[0]),
            "-framework",
            str(frameworks[1]),
            "-output",
            str(output),
        ],
        check=True,
    )


if __name__ == "__main__":
    main()
