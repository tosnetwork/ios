# TOS iOS Wallet Product Test Matrix

- Document status: baseline
- Baseline date: 2026-08-06
- Code baseline: `main` at `f3e7c89`
- Maintenance rule: update this matrix in the same change that adds or changes a feature, test, or defect status.

## Status definitions

| Status | Meaning |
| --- | --- |
| `Unit: Passed` | A repeatable unit or integration test exists and its latest recorded run passed. |
| `UI: Passed` | XCUITest verifies the complete behavior described in the row and passed. |
| `Device: Passed` | A physical-iPhone run records the device, iOS version, and passing result. |
| `Partial` | Only an entry point, screen, library primitive, or lower-level behavior is covered. |
| `Not covered` | No traceable evidence exists at that test layer. This is neither a pass nor a failure. |
| `Failed` | The test ran and an assertion or expected business outcome failed, with a linked defect. |

## A. Installation and lifecycle

| ID | Feature or scenario | Unit test | UI test | Physical device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| APP-01 | Clean launch to onboarding | Not covered | UI: Passed | Not covered | Pass on simulator | `testOnboardingExposesCoreWalletEntryPoints` |
| APP-02 | Existing-wallet cold launch to home | Not covered | Not covered | Not covered | Not covered | Requires a seeded wallet fixture |
| APP-03 | Background/foreground privacy protection | Not covered | Not covered | Not covered | Not covered | Add lifecycle and device tests |
| APP-04 | Force-quit and state restoration | Not covered | Not covered | Not covered | Not covered | Add persistence tests |
| APP-05 | Offline launch and network recovery | Not covered | Not covered | Not covered | Not covered | Add network fault injection |
| APP-06 | Upgrade and legacy-data migration | Not covered | Not covered | Not covered | Not covered | Add cross-version installation tests |

## B. Onboarding, wallet creation, and import

| ID | Feature or scenario | Unit test | UI test | Physical device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| ONB-01 | Create, import, and Terms entry points | Not covered | UI: Passed | Not covered | Pass on simulator | `testOnboardingExposesCoreWalletEntryPoints` |
| ONB-02 | Open Terms content and return | Not covered | Partial | Not covered | Partial | Only link existence is asserted |
| CRT-01 | Start create-wallet flow | Not covered | UI: Passed | Not covered | Pass on simulator | Create-wallet UI test |
| CRT-02 | Set and confirm a four-digit passcode | Not covered | UI: Passed | Not covered | Pass on simulator | Create-wallet UI test |
| CRT-03 | Mismatched passcode handling | Not covered | Not covered | Not covered | Not covered | Add negative UI path |
| CRT-04 | Display recovery phrase | Not covered | Partial | Not covered | Partial | Test stops at backup introduction |
| CRT-05 | Recovery-phrase confirmation challenge | Not covered | Not covered | Not covered | Not covered | Complete backup flow |
| CRT-06 | Skip-backup warning and state | Not covered | Not covered | Not covered | Not covered | Verify controls and persistence |
| CRT-07 | Finish creation and reach wallet home | Not covered | Not covered | Not covered | Not covered | Current UI test does not complete creation |
| IMP-01 | Open Existing Wallet phrase screen | Not covered | UI: Passed | Not covered | Pass on simulator | Import-wallet UI test |
| IMP-02 | Import a valid recovery phrase | Unit: Passed for mnemonic primitive | Not covered | Not covered | Partial | Library test does not prove App import |
| IMP-03 | Paste a phrase | Not covered | Partial | Not covered | Partial | Paste control existence only |
| IMP-04 | Invalid word/count/checksum errors | Not covered | Not covered | Not covered | Not covered | Add validation matrix |
| IMP-05 | Import watch-only address | Not covered | Not covered | Not covered | Not covered | Code path exists; no end-to-end evidence |
| IMP-06 | Import Ledger, Keystone, or Signer wallet | Not covered | Not covered | Not covered | Not covered | Requires hardware and device testing |

## C. Passcode, biometrics, and security

