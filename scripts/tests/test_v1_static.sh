#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
app_path=${1:-"$project_root/build/DerivedData/Build/Products/TonkeeperDebug-iphonesimulator/TOS Wallet.app"}

fail() {
    echo "V1 acceptance failure: $1" >&2
    exit 1
}

assert_contains() {
    file=$1
    pattern=$2
    description=$3
    rg -q -- "$pattern" "$file" || fail "$description"
}

test -d "$app_path" || fail "built app is missing: $app_path"

display_name=$(plutil -extract CFBundleDisplayName raw "$app_path/Info.plist")
bundle_name=$(plutil -extract CFBundleName raw "$app_path/Info.plist")
bundle_identifier=$(plutil -extract CFBundleIdentifier raw "$app_path/Info.plist")

test "$display_name" = "TOS Wallet" || fail "CFBundleDisplayName is '$display_name'"
test "$bundle_name" = "TOS Wallet" || fail "CFBundleName is '$bundle_name'"
test "$bundle_identifier" = "network.tos.wallet" || fail "unexpected bundle identifier '$bundle_identifier'"
test ! -e "$app_path/PlugIns" || fail "V1 app embeds deferred extensions"
test -f "$app_path/PrivacyInfo.xcprivacy" || fail "V1 app is missing its privacy manifest"
plutil -lint "$app_path/PrivacyInfo.xcprivacy" >/dev/null || fail "V1 privacy manifest is malformed"
tracking=$(plutil -extract NSPrivacyTracking raw "$app_path/PrivacyInfo.xcprivacy")
test "$tracking" = "false" || fail "V1 privacy manifest enables tracking"

for forbidden_key in NSBluetoothAlwaysUsageDescription NSCameraUsageDescription NSFaceIDUsageDescription NSUserActivityTypes; do
    if plutil -extract "$forbidden_key" raw "$app_path/Info.plist" >/dev/null 2>&1; then
        fail "V1 app declares deferred metadata key $forbidden_key"
    fi
done

url_schemes=$(plutil -extract CFBundleURLTypes json -o - "$app_path/Info.plist")
printf '%s' "$url_schemes" | rg -q 'tos-tc' && fail "V1 app registers a deferred TonConnect URL scheme"

entitlements_file="$project_root/Configurations/Entitlements/Tonkeeper.entitlements"
rg -q 'aps-environment|com.apple.security.application-groups' "$entitlements_file" && fail "V1 app retains deferred push/widget entitlements"
rg -q 'keychain-access-groups' "$entitlements_file" || fail "V1 app is missing its Keychain access group"

scope_file="$project_root/LocalPackages/App/Sources/App/Shared/TOSV1Scope.swift"
assert_contains "$scope_file" 'supportsOnlyNativeTOS = true' "native-only scope is disabled"
for flag in allowsScanner allowsSwap allowsBuySell allowsStaking allowsNonNativeAssets allowsWatchOnlyWallets allowsConnectedApps allowsBiometry; do
    assert_contains "$scope_file" "${flag} = false" "$flag is enabled"
done

state_file="$project_root/LocalPackages/App/Sources/App/MainModule/Flows/MainCoordinator/MainCoordinatorStateManager.swift"
assert_contains "$state_file" 'State\(tabs: \[\.wallet, \.history\]\)' "V1 tab state is not exactly Wallet and History"

balance_file="$project_root/LocalPackages/core-swift/Sources/KeeperCore/Entities/Balance/Balance.swift"
assert_contains "$balance_file" 'static let symbol = "TOS"' "native symbol is not TOS"

project_file="$project_root/Tonkeeper.xcodeproj/project.pbxproj"
main_target=$(sed -n '/7DB8FB612A1BCC92005B4B11.*Tonkeeper.*= {/,/productType = "com.apple.product-type.application"/p' "$project_file")
printf '%s\n' "$main_target" | rg -q 'TonkeeperWidgetExtension|TonkeeperIntents' && fail "main target depends on a deferred extension"

config_file="$project_root/LocalPackages/core-swift/Sources/KeeperCore/PackageResources/DefaultRemoteConfiguration.json"
python3 - "$config_file" <<'PY'
import json
import sys
from pathlib import Path
from urllib.parse import urlparse

path = Path(sys.argv[1])
data = json.loads(path.read_text())

def walk(value):
    if isinstance(value, dict):
        for nested in value.values():
            yield from walk(nested)
    elif isinstance(value, list):
        for nested in value:
            yield from walk(nested)
    elif isinstance(value, str) and value.startswith(("http://", "https://")):
        yield value

urls = list(walk(data))
if not urls:
    raise SystemExit("V1 acceptance failure: no remote configuration URLs found")
bad = [url for url in urls if not (urlparse(url).hostname or "").endswith("tos.network")]
if bad:
    raise SystemExit("V1 acceptance failure: non-TOS remote configuration URL(s): " + ", ".join(bad))
PY

echo "V1 static and build-artifact checks passed"
