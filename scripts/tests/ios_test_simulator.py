"""Find and boot the simulator selected by the root Makefile test destination."""

import json
import os
import re
import subprocess
import sys


def selected_simulator():
    destination = os.environ.get("TOS_TEST_DESTINATION", "platform=iOS Simulator,name=iPhone 17")
    options = dict(item.split("=", 1) for item in destination.split(",") if "=" in item)
    result = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        check=True, capture_output=True, text=True,
    )
    matches = []
    for runtime, devices in json.loads(result.stdout)["devices"].items():
        runtime_match = re.search(r"iOS-(\d+(?:-\d+)*)$", runtime)
        if not runtime_match:
            continue
        runtime_version = tuple(int(value) for value in runtime_match[1].split("-"))
        for device in devices:
            if "id" in options:
                selected = device["udid"].lower() == options["id"].lower()
            else:
                selected = device["name"] == options.get("name")
                if options.get("OS") not in (None, "latest"):
                    selected &= runtime.endswith("iOS-" + options["OS"].replace(".", "-"))
            if selected:
                matches.append((runtime_version, device))
    if matches and "id" not in options and options.get("OS") in (None, "latest"):
        # Xcode's name-only destination selects the newest available runtime.
        newest = max(version for version, _ in matches)
        matches = [(version, device) for version, device in matches if version == newest]
    if len(matches) != 1:
        raise SystemExit("Test gate requires one available simulator matching " + destination)
    return matches[0][1]


def prepare_simulator():
    device = selected_simulator()
    if device["state"] == "Shutdown":
        subprocess.run(["xcrun", "simctl", "boot", device["udid"]], check=True, capture_output=True)
    subprocess.run(["xcrun", "simctl", "bootstatus", device["udid"], "-b"], check=True, capture_output=True)
    return device


if __name__ == "__main__":
    if sys.argv[1:] == ["--shutdown"]:
        device = selected_simulator()
        if device["state"] != "Shutdown":
            subprocess.run(["xcrun", "simctl", "shutdown", device["udid"]], check=True)
    else:
        print(prepare_simulator()["udid"])