| ID | Feature or scenario | Unit test | UI test | Physical device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| SEC-01 | Numeric keypad entry and accessibility | Not covered | UI: Passed for `1234` | Not covered | Partial | All digits are not exercised |
| SEC-02 | Backspace behavior | Not covered | Not covered | Not covered | Not covered | Identifier exists; behavior untested |
| SEC-03 | Wrong passcode and retry limits | Not covered | Not covered | Not covered | Not covered | Add negative tests |
| SEC-04 | Change passcode | Not covered | Not covered | Not covered | Not covered | Coordinator exists |
| SEC-05 | Face ID/Touch ID success, failure, cancel | Not covered | Not covered | Not covered | Not covered | Requires physical-device coverage |
| SEC-06 | Automatic lock timing | Not covered | Not covered | Not covered | Not covered | Add clock/lifecycle tests |
| SEC-07 | Authentication before phrase display | Not covered | Not covered | Not covered | Not covered | Add settings end-to-end test |
| SEC-08 | Keychain persistence and uninstall behavior | Not covered | Not covered | Not covered | Not covered | Add security-storage tests |
| SEC-09 | Screenshot, recording, and app-switcher privacy | Not covered | Not covered | Not covered | Not covered | Requires system/device verification |

## D. Home, assets, history, and multiple wallets

| ID | Feature or scenario | Unit test | UI test | Physical device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| WAL-01 | Show address and TOS balance | Unit: Passed at RPC layer | Not covered | Not covered | Partial | UI value is not asserted |
| WAL-02 | Refresh balance and loading/error states | Not covered | Not covered | Not covered | Not covered | Add delayed/error RPC fixtures |
| WAL-03 | Transaction history list and pagination | Not covered | Not covered | Not covered | Not covered | History module exists |
| WAL-04 | Transaction detail, memo, and status | Not covered | Not covered | Not covered | Not covered | Add transaction fixtures |
| WAL-05 | Empty wallet and zero balance | Not covered | Not covered | Not covered | Not covered | Add UI fixture |
| WAL-06 | Add and switch multiple wallets | Partial unit source exists | Not covered | Not covered | Partial | Relevant target is not in current CI evidence |
| WAL-07 | Rename wallet | Not covered | Not covered | Not covered | Not covered | Add settings UI test |
| WAL-08 | Delete wallet and last-wallet warning | Not covered | Not covered | Not covered | Not covered | Warning module exists |
| WAL-09 | Mainnet/testnet isolation | Unit: Passed for encoding/config | Not covered | Not covered | Partial | UI and on-chain isolation untested |
| WAL-10 | Token/Jetton asset list | Not covered | Not covered | Not covered | Not covered | Add multi-asset account fixture |
| WAL-11 | NFT list and details | Not covered | Not covered | Not covered | Not covered | Collectibles module exists |

## E. Receive

| ID | Feature or scenario | Unit test | UI test | Physical device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| RCV-01 | Open receive screen | Not covered | Not covered | Not covered | Not covered | Receive module exists |
| RCV-02 | Correct address and QR payload | Not covered | Not covered | Not covered | Not covered | Decode and assert QR payload |
| RCV-03 | Copy address | Not covered | Not covered | Not covered | Not covered | Assert pasteboard |
| RCV-04 | Share address or QR | Not covered | Not covered | Not covered | Not covered | Verify share sheet |
| RCV-05 | Balance/history update after receiving | Partial RPC integration | Not covered | Not covered | Partial | Backend transfer passed; App UI untested |
| RCV-06 | Network/asset-specific receive warnings | Not covered | Not covered | Not covered | Not covered | Add network and asset matrix |

## F. Send and transaction confirmation

