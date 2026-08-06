# TOS Wallet for iOS

The official iOS wallet maintained by TOS Network.

TOS Wallet provides the essential native-wallet experience: create or import a
wallet, view the TOS balance, receive TOS, and sign and submit TOS transfers.
The app talks directly to a TOS JSON-RPC node and includes no analytics SDK.

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
