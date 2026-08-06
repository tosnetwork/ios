# TOS iOS Wallet Product Test Matrix

- Document status: baseline
- Baseline date: 2026-08-06
- Code baseline: `main` at `868b521`
- Default owner: iOS team (replace with a named owner when scheduled)
- Default priority: `P0` for wallet access/signing/value transfer, `P1` for core navigation and account data, `P2` for optional modules and quality improvements
- Maintenance rule: update this matrix in the same change that adds or changes a feature, test, or defect status.

## Status definitions

| Status | Meaning |
| --- | --- |
| `Unit: Passed` | A repeatable unit or integration test exists and its latest recorded run passed. |
| `Integration: Passed` | A repeatable test crosses the client/process/network boundary and passed. |
| `UI: Passed` | XCUITest verifies the complete behavior described in the row and passed. |
| `Device: Passed` | A physical-iPhone run records the device, iOS version, and passing result. |
| `Manual: Passed` | A documented manual case records tester, build, environment, date, and evidence. |
| `Partial` | Only an entry point, screen, library primitive, or lower-level behavior is covered. |
| `Not covered` | No traceable evidence exists at that test layer. This is neither a pass nor a failure. |
| `Failed` | The test ran and an assertion or expected business outcome failed, with a linked defect. |

## A. Installation and lifecycle

| ID | Feature or scenario | Unit test | UI test | Physical device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| APP-01 | Launch to onboarding in the UI-test state | Not covered | UI: Passed | Not covered | Pass on simulator | Does not prove a clean install because Keychain/UserDefaults are not explicitly reset |
| APP-02 | Existing-wallet cold launch to home | Not covered | Not covered | Not covered | Not covered | Requires a seeded wallet fixture |
| APP-03 | Background/foreground privacy protection | Not covered | Not covered | Not covered | Not covered | Add lifecycle and device tests |
| APP-04 | Force-quit and state restoration | Not covered | Not covered | Not covered | Not covered | Add persistence tests |
| APP-05 | Offline launch and network recovery | Not covered | Not covered | Not covered | Not covered | Add network fault injection |
| APP-06 | Upgrade and legacy-data migration | Not covered | Not covered | Not covered | Not covered | Add cross-version installation tests |
| APP-07 | First launch after reinstall with retained Keychain data | Not covered | Not covered | Not covered | Not covered | P0; requires install/uninstall device procedure |
| APP-08 | Multiple scene/window and interrupted launch handling | Not covered | Not covered | Not covered | Not covered | P2; add lifecycle tests |
| APP-09 | In-app update prompt and dismissal | Not covered | Not covered | Not covered | Not covered | P2; `UpdatePopup` exists |

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
| IMP-02 | Import a valid recovery phrase | Not covered for App import | Not covered | Not covered | Not covered | Tron mnemonic primitives are not evidence for TOS App import |
| IMP-03 | Paste a phrase | Not covered | Partial | Not covered | Partial | Paste control existence only |
| IMP-04 | Invalid word/count/checksum errors | Not covered | Not covered | Not covered | Not covered | Add validation matrix |
| IMP-05 | Import watch-only address | Not covered | Not covered | Not covered | Not covered | Code path exists; no end-to-end evidence |
| IMP-06 | Import Ledger, Keystone, or Signer wallet | Not covered | Not covered | Not covered | Not covered | Requires hardware and device testing |
| IMP-07 | Import a testnet wallet | Not covered | Not covered | Not covered | Not covered | P1; separate `.testnet` coordinator path |
| IMP-08 | Import a Tetra wallet | Not covered | Not covered | Not covered | Not covered | P2; separate `.tetra` coordinator path |
| IMP-09 | Import by public key | Not covered | Not covered | Not covered | Not covered | P1; `PublicKeyImportCoordinator` exists |
| IMP-10 | Resolve domain in watch-only import | Not covered | Not covered | Not covered | Not covered | P1; test resolved and unresolved domains |
| CRT-08 | Customize wallet name, color, and emoji | Not covered | Not covered | Not covered | Not covered | P1; `CustomizeWallet` exists |
| CRT-09 | Create/add a different wallet version | Not covered | Not covered | Not covered | Not covered | P1; version-selection coordinator exists |

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
| WAL-12 | Edit wallet name, color, and emoji | Not covered | Not covered | Not covered | Not covered | P1; edit configurator exists |
| WAL-13 | Wallet list edit/reorder mode | Not covered | Not covered | Not covered | Not covered | P1; verify Edit/Done and persistence |
| WAL-14 | Manage token visibility and ordering | Not covered | Not covered | Not covered | Not covered | P1; `ManageTokens` exists |
| WAL-15 | TON token details and actions | Not covered | Not covered | Not covered | Not covered | P1; send/receive/buy/swap actions |
| WAL-16 | Jetton token details and actions | Not covered | Not covered | Not covered | Not covered | P1; include metadata/error states |
| WAL-17 | TRC20 token details and fee banner | Not covered | Not covered | Not covered | Not covered | P1; Battery/TRX variants |
| WAL-18 | Token price chart and period selection | Not covered | Not covered | Not covered | Not covered | P2; include empty/error data |
| WAL-19 | All Updates feed | Not covered | Not covered | Not covered | Not covered | P2; module exists |
| WAL-20 | Support popup and external support link | Not covered | Not covered | Not covered | Not covered | P2; validate trusted destination |
| WAL-21 | Ethena asset and staking details | Not covered | Not covered | Not covered | Not covered | P2; dedicated configurator/module exists |
| HIS-01 | History All/Sent/Received/Spam filters | Not covered | Not covered | Not covered | Not covered | P1; four filter branches exist |
| HIS-02 | Initial loading, pagination, and retry states | Not covered | Not covered | Not covered | Not covered | P1; include page-load failure |
| HIS-03 | TON and TRON event rendering | Not covered | Not covered | Not covered | Not covered | P1; fixture both event types |
| HIS-04 | Mark transaction as spam/not spam | Not covered | Not covered | Not covered | Not covered | P1; verify list movement and persistence |
| HIS-05 | Decrypt encrypted transaction comment | Not covered | Not covered | Not covered | Not covered | P1; include auth failure |
| NFT-01 | NFT verified/unverified presentation | Not covered | Not covered | Not covered | Not covered | P1; distinct fixtures |
| NFT-02 | NFT spam/not-spam reporting | Not covered | Not covered | Not covered | Not covered | P1; verify repository result and UI |
| NFT-03 | NFT management actions | Not covered | Not covered | Not covered | Not covered | P1; include cancel/error |
| NFT-04 | Purchases management and details | Not covered | Not covered | Not covered | Not covered | P2; settings modules exist |