| ID | Feature or scenario | Unit test | UI test | Physical device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| SND-01 | Open send screen | Not covered | Not covered | Not covered | Not covered | SendV3 module exists |
| SND-02 | Enter or paste a valid TOS address | Unit: Passed at address/RPC layer | Not covered | Not covered | Partial | App form untested |
| SND-03 | Scan recipient QR | Not covered | Not covered | Not covered | Not covered | Requires camera/device test |
| SND-04 | Invalid-address UI error | Unit: Passed at RPC layer | Not covered | Not covered | Partial | UI message untested |
| SND-05 | Amount input and decimal boundaries | Not covered | Not covered | Not covered | Not covered | Add boundary matrix |
| SND-06 | Max amount | Not covered | Not covered | Not covered | Not covered | Verify fee deduction |
| SND-07 | Memo/comment | Not covered | Not covered | Not covered | Not covered | Verify encoding and display |
| SND-08 | Fee estimate and confirmation screen | Not covered | Not covered | Not covered | Not covered | Confirmation module exists |
| SND-09 | Passcode confirmation and signing | Partial signing unit coverage | Not covered | Not covered | Partial | App end-to-end signing untested |
| SND-10 | Broadcast TOS transfer and confirm on-chain | Partial local-chain integration | Not covered | Not covered | Partial | Demo was not initiated by iOS |
| SND-11 | Insufficient balance | Not covered | Not covered | Not covered | Not covered | Add form and node-error tests |
| SND-12 | Insufficient fee balance | Not covered | Not covered | Not covered | Not covered | InsufficientFunds module exists |
| SND-13 | Timeout, disconnect, and retry | Not covered | Not covered | Not covered | Not covered | Add fault injection |
| SND-14 | Duplicate tap/broadcast prevention | Not covered | Not covered | Not covered | Not covered | Add idempotency test |
| SND-15 | Cancel confirmation and return to edit | Not covered | Not covered | Not covered | Not covered | Add navigation-state test |
| SND-16 | Token/Jetton transfer | Partial builder test source | Not covered | Not covered | Partial | Relevant target not in current CI evidence |
| SND-17 | NFT transfer | Partial builder test source | Not covered | Not covered | Partial | Relevant target not in current CI evidence |
| SND-18 | TRON USDT transfer and fee options | Unit: Passed for Tron primitives | Not covered | Not covered | Partial | Full business path untested |

## G. Settings, menus, and navigation

| ID | Feature or scenario | Unit test | UI test | Physical device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| SET-01 | Open settings and every top-level menu | Not covered | Not covered | Not covered | Not covered | Add menu traversal test |
| SET-02 | Backup/view recovery phrase | Not covered | Not covered | Not covered | Not covered | SettingsBackup exists |
| SET-03 | Change display currency | Not covered | Not covered | Not covered | Not covered | Currency picker exists |
| SET-04 | Notification settings and permission | Not covered | Not covered | Not covered | Not covered | Requires device permission test |
| SET-05 | Manage connected apps | Not covered | Not covered | Not covered | Not covered | Configurator exists |
| SET-06 | Security settings | Not covered | Not covered | Not covered | Not covered | Test passcode/biometric integration |
| SET-07 | Legal, privacy, and license pages | Not covered | Not covered | Not covered | Not covered | Modules exist |
| SET-08 | Developer menu and feature flags | Partial configuration unit coverage | Not covered | Not covered | Partial | UI/effect untested |
| SET-09 | Back, cancel, and close on every screen | Not covered | Not covered | Not covered | Not covered | Add navigation traversal |
| SET-10 | Dark mode | Not covered | Not covered | Not covered | Not covered | Add visual regression |
| SET-11 | Dynamic Type and large accessibility sizes | Not covered | Not covered | Not covered | Not covered | Add accessibility layout tests |
| SET-12 | Localization and plural rules | Unit: Passed for Russian plural | Not covered | Not covered | Partial | Does not validate all translations |

## H. Deep links, scanning, DApps, and TonConnect

| ID | Feature or scenario | Unit test | UI test | Physical device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| INT-01 | TOS/Tonkeeper deep-link parsing | Unit: Passed | Not covered | Not covered | Pass at parser layer | Parser tests |
| INT-02 | Cold-launch deep link and navigation | Unit: Passed for parsing | Not covered | Not covered | Partial | App navigation untested |
| INT-03 | Camera permission, scan success, denial | Not covered | Not covered | Not covered | Not covered | Requires camera/device test |
| INT-04 | Browser explore, category, and search | Not covered | Not covered | Not covered | Not covered | Browser module exists |
| INT-05 | Open, share, and close a DApp | Not covered | Not covered | Not covered | Not covered | Add WebView tests |
| INT-06 | Establish TonConnect session | Not covered | Not covered | Not covered | Not covered | TonConnect module exists |
| INT-07 | Approve/reject TonConnect transaction | Partial test source | Not covered | Not covered | Partial | Missing current CI and end-to-end evidence |
| INT-08 | Sign Data / Sign Raw | Unit: Passed for CellSignDataSigner | Not covered | Not covered | Partial | UI, rejection, and request flow untested |
| INT-09 | Malformed or malicious link handling | Partial unit coverage | Not covered | Not covered | Partial | Expand security input set |

