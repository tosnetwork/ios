#!/usr/bin/env python3
"""Fetch the pinned privacy SDK source and build the native mobile artifact."""

import argparse
import fcntl
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

SOURCE_URL = "https://github.com/tosnetwork/tos.git"
SOURCE_PATHS = [
    "tools/shielded-pool-mobile",
    "tools/shielded-pool-wallet",
    "tools/shielded-pool-codec",
    "tools/shielded-pool-circuit",
    "tools/shielded-pool-prover",
    "tools/shielded-pool-ceremony",
    "tools/bonded-relayer/client",
    "tools/bonded-relayer/bond-codec",
    "crypto/poseidon2",
    "crypto/smartcont",
    "tosctl/src/block",
    "tosctl/src/lockfree",
    "tosctl/src/common",
    "scripts",
]


def run(args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)


def output(args, **kwargs):
    return subprocess.check_output([str(a) for a in args], text=True, **kwargs).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=["ios", "android"], required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--abi", choices=["arm64-v8a", "armeabi-v7a", "x86", "x86_64"])
    parser.add_argument("--ndk", type=Path)
    parser.add_argument("--proving", action="store_true", help="Build the local payment prover")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    revision = (root / "scripts/privacy-native-revision.txt").read_text().strip()
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise RuntimeError("Privacy source revision must be a full commit SHA")
    if args.platform == "android" and (args.output is None or args.abi is None or args.ndk is None):
        parser.error("Android requires --output, --abi and --ndk")
    cache = root / (".native" if args.platform == "ios" else ".gradle") / "privacy-native"
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / "build.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        provided = os.environ.get("TOS_PRIVACY_SOURCE")
        source = Path(provided).resolve() if provided else cache / "source"
        if not source.exists():
            if provided:
                raise RuntimeError("Provided privacy source does not exist")
            source.mkdir()
            run(["git", "init", source])
            run(["git", "-C", source, "remote", "add", "origin", SOURCE_URL])
            run(["git", "-C", source, "sparse-checkout", "init", "--cone"])
            run(["git", "-C", source, "sparse-checkout", "set", *SOURCE_PATHS])
        if (
            Path(output(["git", "-C", source, "rev-parse", "--show-toplevel"])).resolve()
            != source.resolve()
        ):
            raise RuntimeError("Privacy source must be the checkout root")
        if output(["git", "-C", source, "status", "--porcelain"]):
            raise RuntimeError(
                "Privacy source has local changes; preserve them and use a clean checkout"
            )
        if not provided:
            run(["git", "-C", source, "sparse-checkout", "set", *SOURCE_PATHS])
        head = subprocess.run(
            ["git", "-C", str(source), "rev-parse", "--verify", "HEAD"],
            capture_output=True,
            text=True,
        )
        if head.returncode != 0 or head.stdout.strip() != revision:
            if provided:
                raise RuntimeError("Provided privacy source does not match the pinned revision")
            run(["git", "-C", source, "config", "remote.origin.promisor", "true"])
            run(["git", "-C", source, "config", "remote.origin.partialclonefilter", "blob:none"])
            run(
                [
                    "git",
                    "-C",
                    source,
                    "fetch",
                    "--filter=blob:none",
                    "--depth=1",
                    "origin",
                    revision,
                ]
            )
            run(["git", "-C", source, "checkout", "--detach", revision])
        if output(["git", "-C", source, "rev-parse", "HEAD"]) != revision:
            raise RuntimeError("Privacy source revision mismatch")
        destination = (
            args.output.resolve()
            if args.output
            else root / "LocalPackages/core-swift/Generated/TOSShielded.xcframework"
        )
        command = [
            "python3",
            source / "scripts/build-shielded-mobile.py",
            "--platform",
            args.platform,
            "--output",
            destination,
            "--target-dir",
            Path(os.environ.get("TOS_PRIVACY_TARGET_DIR", cache / "target")).resolve(),
        ]
        if args.platform == "android":
            command += ["--ndk", args.ndk.resolve(), "--abi", args.abi]
        if args.proving:
            command.append("--proving")
        run(command)
        provenance = json.loads((destination / "PROVENANCE.json").read_text())
        if provenance["source_commit"] != revision or provenance["source_dirty"]:
            raise RuntimeError("Privacy artifact was not built from the pinned clean source")
        if provenance["features"] != (["proving"] if args.proving else []):
            raise RuntimeError("Privacy artifact features do not match the requested build")
        for relative, digest in provenance["files"].items():
            path = (destination / relative).resolve()
            if (
                not path.is_relative_to(destination.resolve())
                or hashlib.sha256(path.read_bytes()).hexdigest() != digest
            ):
                raise RuntimeError("Privacy artifact hash mismatch")


if __name__ == "__main__":
    main()
