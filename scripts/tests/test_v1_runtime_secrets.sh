#!/bin/sh
set -eu

fixture_phrase='usage vital faculty evoke fossil blush upon exotic bright chimney bargain bone club visit robust wrestle trophy melt twelve gallery shuffle auction apart exotic'
simulator_id=$(xcrun simctl list devices booted -j | plutil -extract devices xml1 -o - - | sed -n 's/.*<key>\([^<]*\)<\/key>.*/\1/p' | head -1)

if [ -z "$simulator_id" ]; then
    echo 'V1 secret scan failed: no booted simulator' >&2
    exit 1
fi

log_file=$(mktemp)
trap 'rm -f "$log_file"' EXIT
xcrun simctl spawn "$simulator_id" log show --last 2h --style compact \
    --predicate 'process == "TOS Wallet"' >"$log_file" 2>/dev/null || true

if rg -F "$fixture_phrase" "$log_file" >/dev/null; then
    echo 'V1 secret scan failed: fixture recovery phrase appears in app logs' >&2
    exit 1
fi
if rg -i 'passcode[^[:alnum:]]*1234|password[^[:alnum:]]*1234' "$log_file" >/dev/null; then
    echo 'V1 secret scan failed: fixture passcode appears in app logs' >&2
    exit 1
fi

pasteboard=$(xcrun simctl pbpaste "$simulator_id" 2>/dev/null || true)
if printf '%s' "$pasteboard" | rg -F "$fixture_phrase" >/dev/null; then
    echo 'V1 secret scan failed: fixture recovery phrase appears in pasteboard' >&2
    exit 1
fi

echo 'V1 runtime secret scan passed'