## E. Receive

| ID | Feature or scenario | Unit test | UI test | Physical device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| RCV-01 | Open receive screen | Not covered | Not covered | Not covered | Not covered | Receive module exists |
| RCV-02 | Correct address and QR payload | Not covered | Not covered | Not covered | Not covered | Decode and assert QR payload |
| RCV-03 | Copy address | Not covered | Not covered | Not covered | Not covered | Assert pasteboard |
| RCV-04 | Share address or QR | Not covered | Not covered | Not covered | Not covered | Verify share sheet |
| RCV-05 | Balance/history update after receiving | Partial RPC integration | Not covered | Not covered | Partial | Backend transfer passed; App UI untested |
| RCV-06 | Network/asset-specific receive warnings | Not covered | Not covered | Not covered | Not covered | Add network and asset matrix |
| RCV-07 | TON/TRC20 receive tab switching | Not covered | Not covered | Not covered | Not covered | P0; assert address/network changes |
| RCV-08 | TRC20-disabled wallet prompt and enable flow | Not covered | Not covered | Not covered | Not covered | P0; `ReceiveTRC20Popup` exists |
| RCV-09 | QR readability on small/large screens and dark mode | Not covered | Not covered | Not covered | Not covered | P1; decode rendered QR screenshots |

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
| SND-19 | Token picker search, selection, and empty state | Not covered | Not covered | Not covered | Not covered | P0; `SendTokenPicker` exists |
| SND-20 | Recipient domain resolution | Not covered | Not covered | Not covered | Not covered | P0; success, unresolved, and spoofing cases |
| SND-21 | Amount unit and fiat/crypto conversion | Not covered | Not covered | Not covered | Not covered | P1; shared AmountInput variants |
| SND-22 | Encrypted comment and recipient compatibility | Not covered | Not covered | Not covered | Not covered | P1; verify payload and fallback |
| SND-23 | TRON activation/top-up path | Not covered | Not covered | Not covered | Not covered | P0; include insufficient TRX/Battery paths |
| SND-24 | Signer/Keystone/Ledger confirmation and rejection | Not covered | Not covered | Not covered | Not covered | P0; requires hardware/device records |

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
| SET-13 | Theme selection and persistence | Not covered | Not covered | Not covered | Not covered | P1; system/light/dark variants |
| SET-14 | Search-engine selection and use | Not covered | Not covered | Not covered | Not covered | P2; verify generated search URL |
| SET-15 | RPC node editor, validation, save, and reset | Unit: Passed for URL config | Not covered | Not covered | Partial | P0; settings UI untested |
| SET-16 | Wallet V4/V5 information and version actions | Not covered | Not covered | Not covered | Not covered | P1; conditional settings items exist |
| SET-17 | Sign out versus delete-wallet behavior | Not covered | Not covered | Not covered | Not covered | P0; test every wallet kind and last wallet |
| SET-18 | App information, version, and external links | Not covered | Not covered | Not covered | Not covered | P2; validate destinations |
| SET-19 | Tooltip settings and date controls | Not covered | Not covered | Not covered | Not covered | P2; configurator exists |
| SET-20 | TRON wallet setup and seed-phrase settings | Not covered | Not covered | Not covered | Not covered | P0; conditional settings paths |

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
| INT-10 | Open-DApp warning accept/cancel/do-not-show | Not covered | Not covered | Not covered | Not covered | P1; shared warning popup exists |
| INT-11 | TonConnect reconnect, disconnect, and session persistence | Not covered | Not covered | Not covered | Not covered | P0; include relaunch and stale session |
| INT-12 | TonConnect manifest/network/account mismatch | Not covered | Not covered | Not covered | Not covered | P0; security-critical negative cases |
| INT-13 | Sign Data display, approve, reject, and malformed payload | Unit: Passed for signer primitive | Not covered | Not covered | Partial | P0; UI/request lifecycle untested |
| INT-14 | Sign Raw display, approve, reject, and malformed payload | Partial mapping coverage | Not covered | Not covered | Partial | P0; end-to-end untested |

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
| EXT-10 | Buy/Sell country and provider selection | Not covered | Not covered | Not covered | Not covered | P2; country/provider pickers exist |
| EXT-11 | Ramp amount, payment method, and validation | Not covered | Not covered | Not covered | Not covered | P1; include minimum/maximum amounts |
| EXT-12 | Ramp QR payment and Send Asset flow | Not covered | Not covered | Not covered | Not covered | P1; include expiry/cancel/error |
| EXT-13 | Native Swap token picker and quote refresh | Not covered | Not covered | Not covered | Not covered | P1; stale quote and slippage cases |
| EXT-14 | Web Swap message bridge and untrusted messages | Not covered | Not covered | Not covered | Not covered | P1; WebView security boundary |
| EXT-15 | Staking pool selection, APY, and estimate | Not covered | Not covered | Not covered | Not covered | P2; split from stake/unstake execution |
| EXT-16 | Battery promo code and validation | Not covered | Not covered | Not covered | Not covered | P2; promo module exists |
| EXT-17 | Battery refill token, transaction, and settings | Not covered | Not covered | Not covered | Not covered | P1; several refill modules exist |
| EXT-18 | Balance Widget timeline, sizes, and empty state | Not covered | Not covered | Not covered | Not covered | P2; device/widget gallery testing |
| EXT-19 | Rate Widget chart, timeline, sizes, and errors | Not covered | Not covered | Not covered | Not covered | P2; separate widget implementation |
| EXT-20 | Widget App Intent wallet/currency selection | Not covered | Not covered | Not covered | Not covered | P2; `TonkeeperIntents` exists |

