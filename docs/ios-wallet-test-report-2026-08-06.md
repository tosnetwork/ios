# TOS iOS Wallet Automated Test Report

> The product-wide coverage status is maintained in [`ios-product-test-matrix.md`](ios-product-test-matrix.md). “100%” in this report means only that the limited test set defined for this run was fully executed.

- Date: 2026-08-06 (Asia/Tokyo)
- Branch used for the run: `codex/ios-wallet-full-test`
- iOS environment: Xcode iOS Simulator, `TOS Wallet QA`
- TOS environment: three local validator nodes; JSON-RPC at `http://127.0.0.1:18545`

## Result

The test set defined for this run was executed completely and passed with no unresolved product defects. The three-node network continued producing blocks with zero reported sync lag.

This result is not 100% product or code coverage. Mainnet, real fiat providers, hardware wallets, physical-device biometric behavior, and functionality not listed below were outside this run.

## Executed scope

| Area | Automated verification | Result |
| --- | --- | --- |
| Three-node network | Validator startup, `/readyz`, block production, masterchain query | Passed |
| On-chain funds | Active funded faucet and a demo transfer yielding `4.999999 TOS` | Passed |
| iOS RPC client | Account query, masterchain progress, invalid-address error propagation | 2/2 passed |
| Create-wallet UI | Entry point, numeric keypad, passcode confirmation, arrival at backup introduction | Passed |
| Import-wallet UI | Entry point, Existing Wallet option, recovery-phrase screen, Paste/Continue controls | Passed |
| Onboarding UI | Product identity, create/import actions, Terms of Use link | Passed |
| WalletCore | CoreComponents, KeeperCore, WalletCore, and signing-related tests | Passed |
| Other packages | TronSwift, TKCryptoKit, TKCore, TKLocalize, and TKChart | Passed |

Final UI result: three tests, zero failures.

## Defects found and fixed

1. **Obsolete fiat endpoint requested on first launch**
   - The app requested `https://api.tos.network/fiat/methods` before that data was needed.
   - Startup preloading of `BuySellProvider` was removed.
   - Clean-launch and onboarding UI regression tests passed.

2. **Structured JSON-RPC errors were lost for HTTP 422 responses**
   - The client rejected the HTTP status before decoding the node error envelope.
   - It now decodes JSON-RPC errors before applying generic non-2xx handling.
   - Mocked HTTP 422 and live three-node invalid-address tests passed.

3. **Onboarding and secure-keyboard controls lacked reliable accessibility semantics**
   - Interactive elements appeared as generic elements to VoiceOver/XCUITest.
   - Stable identifiers, labels, and button traits were added.
   - All three end-to-end UI tests passed.

## Reproduction commands

```sh
make test_all TEST_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro,OS=latest'
make test_tos_live TEST_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro,OS=latest'
make test_ui TEST_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro,OS=latest'
```

## Non-blocking risks

Third-party packages including BigInt, Kingfisher, swift-collections, swift-http-types, and TONWalletKit emit Swift 6 compatibility or deprecation warnings. They did not fail this run, but should be upgraded or patched before enabling stricter Swift 6 diagnostics.
