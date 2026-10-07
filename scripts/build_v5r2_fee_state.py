#!/usr/bin/env python3
"""Build the source-pinned fee state core for device and both simulators."""

import plistlib
import pathlib
import shutil
import subprocess


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
