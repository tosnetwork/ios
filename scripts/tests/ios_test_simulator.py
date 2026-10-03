"""Find and boot the simulator selected by the root Makefile test destination."""

import json
import os
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
        for device in devices:
            if "id" in options:
                selected = device["udid"].lower() == options["id"].lower()
            else:
                selected = device["name"] == options.get("name")
                if "OS" in options:
                    selected &= runtime.endswith("iOS-" + options["OS"].replace(".", "-"))
            if selected:
                matches.append(device)
    if len(matches) != 1:
        raise SystemExit("Test gate requires one available simulator matching " + destination)
    return matches[0]


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
