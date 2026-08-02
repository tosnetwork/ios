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

Copyright © TOS Network.