## J. Reliability, compatibility, and quality attributes

| ID | Feature or scenario | Unit test | UI test | Physical device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| QLT-01 | Three-node health and masterchain progress | Integration: Passed | Not covered | Not applicable | Pass | `TOSRPCLiveIntegrationTests` |
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
| QLT-13 | Landscape orientation and rotation recovery | Not covered | Not covered | Not covered | Not covered | P2; confirm supported orientations |
| QLT-14 | Right-to-left layout | Not covered | Not covered | Not covered | Not covered | P2; add pseudo-localized screenshots |
| QLT-15 | Reduce Motion and Reduce Transparency | Not covered | Not covered | Not covered | Not covered | P2; accessibility settings |
| QLT-16 | Color contrast and non-color status cues | Not covered | Not covered | Not covered | Not covered | P1; accessibility audit |
| QLT-17 | Software/hardware keyboard and input obstruction | Not covered | Not covered | Not covered | Not covered | P1; phrase, amount, memo, search fields |
| QLT-18 | Low-storage and memory-pressure recovery | Not covered | Not covered | Not covered | Not covered | P2; fault/device testing |
| QLT-19 | TLS/certificate/proxy failure handling | Not covered | Not covered | Not covered | Not covered | P0; transport security cases |
| QLT-20 | No analytics SDK or unintended telemetry | Not covered | Not covered | Not covered | Not covered | P1; static and runtime network audit |

## K. Build, release, and distribution

