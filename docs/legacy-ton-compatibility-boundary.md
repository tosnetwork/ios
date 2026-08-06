# Legacy TON Compatibility Boundary

## Purpose

TOS Wallet is the product and first-party brand. Some upstream packages and wire protocols still use TON-era names. Those names are retained only when changing them would break dependency resolution, cryptographic compatibility, serialized data, deep links, or remote services.

## First-party naming

The application project, schemes, targets, configuration files, extensions, source namespaces, bundle metadata, logs, analytics ownership, and user-facing copy use `TosWallet` or `TOS Wallet`.

New first-party APIs must not introduce `Tonkeeper` branding. New native-chain business concepts should use `TOS` naming.

## Approved upstream compatibility names

The following names are external identities and remain unchanged until their implementations are replaced or maintained as TOS-owned forks:

- `TonSwift` and the `ton-swift` repository: address, key, cell, BOC, mnemonic, and wallet-contract primitives.
- `TonAPI` and `TonStreamingAPI`: legacy generated API clients and models that have not yet been replaced by native TOS JSON-RPC models.
- `TONWalletKit` and TonConnect protocol types: third-party DApp connectivity.
- `TonTransport`: the existing Ledger transport product.
- `X-TonConnect-Auth`, TonConnect request names, and serialized protocol keys: remote wire compatibility.
- GitHub organizations, package URLs, service hosts, historical deep-link schemes, and serialized configuration keys owned by upstream systems.

These names must not be cosmetically replaced. A rename is allowed only together with a real fork, protocol migration, or compatibility adapter backed by tests.

## Dependency boundary

External packages are declared in `LocalPackages/core-swift/Package.swift` and `LocalPackages/Ledger/Package.swift`. Product targets consume the local `WalletCore` and `Ledger` packages; dependency URLs are never rewritten to fictional TOS repositories.

Native TOS JSON-RPC remains the preferred path for V1 account balance, native transfer, broadcast, and history. Legacy APIs must not become a new source of V1 product behavior.

## Removal path

1. Replace remaining TonAPI response models with TOS-owned domain models.
2. Remove deferred Jetton, NFT, staking, battery, and DApp paths from the V1 dependency graph where practical.
3. Fork cryptographic or protocol libraries only when TOS is ready to own security review, releases, and upstream synchronization.
4. Remove an allowlisted legacy name only after its replacement passes unit, integration, and acceptance tests.

Run `make test_brand_boundary` after changing package manifests, compatibility fields, or product naming.
