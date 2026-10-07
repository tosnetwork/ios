#!/usr/bin/env python3
"""Point application-hosted package tests at their actual embedded bundles."""

import argparse
import plistlib
from pathlib import Path


def fix(source: Path, destination: Path) -> int:
    source = source.resolve()
    destination = destination.resolve()
    if destination.parent != source.parent:
        raise ValueError("Keep the generated TESTROOT directory unchanged")
    value = plistlib.loads(source.read_bytes())
    count = 0
    for configuration in value["TestConfigurations"]:
        for target in configuration["TestTargets"]:
            if target.get("IsAppHostedTestBundle") is not True:
                continue
            name = Path(target["TestBundlePath"]).name
            if not name.endswith(".xctest"):
                raise ValueError("Expected a test bundle")
            host = Path(target["TestHostPath"].replace("__TESTROOT__", str(source.parent)))
            if not host.is_absolute() or not (host / "PlugIns" / name).is_dir():
                raise ValueError("Required embedded test bundle is absent")
            target["TestBundlePath"] = "__TESTHOST__/PlugIns/" + name
            count += 1
    if not count:
        raise ValueError("No application-hosted tests found")
    with destination.open("xb") as output:
        plistlib.dump(value, output)
    return count


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    print(f"Fixed {fix(args.source, args.destination)} hosted test bundle paths")