| ID | Feature or scenario | Unit test | UI test | Physical device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| REL-01 | Debug simulator build | Not applicable | Not applicable | Not applicable | Pass | `make compile` and GitHub CI run `31071145514` |
| REL-02 | Release archive with distribution signing | Not covered | Not covered | Not covered | Not covered | P0; archive and export validation |
| REL-03 | App, Widget, and Intents embedding/signing | Not covered | Not covered | Not covered | Not covered | P0; inspect archive and install on device |
| REL-04 | TestFlight install, launch, and upgrade | Not covered | Not covered | Not covered | Not covered | P0; retain wallet and settings across upgrade |
| REL-05 | Production RPC configuration and smoke test | Not covered | Not covered | Not covered | Not covered | P0; no value transfer without release approval |
| REL-06 | Privacy manifest, entitlements, and permission strings | Not covered | Not covered | Not covered | Not covered | P0; automated archive audit |
| REL-07 | Crash/symbolication and diagnostics export | Not covered | Not covered | Not covered | Not covered | P1; validate dSYM and safe log export |

## L. Interactive-control inventory

This section prevents a feature-level row from hiding untested buttons. Each control group must eventually link to individual accessibility identifiers and UI cases.

| ID | Control group | UI test | Physical device | Overall | Missing coverage |
| --- | --- | --- | --- | --- | --- |
| CTL-01 | Onboarding: Create, Import, Terms | Partial | Not covered | Partial | Terms navigation is not exercised |
| CTL-02 | Secure keypad: digits, backspace, biometric | Partial | Not covered | Partial | Only `1234` is tapped; backspace/biometric untested |
| CTL-03 | Wallet header: Buy, Receive, Scan, Send, Stake, Swap | Not covered | Not covered | Not covered | Exercise visibility, disabled states, and destination |
| CTL-04 | Wallet selector: open, select, add, edit, done | Not covered | Not covered | Not covered | Include multiple wallet kinds |
| CTL-05 | Token details: Send, Receive, Buy/Sell, Swap, chart period | Not covered | Not covered | Not covered | Test each supported token type |
| CTL-06 | History: filter, event, retry, spam, decrypt | Not covered | Not covered | Not covered | Include pagination states |
| CTL-07 | Receive: asset tabs, copy, share, close | Not covered | Not covered | Not covered | Validate QR/address per selected tab |
| CTL-08 | Send: token, recipient, scanner, amount, max, memo, continue | Not covered | Not covered | Not covered | Include validation and keyboard states |
| CTL-09 | Confirmation: back, cancel, confirm, retry | Not covered | Not covered | Not covered | Prevent duplicate submission |
| CTL-10 | Settings: every row, toggle, picker, destructive action | Not covered | Not covered | Not covered | Generate expected menu inventory per wallet kind |
| CTL-11 | Browser/TonConnect: search, share, connect, approve, reject, disconnect | Not covered | Not covered | Not covered | Include malicious/stale requests |
| CTL-12 | Hardware wallet: pair, rescan, approve, reject, disconnect | Not covered | Not covered | Not covered | Requires supported devices |

## Traceable evidence

- UI automation: `TOSWalletUITests/TOSWalletUITests.swift`
- RPC tests: `LocalPackages/core-swift/Tests/KeeperCoreTests/API/`
- Other unit tests: `LocalPackages/**/Tests/`
- Test entry points: `Makefile` targets `test_all`, `test_tos_live`, and `test_ui`
- Latest detailed run report: `docs/ios-wallet-test-report-2026-08-06.md`
- Latest GitHub CI at baseline: `https://github.com/tosnetwork/ios/actions/runs/31071145514`

## Execution tracking requirements

The compact tables above intentionally avoid repeating administrative fields on every row. When a row is scheduled or executed, its linked test case or test-management record must contain:

| Field | Required value |
| --- | --- |
| Priority | `P0`, `P1`, or `P2` |
| Owner | Named engineer or QA owner, not only a team name |
| Test type | Unit, integration, UI automation, manual simulator, or physical device |
| Build | Commit SHA plus app version/build number |
| Environment | Xcode, iOS, device/simulator model, network, RPC endpoint |
| Last run | ISO date/time and CI run or report link |
| Result | Passed, Failed, Blocked, or Not Run |
| Defect | Issue ID for every failure; `None` only for a passing run |
| Evidence | XCTest result, screenshot/video, device log, or signed manual record |

## Product-level pass criteria

A row may move from `Partial` or `Not covered` to product-level `Pass` only when:

1. The happy path and material error paths have repeatable tests.
2. Business rules, serialization, signing, and network behavior have unit/integration coverage where applicable.
3. Buttons, menus, input, navigation, and presentation have UI automation where applicable.
4. Keychain, biometrics, camera, notifications, widgets, sharing, and hardware integrations have physical-device records where applicable.
5. Tests pass on the supported iOS/Xcode matrix with traceable CI or report evidence.
6. Every known failure links to a defect, and every fix retains a regression test.
