# TOS Wallet for iOS

The official iOS wallet maintained by TOS Network.

TOS Wallet provides the essential native-wallet experience: create or import a
wallet, view the TOS balance, receive TOS, and sign and submit TOS transfers.
The app talks directly to a TOS JSON-RPC node and includes no analytics SDK.

New wallets use TOS SDK compatible recovery phrases, the current TOS V5 contract,
and Ed25519 signing, including the
separate signed network ID required by TOS anti-replay protection. Creation and
import discover ConfigParam 19 from the selected node and persist that identity;
ConfigParam 8 must report VM version 6 or newer. Sending rechecks identity and
capability against the same node used for submission. Existing wallet
revisions retain their original keys, addresses, and serialization. Legacy TON
phrases require an explicit recovery choice; phrases valid in both domains
require a format selection. A reachable TOS
node is required when creating or importing the current wallet revision. Use
“Configure TOS Node” on the welcome screen to set an endpoint before onboarding.

Post-quantum validator consensus is compatible with these Ed25519 user wallets.
This app does not create ML-DSA or experimental Falcon user-wallet keys. PQ user
wallets require a separate signing and funded relay flow; they are not enabled by
this update.

## Build and test

Requirements: macOS, Xcode 26 or newer, and an installed iOS Simulator runtime.

```sh
make compile
make test_keeper_core
```

Debug builds use `http://127.0.0.1:18545` by default. Override the node for a
debug launch with `TOS_RPC_URL`. Release builds use `https://rpc.tos.network`.

## Upstream attribution

TOS Wallet is a modified fork of the open-source
[Tonkeeper iOS](https://github.com/tonkeeper/ios) project. We are grateful to
the Tonkeeper maintainers and contributors whose work provided the original
foundation for this repository.

TOS Wallet is independently maintained by TOS Network and is not affiliated
with, endorsed by, or sponsored by Tonkeeper. Product names and trademarks
belong to their respective owners. See [NOTICE.md](NOTICE.md) for provenance
and modification details.

This repository is distributed under the GNU General Public License v3.0; see
[LICENSE](LICENSE). Copyright in upstream portions remains with their
respective copyright holders. Copyright in TOS-specific modifications © TOS
Network and its contributors.
