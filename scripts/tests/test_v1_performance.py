#!/usr/bin/env python3
"""Fail the simulator release gate when launch or resident-memory budgets regress."""

import json
import statistics
import subprocess
import time
from pathlib import Path

BUNDLE_ID = "network.tos.wallet"
MAX_LAUNCH_SECONDS = 5.0
MAX_RSS_KIB = 512 * 1024


def run(*args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True)


devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j").stdout)["devices"]
available = [device for runtime in devices.values() for device in runtime]
booted = [device for device in available if device["state"] == "Booted"]
device = booted[0] if booted else next(
    (candidate for candidate in available if candidate["name"] == "iPhone 17"),
    available[0] if available else None,
)
if device is None:
    raise SystemExit("V1 performance gate failed: no available simulator")
udid = device["udid"]
if device["state"] != "Booted":
    run("xcrun", "simctl", "boot", udid)
    run("xcrun", "simctl", "bootstatus", udid, "-b")

app_candidates = sorted(Path("build/DerivedData-tests/TOSWalletUITests/Build/Products").glob("*-iphonesimulator/TOS Wallet.app"))
if not app_candidates:
    raise SystemExit("V1 performance gate failed: built simulator app not found")
run("xcrun", "simctl", "install", udid, str(app_candidates[-1]))

launch_times = []
rss_values = []
for _ in range(3):
    run("xcrun", "simctl", "terminate", udid, BUNDLE_ID, check=False)
    started = time.monotonic()
    result = run("xcrun", "simctl", "launch", udid, BUNDLE_ID)
    launch_times.append(time.monotonic() - started)
    pid = int(result.stdout.strip().rsplit(":", 1)[-1])
    time.sleep(1)
    rss = run("ps", "-o", "rss=", "-p", str(pid))
    rss_values.append(int(rss.stdout.strip()))

worst_launch = max(launch_times)
worst_rss = max(rss_values)
if worst_launch > MAX_LAUNCH_SECONDS:
    raise SystemExit(f"V1 launch budget exceeded: {worst_launch:.3f}s > {MAX_LAUNCH_SECONDS:.1f}s")
if worst_rss > MAX_RSS_KIB:
    raise SystemExit(f"V1 memory budget exceeded: {worst_rss} KiB > {MAX_RSS_KIB} KiB")

print(
    "V1 performance gate passed: "
    f"launch mean={statistics.mean(launch_times):.3f}s max={worst_launch:.3f}s; "
    f"RSS max={worst_rss / 1024:.1f} MiB"
)