## I. Extended product modules

| ID | Feature or scenario | Unit test | UI test | Physical device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| EXT-01 | Buy/Sell/Ramp entry and providers | Unit: Passed for filtering logic | Not covered | Not covered | Partial | No real-provider purchase test |
| EXT-02 | Swap quote, confirmation, result | Not covered | Not covered | Not covered | Not covered | Swap modules exist |
| EXT-03 | Staking, stake, and unstake | Not covered | Not covered | Not covered | Not covered | Staking module exists |
| EXT-04 | DNS management and renewal | Not covered | Not covered | Not covered | Not covered | DNS module exists |
| EXT-05 | Battery balance and recharge | Not covered | Not covered | Not covered | Not covered | Battery module exists |
| EXT-06 | P2P Express | Not covered | Not covered | Not covered | Not covered | P2P module exists |
| EXT-07 | Ledger hardware wallet | Not covered | Not covered | Not covered | Not covered | Requires hardware/device tests |
| EXT-08 | Keystone/Signer offline signing | Not covered | Not covered | Not covered | Not covered | Requires external-device end-to-end tests |
| EXT-09 | Balance/currency widgets | Not covered | Not covered | Not covered | Not covered | Add widget target and device tests |

## J. Reliability, compatibility, and quality attributes

| ID | Feature or scenario | Unit test | UI test | Physical device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| QLT-01 | Three-node health and masterchain progress | Unit: Passed as integration | Not covered | Not applicable | Pass | `TOSRPCLiveIntegrationTests` |
| QLT-02 | Structured HTTP 422 RPC error | Unit: Passed | Not covered | Not covered | Pass at client layer | Mock and local-node tests |
| QLT-03 | RPC URL configuration and node switch | Unit: Passed for URL config | Not covered | Not covered | Partial | Settings UI and in-flight switch untested |
| QLT-04 | Node outage, delay, malformed response | Partial unit coverage | Not covered | Not covered | Partial | Missing timeout and retry tests |
| QLT-05 | VoiceOver labels and navigation order | Not covered | Partial | Not covered | Partial | Only a few onboarding/keypad controls covered |
| QLT-06 | Small and large iPhone layouts | Not covered | Not covered | Not covered | Not covered | Add multi-destination screenshots |
| QLT-07 | iPad layout | Not covered | Not covered | Not covered | Not covered | Confirm support scope and test |
| QLT-08 | Minimum supported iOS version | Not covered | Not covered | Not covered | Not covered | Add CI version matrix |
| QLT-09 | Latest iOS simulator | Not covered | UI: Passed for three onboarding tests | Not covered | Partial | Does not cover the full product |
| QLT-10 | Launch time, memory, and performance | Not covered | Not covered | Not covered | Not covered | Establish metric baselines |
| QLT-11 | Long-running and concurrent refresh stability | Not covered | Not covered | Not covered | Not covered | Add soak tests |
| QLT-12 | Sensitive logs, pasteboard, and transport security | Not covered | Not covered | Not covered | Not covered | Add security assessment |

## Traceable evidence

- UI automation: `TOSWalletUITests/TOSWalletUITests.swift`
- RPC tests: `LocalPackages/core-swift/Tests/KeeperCoreTests/API/`
- Other unit tests: `LocalPackages/**/Tests/`
- Test entry points: `Makefile` targets `test_all`, `test_tos_live`, and `test_ui`
- Latest detailed run report: `docs/ios-wallet-test-report-2026-08-06.md`
- Latest GitHub CI at baseline: `https://github.com/tosnetwork/ios/actions/runs/31071145514`

## Product-level pass criteria

A row may move from `Partial` or `Not covered` to product-level `Pass` only when:

1. The happy path and material error paths have repeatable tests.
2. Business rules, serialization, signing, and network behavior have unit/integration coverage where applicable.
3. Buttons, menus, input, navigation, and presentation have UI automation where applicable.
4. Keychain, biometrics, camera, notifications, widgets, sharing, and hardware integrations have physical-device records where applicable.
5. Tests pass on the supported iOS/Xcode matrix with traceable CI or report evidence.
6. Every known failure links to a defect, and every fix retains a regression test.
