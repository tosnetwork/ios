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
Settings → PQ Wallets also creates separate ML-DSA-44 and experimental
Falcon-512 padded identities, with protected seed storage, encrypted backup and a
funded native fee-wallet transport. See [PQ signing and local validation](docs/mobile-pq-signing-20261004.md)
for protocol profiles, tests and physical-device/production release gates.

## Privacy wallet

The dedicated Privacy Wallet screen can show the shielded TOS balance for a
verified pool, deposit ordinary TOS into that pool, and prepare and submit
private transfers through a configured Tor relayer. The app reviews the
recipient and quote before submission and can resume a persisted payment request.
Development builds with privacy proving enabled also provide withdrawals through
the configured Tor relayer. Enter an ordinary workchain-0 address (friendly or raw format) and the withdrawal
amount on the privacy screen. Review
the full recipient, pool fee read from verified chain state, and relay fee before
confirming. The ordinary payout address and amount are public on chain; Tor
protects the connection to the relayer. Balance synchronization uses the configured
RPC separately. Retry pending payments to recover the original submitted request.
This change is not included in the existing v1.0.5 release artifacts.

Both platforms have exercised the Tor payment flow and restart recovery in
isolated simulator or emulator environments. Production relayer availability
and real-network acceptance remain separate validation steps.

## Releases

Version tags and release notes are available on [GitHub Releases](https://github.com/tosnetwork/ios/releases).
This repository's GitHub release process publishes source and release notes.
To build the app locally, use the Xcode build steps below.

## Build and test

Use macOS with Xcode 26 or newer, an installed iOS Simulator runtime, and
the native build dependencies listed in the [iOS CI workflow](.github/workflows/ci.yml).

```sh
make compile
make test_all
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
