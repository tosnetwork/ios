#!/bin/sh
set -eu

simulator_id=$(python3 scripts/tests/ios_test_simulator.py)

if [ -z "$simulator_id" ]; then
    echo 'V1 secret scan failed: no booted simulator' >&2
    exit 1
fi

log_file=$(mktemp)
phrase_patterns=$(mktemp)
trap 'rm -f "$log_file" "$phrase_patterns"' EXIT
python3 -c 'import json; data=json.load(open("LocalPackages/core-swift/Tests/KeeperCoreTests/TestData/tos-mnemonic-goldens.json")); print("\n".join("[^[:alnum:]]+".join(v["mnemonic"].split()) for v in data["vectors"]))' >"$phrase_patterns"
xcrun simctl spawn "$simulator_id" log show --last 2h --style compact \
    --predicate 'process == "TOS Wallet"' >"$log_file" 2>/dev/null

if rg -i -f "$phrase_patterns" "$log_file" >/dev/null; then
    echo 'V1 secret scan failed: fixture recovery phrase appears in app logs' >&2
    exit 1
fi
if rg -i 'passcode[^[:alnum:]]*1234|password[^[:alnum:]]*1234' "$log_file" >/dev/null; then
    echo 'V1 secret scan failed: fixture passcode appears in app logs' >&2
    exit 1
fi

pasteboard=$(xcrun simctl pbpaste "$simulator_id" 2>/dev/null)
if printf '%s' "$pasteboard" | rg -i -f "$phrase_patterns" >/dev/null; then
    echo 'V1 secret scan failed: fixture recovery phrase appears in pasteboard' >&2
    exit 1
fi

echo 'V1 runtime secret scan passed'
