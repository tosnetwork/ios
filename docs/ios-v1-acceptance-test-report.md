# TOS iOS Wallet V1 Acceptance Test Report

- Test date: 2026-08-07
- Matrix: `docs/ios-product-test-matrix.md`
- Environment: Xcode 26.3, iPhone 17 simulator on iOS 26.5
- Network: local three-validator TOS network at `http://127.0.0.1:18545`
- Branch under test: `codex/execute-v1-acceptance`

## Release decision

**Passed: ready for the V1 100% automated acceptance claim defined by the matrix.** All 105 machine-executable requirements are `Passed`. Human-, physical-device-, distribution-, and TestFlight-dependent activities remain intentionally excluded from this claim.

## Automated results

| Suite | Result | Evidence |
| --- | --- | --- |
| Full simulator build | Passed | `make compile`; 129-target graph; no embedded Widget or Intents extension |
| Unsigned generic-device release archive | Passed | `make archive_v1_release`; `TosWalletRelease`; `Archive Succeeded` |
| V1 static/build-artifact gate | Passed | Main app privacy manifest is embedded and linted; tracking is disabled; deferred extensions, permissions, schemes, and entitlements are rejected |
| iOS UI tests | Passed | 41 tests, 0 failures; 2,656.049 seconds |
| WalletCore/CoreComponents | Passed | `make test_all`; all discovered native mapper, client, storage, formatter, mnemonic, and regression suites passed |
| Local TOS RPC integration | Passed | 5 live tests against three validator RPC views, including transfer convergence and exact pagination |
| TronSwift package regression | Passed | All discovered package tests passed |
| TKCryptoKit package regression | Passed | 2 tests, 0 failures |
| TKCore package regression | Passed | 1 test, 0 failures |
| TKLocalize package regression | Passed | 1 test, 0 failures |
| TKChart package regression | Passed | 1 test, 0 failures |
| Multi-destination layout/contrast | Passed | iPhone 17e and iPhone 17 Pro Max; light/dark appearance and encoded dynamic-type sizes |
| Runtime secret scan | Passed | No fixture recovery phrase or passcode/password pattern in TOS Wallet logs or simulator pasteboard |
| Performance budget | Passed | Three cold launches; latest maximum 0.216 seconds and 273.5 MiB RSS, within 5-second/512-MiB budgets |

The UI suite covers clean-state onboarding; create/import, backup and recovery phrase challenges; passcode and persistence; native balance/receive/send/history; exact confirmation and event details; local-chain incoming/outgoing transfers; RPC editing; offline, malformed and lost/delayed-response recovery; destructive actions; accessibility inventory; V1 route gating; appearance, dynamic type, privacy shield, runtime secrets, and performance.

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
| Native non-max transfer could consume fee while failing on-chain and appear successful | P0 | Native transfers now reserve the emulated fee or a conservative RPC fallback floor and show a pre-broadcast blockchain-fee error |
| Node failures had no consistent recoverable wallet UI | P1 | Balance/history failures now present a deterministic pull-to-retry error and clear after successful reconnect |
| UI automation could not deterministically exercise network faults | P1 | Added a local RPC fault proxy for offline, malformed, dropped-response, and delayed-response modes with request counters |

## Remaining acceptance gaps

There are no remaining gaps inside the 105-row autonomous V1 matrix. The aggregate command `make test_v1_acceptance` passed with exit code 0 on the environment above.

Physical-device, biometric-hardware, manual accessibility/visual review, distribution-signing, App Store Connect, and TestFlight checks are outside this automated release claim and are listed explicitly in the matrix's excluded section.
