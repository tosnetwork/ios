#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$project_root"

fail() {
    echo "Brand boundary failure: $1" >&2
    exit 1
}

test -d TosWallet || fail "TosWallet source target is missing"
test -d TosWallet.xcodeproj || fail "TosWallet Xcode project is missing"
test ! -e Tonkeeper || fail "legacy Tonkeeper source target still exists"
test ! -e Tonkeeper.xcodeproj || fail "legacy Tonkeeper Xcode project still exists"

if rg -n -i 'tonkeeper|ton-connect|tonapi|ton-swift' .github/workflows; then
    fail "a GitHub workflow still references an upstream TON/Tonkeeper project"
fi

if rg -n --hidden \
    -g '!build/**' \
    -g '!worktrees/**' \
    -g '!.git/**' \
    'github\.com/(toswallet|tos-wallet)/(ton-swift|ton-api-swift|kit-ios|CryptoSwift|URKit|battery-api-swift|hw-transport-ios-ble)' \
    .; then
    fail "an upstream dependency was rewritten to a fictional TOS repository"
fi

rg -q 'github\.com/tonkeeper/ton-swift' LocalPackages/core-swift/Package.swift \
    || fail "the audited ton-swift upstream dependency is missing"
rg -q 'github\.com/tonkeeper/ton-api-swift' LocalPackages/core-swift/Package.swift \
    || fail "the audited TonAPI upstream dependency is missing"
rg -q 'github\.com/ton-connect/kit-ios' LocalPackages/core-swift/Package.swift \
    || fail "the audited TONWalletKit upstream dependency is missing"
rg -q 'X_hyphen_TonConnect_hyphen_Auth' LocalPackages/core-swift/Sources/KeeperCore/API/TKBatteryAPI/BatteryAPI.swift \
    || fail "the upstream TonConnect authentication header was renamed"

echo "Brand and upstream compatibility boundary passed."
