# TOS iOS Wallet V1 Acceptance Test Report

- Test date: 2026-08-06
- Matrix: `docs/ios-product-test-matrix.md`
- Environment: Xcode 26.3, iPhone 17 simulator on iOS 26.5
- Network: local three-validator TOS network at `http://127.0.0.1:18545`
- Branch under test: `codex/execute-v1-acceptance`

## Release decision

**Not ready for a 100% automated acceptance claim.** All automated suites listed below pass, and the V1 scope defects found during this run were fixed. The revised matrix contains only tests that this host can execute autonomously, but several deterministic fixtures and automated end-to-end cases have not been implemented yet.

## Automated results

| Suite | Result | Evidence |
| --- | --- | --- |
| Full simulator build | Passed | `make compile`; 129-target graph; no embedded Widget or Intents extension |
| Unsigned generic-device release archive | Passed | `make archive_v1_release`; `TonkeeperRelease`; `Archive Succeeded` |
| iOS UI tests | Passed | 6 tests, 0 failures; 98.126 seconds in the latest full run |
| WalletCore/CoreComponents | Passed | 80 KeeperCore XCTest cases, 0 failures; other WalletCore and Swift Testing suites also pass |
| Local TOS RPC integration | Passed | 2 live tests against the three-node network, 0 failures |
| TronSwift package regression | Passed | All discovered package tests passed |
| TKCryptoKit package regression | Passed | 2 tests, 0 failures |
| TKCore package regression | Passed | 1 test, 0 failures |
| TKLocalize package regression | Passed | 1 test, 0 failures |
| TKChart package regression | Passed | 1 test, 0 failures |

The UI suite verifies isolated clean-state TOS onboarding, wallet creation through wallet home, process termination and passcode-protected relaunch, import navigation to recovery-phrase entry, and absence of inherited home/import options such as Swap, Buy, Stake, Browser, Collectibles, Watch-only, Ledger, Signer, Keystone, Testnet, and TRON.

## Defects found and fixed

| Defect | Severity | Resolution |
| --- | --- | --- |
| Home exposed Scan, Swap, Buy, and Stake | P0 | Native V1 header now exposes only Send and Receive |
| Asset list rendered Jetton, staking, TRC20, and Ethena balances | P0 | V1 balance mapper now renders only native TOS |
| Add/import wallet exposed inherited wallet types | P0 | Restricted to native wallet create and recovery-phrase import |
| Settings exposed TRON, Battery, connected apps, and unsupported wallet/app options | P0 | Settings reduced to backup, TOS RPC node, delete wallet, and legal entries |
| Receive screen could expose TRC20 | P0 | Receive token source is filtered to native TOS |
| Unsupported deep links opened legacy modules | P0 | App navigation rejects Jetton/raw transfers, Swap, staking, buy/sell, DApp, TonConnect, Battery, stories, and external-signing routes |
| V1 import accepted legacy/BIP39 phrases without the native TOS checksum | P0 | Creation and import now require exactly 24 native-checksummed words; regression vectors pass |
| Saved tab state could restore Browser or Collectibles | P0 | Tab restoration now accepts only V1-enabled tabs |
| Main V1 navigation omitted the required History tab | P0 | Main state now exposes exactly Wallet and History; the static gate prevents regression |
| History exposed the inherited Spam entry | P1 | Removed from the V1 history tabs |
| Widget and App Intents extensions were embedded in the V1 app | P1 | Removed both extension dependencies and the embed phase from the main app target |
| Malformed RPC JSON leaked an unstable Foundation parsing error | P1 | Mapped malformed envelopes to stable `TOSRPCClient.invalidResponse` and added regression coverage |
| V1 bundle retained TonConnect schemes, Widget activities, deferred permission copy, push, and App Group metadata | P1 | Removed deferred metadata and added build-artifact regression checks |
| Wallet creation failure was silent after customization | P1 | Creation errors now present an actionable alert; the successful create-and-relaunch path is covered by UI automation |

## Remaining acceptance gaps

The matrix remains the authority for every uncovered row. The largest gaps are full create/import completion into a deterministic funded wallet, app-driven native TOS send/broadcast/confirmation/history verification, lifecycle and fault-injection scenarios, simulator Keychain inspection, automated accessibility-tree checks, performance budgets, and unsigned release-artifact inspection.

These rows are not marked passed merely because a lower-layer RPC or build test passed. Physical-device, TestFlight, distribution-signing, and other human/external checks are explicitly excluded from the automated matrix and its completion percentage.
