# TOS iOS Wallet V1 Automated Product Test Matrix

- Product: TOS Wallet for iOS
- Release scope: V1, native TOS only
- Baseline date: 2026-08-06
- Code baseline: `main` at `d663dba` plus the V1 acceptance branch under test
- Execution boundary: every row must be executable and decidable without a person, a physical iPhone, TestFlight, distribution signing, or an external service
- Brand rule: supported user-facing product, asset, network, links, and copy must use **TOS**, not TON or Tonkeeper

## Scope and completion rule

V1 supports wallet creation, recovery-phrase import, passcode protection, native TOS address and balance, native TOS receive/send/history, and TOS JSON-RPC configuration. TRON/TRC20, Jetton, NFT, Swap, Staking, DNS, Battery, Buy/Sell/Ramp, DApps, TonConnect, hardware wallets, watch-only wallets, widgets, and App Intents are deferred and must be unreachable.

This matrix deliberately excludes tests that require human observation or intervention. Physical-device installation, biometric hardware, manual VoiceOver review, manual visual review, App Store Connect, TestFlight, distribution certificates, and human approval are not part of the automated V1 completion percentage.

V1 reaches 100% automated completion only when every row below has a repeatable test, the latest run is `Passed`, and a failure makes the automated test command fail.

## Status definitions

| Status | Meaning |
| --- | --- |
| `Passed` | A repeatable automated test covers the full row and its latest run passed. |
| `Partial` | Automation covers only part of the stated behavior. |
| `Not covered` | No complete automated test exists yet. |
| `Failed` | The automated test ran and failed; evidence must identify the defect. |

## A. Branding and V1 feature gating

| ID | Automated requirement | Test layer | Status | Evidence or missing automation |
| --- | --- | --- | --- | --- |
| BRD-01 | App bundle name and onboarding identify TOS Wallet | Static + UI | Passed | UI title plus built `Info.plist` name and identifier assertions |
| BRD-02 | Native asset symbol is TOS throughout balance, receive, send, confirmation, and history | Unit + UI | Passed | Native formatter plus zero/funded home, receive, send confirmation, and seeded history UI assertions pass |
| BRD-03 | Reachable V1 screens contain no TON or Tonkeeper branding | Static + UI | Passed | Recursive reachable-element scan runs across onboarding, creation/import, home, receive, send/confirmation, history, settings, and legal flows |
| BRD-04 | No TRON/TRC20 entry point is reachable | Unit + UI | Passed | Recursive full-element UI inventory plus import/home/receive/send/settings negative assertions and stale-route gates reject TRON/TRC20 |
| BRD-05 | No Jetton/NFT/Swap/Staking/Buy/DApp/TonConnect entry point is reachable | Unit + UI | Passed | Recursive full-element UI inventory, production V1 filters, and deep-link policy cover every retained V1 surface |
| BRD-06 | Supported links and RPC defaults use approved TOS schemes and domains | Static + Unit | Passed | Static gate validates remote configuration, built legal URLs, HTTPS `tos.network` hosts, and RPC defaults |
| BRD-07 | Unsupported deep links and stale tab state are rejected | Unit + UI | Partial | Unit policy rejects inherited routes and static gate asserts Wallet/History tabs; launch-URL UI coverage missing |
| BRD-08 | V1 app bundle embeds no Widget or App Intents extension | Build artifact | Passed | `make compile`; built app has no `PlugIns` directory |

## B. Simulator installation, lifecycle, and persistence

| ID | Automated requirement | Test layer | Status | Evidence or missing automation |
| --- | --- | --- | --- | --- |
| APP-01 | A reset simulator launches to TOS onboarding | UI | Passed | Every UI test uses the guarded `TOS_UI_TEST_RESET` application-data and Keychain reset path |
| APP-02 | A seeded wallet cold-launches to wallet home | UI | Passed | Deterministic fixture mnemonic imports, relaunches to passcode, and unlocks to native wallet home |
| APP-03 | Terminate and relaunch preserve wallet and RPC settings | UI | Passed | Wallet/passcode persistence and `testRPCNodeValidationPersistenceAndRestore` cold-launch RPC persistence pass |
| APP-04 | Backgrounding adds the privacy shield and foregrounding restores safely | UI | Passed | System Home/activate UI test asserts the TOS privacy shield is installed while inactive and removed after normal foregrounding |
| APP-05 | Offline launch shows a recoverable error state | UI + Integration | Not covered | Add local proxy/network fault control |
| APP-06 | Reconnect refreshes balance and history | UI + Integration | Not covered | Add deterministic disconnect/reconnect fixture |

## C. Native TOS wallet creation

| ID | Automated requirement | Test layer | Status | Evidence or missing automation |
| --- | --- | --- | --- | --- |
| CRT-01 | Create Wallet opens passcode setup | UI | Passed | `testCreateWalletRequiresPasscodeConfirmationBeforeBackup` |
| CRT-02 | Matching four-digit passcode reaches backup introduction | UI | Passed | `1234` create flow |
| CRT-03 | Mismatched confirmation is rejected | UI | Passed | UI test verifies return to `Create passcode` after mismatch |
| CRT-04 | Backspace and cancel do not create partial wallet state | UI | Passed | Backspace boundary passes; explicit creation cancel followed by a reset-free cold launch remains clean onboarding |
| CRT-05 | Generated recovery phrase has valid words, count, and checksum | Unit | Passed | 20 generated 24-word phrases validate through TonSwift and CoreComponents |
| CRT-06 | Recovery phrase is displayed only in the authenticated backup flow | UI | Passed | Authenticated creation opens the numbered 24-word recovery screen; onboarding and ordinary wallet home do not expose the words |
| CRT-07 | Recovery-phrase confirmation challenge accepts correct answers and rejects incorrect answers | UI | Passed | UI captures all generated words, proves one wrong challenge answer is rejected, then completes with the exact challenged words |
| CRT-08 | Skip-backup warning and backup state persist correctly | UI | Passed | Dedicated UI tests cold-launch both branches and assert the warning remains only for the skipped-backup wallet |
| CRT-09 | Creation completes at native TOS wallet home | UI | Passed | UI completes passcode, skip-backup, customization, and asserts Wallet/History plus native V1 actions |
| CRT-10 | Created address parses and is queryable on the local TOS network | Unit + Integration | Passed | Fixed V5R1 mnemonic derives the asserted friendly address; local TOS RPC returns its account state |
| CRT-11 | V1 exposes no second-wallet creation path that can overwrite the active wallet | Static + UI | Passed | Wallet-home and Settings inventories contain no add/create-wallet entry after creation; storage safety is therefore enforced by reachability |

## D. Native TOS wallet import

| ID | Automated requirement | Test layer | Status | Evidence or missing automation |
| --- | --- | --- | --- | --- |
| IMP-01 | Import Wallet reaches recovery-phrase entry | UI | Passed | `testImportWalletOpensRecoveryPhraseFlow` |
| IMP-02 | Valid deterministic TOS recovery phrase imports successfully | Unit + UI | Passed | `testValidFixturePhrasePastesAndStartsNativeImport` completes paste, passcode, customization, and wallet-home import |
| IMP-03 | Paste imports the exact fixture phrase | UI | Passed | Debug-gated in-process paste fixture follows the production paste parser and derives the exact asserted address |
| IMP-04 | Spaces and capitalization are normalized safely | Unit + UI | Passed | Unit coverage includes whitespace variants; `testRecoveryPhraseNormalization` passes mixed-case phrase through the UI paste path |
| IMP-05 | Invalid word count is rejected | Unit + UI | Passed | Unit validation and `testRecoveryPhraseInvalidWordCountIsRejected` both reject the 23-word vector |
| IMP-06 | Unknown words and invalid checksum are rejected | Unit + UI | Passed | Dedicated UI tests reject unknown words and the inherited BIP39 checksum vector; import validator was fixed to enforce TOS V1 |
| IMP-07 | Imported address matches the deterministic expected TOS address | Unit + Integration | Passed | Import UI reaches receive and asserts `UQCJFahawZUzYka4uzFTeWns-oQNfoa0VNVOAn8e8BJnXPZe`; local RPC query passes |
| IMP-08 | Imported funded wallet reaches home with correct balance and history | UI + Integration | Passed | `testFundedFixtureLoadsExactNativeBalanceAndIncomingHistory` imports the funded local-chain fixture and asserts `100 TOS` plus incoming history |
| IMP-09 | Cancelled import leaves no partial wallet or secret | UI + Storage | Passed | UI cancels after fixture paste, relaunches without reset, and asserts clean onboarding with no wallet state |

## E. Passcode and secret protection

| ID | Automated requirement | Test layer | Status | Evidence or missing automation |
| --- | --- | --- | --- | --- |
| SEC-01 | Correct passcode unlocks the seeded wallet | UI | Passed | UI terminates and relaunches a created wallet, enters the correct passcode, and reaches wallet home |
| SEC-02 | Wrong passcode is rejected without changing wallet data | UI + Storage | Passed | After a wrong passcode the lock remains; the original passcode still unlocks the persisted wallet home |
| SEC-03 | Retry and lockout behavior matches the encoded policy | Unit + UI | Partial | UI now exercises five consecutive rejected attempts and recovery with the correct passcode; explicit policy unit extraction remains |
| SEC-04 | Change-passcode controls are absent when that feature is not retained in V1 | Static + UI | Passed | The encoded V1 Settings inventory excludes Security/Change Passcode and the UI negative inventory passes |
| SEC-05 | Recovery phrase requires passcode authentication | UI | Passed | Settings UI proves a wrong passcode remains gated, then the correct passcode reveals the exact fixture words |
| SEC-06 | Recovery phrase is absent from logs and pasteboard unless explicitly copied | Static + UI | Passed | Post-UI runtime gate scans the TOS Wallet process log and simulator pasteboard for the exact fixture recovery phrase |
| SEC-07 | Stored secret uses the expected Keychain accessibility class | Unit + Simulator Keychain | Passed | `CoreComponentsTests` captures the password Keychain query and requires biometric access with `whenUnlockedThisDeviceOnly` |

## F. Native TOS wallet home and balance

| ID | Automated requirement | Test layer | Status | Evidence or missing automation |
| --- | --- | --- | --- | --- |
| WAL-01 | Home displays the fixture wallet's exact TOS address | UI + Integration | Passed | Deterministic imported wallet reaches home and receive asserts the exact fixture address |
| WAL-02 | Home displays the exact native TOS symbol and balance | UI + Integration | Passed | Funded local-chain fixture renders the exact `100 TOS` home balance; zero-wallet coverage remains in `WAL-03` |
| WAL-03 | Zero balance and empty history render correctly | UI | Passed | Fresh wallet renders `0 TOS`; History opens and renders the deterministic empty-state title and caption |
| WAL-04 | Refresh updates balance after a local-chain transfer | UI + Integration | Not covered | Add local transfer orchestration |
| WAL-05 | Loading, timeout, malformed response, and retry are safe | Unit + UI | Partial | Malformed result covered; timeout/retry UI missing |
| WAL-06 | TOS decimal formatting handles zero, fractions, and maximum supported values | Unit | Passed | Exact, compact, nano, and very-large `BigUInt` formatter tests |
| WAL-07 | Only native TOS appears in the V1 asset list | Unit + UI | Passed | Production mapper gate plus zero-wallet UI inventory assert TOS and reject TON, TRX, USDT, Jetton, and NFT assets |

## G. Receive native TOS

| ID | Automated requirement | Test layer | Status | Evidence or missing automation |
| --- | --- | --- | --- | --- |
| RCV-01 | Receive opens the native TOS receive screen | UI | Passed | Created-wallet UI opens `Receive TOS` and asserts a valid friendly address |
| RCV-02 | Receive shows the exact fixture wallet address | UI | Passed | Deterministic import opens Receive and asserts exact address equality |
| RCV-03 | Rendered QR decodes to a native transfer payload containing the exact TOS address | UI + QR decoder | Passed | UI crops the rendered QR, decodes it with Core Image, and asserts the exact displayed friendly address is in the payload |
| RCV-04 | Copy writes the exact address to simulator pasteboard | UI | Passed | UI taps Copy, observes `Copied`, and the guarded in-process probe returns the exact pasteboard value for comparison |
| RCV-05 | Share activity payload contains the exact address | UI | Passed | UI opens the iOS `ActivityListView` and asserts the address received by the activity-items callback exactly matches the displayed address |
| RCV-06 | Incoming local-chain transfer refreshes balance and history | UI + Integration | Not covered | Add deterministic sender and polling bound |
| RCV-07 | Receive exposes no TRC20, Jetton, or NFT option | Unit + UI | Partial | Receive UI negative inventory passes and production filter is present; isolated mapper test missing |

## H. Send native TOS

| ID | Automated requirement | Test layer | Status | Evidence or missing automation |
| --- | --- | --- | --- | --- |
| SND-01 | Send opens the native TOS form | UI | Passed | Created-wallet UI opens Send and asserts recipient, amount, and comment fields |
| SND-02 | Valid typed and pasted TOS addresses are accepted | Unit + UI | Passed | Parser tests plus typed-address and exact recipient paste-button UI paths pass |
| SND-03 | Invalid address is rejected with deterministic UI error | Unit + UI | Passed | Live-node rejection plus UI entry of `invalid-address` deterministically renders `Invalid wallet address.` |
| SND-04 | Whole and fractional TOS amounts are accepted | Unit + UI | Passed | `testNativeSendAmountBoundaries` accepts `1` and `1.25` TOS with a funded fixture |
| SND-05 | Zero, negative, excessive precision, overflow, and over-balance amounts are rejected | Unit + UI | Passed | Boundary UI table rejects zero, negative sign, sub-nano precision, huge overflow input, and `101 TOS` against the funded fixture; zero-amount core validation was fixed |
| SND-06 | Max amount reserves the required network fee | Unit + Integration | Not covered | Add deterministic fee fixture |
| SND-07 | Optional comment is encoded and recovered exactly | Unit + Integration | Passed | UI enforces the 120 UTF-8-byte boundary; an app-originated `TOS 星河 🚀` comment is recovered byte-for-byte through native `getAccountEvent` |
| SND-08 | Confirmation shows exact recipient, amount, fee, and comment | UI | Not covered | Add confirmation assertions |
| SND-09 | Cancel never broadcasts | UI + Integration | Passed | Confirmation cancellation returns home and leaves the recipient's exact local-chain balance unchanged |
| SND-10 | Passcode signs a native TOS transfer | Unit + UI | Passed | `testPasscodeSignsBroadcastsAndReconcilesNativeTransfer` completes confirmation, passcode signing, and native submission |
| SND-11 | iOS broadcasts to the local three-node TOS network | UI + Integration | Passed | App-originated `0.5 TOS` transfer is accepted by the resident three-validator local network and observed through native RPC |
| SND-12 | Confirmation updates sender/recipient balances and app history | UI + Integration | Passed | Bounded polling asserts sender debit, recipient `0.5 TOS` credit, and the matching TOS history row |
| SND-13 | Insufficient balance and insufficient fee show safe errors | Unit + UI | Not covered | Add funded/underfunded fixtures |
| SND-14 | Timeout/disconnect retry does not duplicate the transfer | UI + Integration | Not covered | Add fault proxy and idempotency assertion |
| SND-15 | Relaunch reconciles a pending transaction | UI + Integration | Not covered | Add controlled delayed-confirmation fixture |
| SND-16 | Send exposes no token, NFT, or TRC20 selector | Unit + UI | Partial | Native Send UI negative inventory passes; isolated form-policy unit test missing |

## I. Native TOS transaction history

| ID | Automated requirement | Test layer | Status | Evidence or missing automation |
| --- | --- | --- | --- | --- |
| HIS-01 | Load deterministic native TOS history | Integration + UI | Passed | Native `getAccountEvents` mapper tests plus funded incoming and app-originated outgoing history UI fixtures pass |
| HIS-02 | Render incoming and outgoing directions, counterparties, and amounts | Unit + UI | Passed | Mapper fixtures assert both directions/counterparties/nanotOS; UI asserts exact incoming `100 TOS` and outgoing `0.5 TOS` rows |
| HIS-03 | Render pending, confirmed, and failed states accurately | Unit + UI | Partial | Confirmed and bounced/failed native mappings pass; pending UI fixture remains |
| HIS-04 | Details show exact timestamp, fee, address, amount, and comment | Unit + UI | Partial | Timestamp, fee, addresses, and amount mapping pass; node comment decoding and details UI remain |
| HIS-05 | Pagination has no duplicate or missing records | Unit + Integration | Not covered | Add multi-page local fixture |
| HIS-06 | Empty, loading, error, and retry states are deterministic | Unit + UI | Partial | Empty native response now renders and passes in UI; malformed mapping passes, while loading/error/retry UI remains |
| HIS-07 | Newly confirmed app transfer appears once | UI + Integration | Passed | End-to-end send compares event-ID sets before/after and requires exactly one new event before asserting the UI row |
| HIS-08 | V1 history exposes no TRON, Jetton, NFT, DApp, or spam navigation | Unit + UI | Passed | Native mapper rejects unsupported directions and the now-started History UI has a complete negative V1 navigation inventory |

## J. TOS RPC and local three-node network

| ID | Automated requirement | Test layer | Status | Evidence or missing automation |
| --- | --- | --- | --- | --- |
| RPC-01 | Debug RPC defaults to the configured local TOS endpoint | Unit | Passed | `TOSRPCSettingsTests` |
| RPC-02 | Release configuration contains the approved TOS RPC endpoint | Static + Build settings | Passed | Automated JSON URL scan requires all configured hosts to end in `tos.network` |
| RPC-03 | RPC URL validation and `/json_rpc` normalization are correct | Unit | Passed | `TOSRPCSettingsTests` |
| RPC-04 | Query the funded fixture account | Integration | Passed | `TOSRPCLiveIntegrationTests` |
| RPC-05 | Masterchain advances within the bounded interval | Integration | Passed | `TOSRPCLiveIntegrationTests` |
| RPC-06 | Structured node errors are preserved | Unit | Passed | `TOSRPCClientTests` |
| RPC-07 | Timeout, unavailable node, and reconnect are bounded and recoverable | Unit + Integration | Passed | Client tests cover timeout, bounded unavailable-node retries, one-transient reconnect, non-retried broadcasts, and stable error propagation |
| RPC-08 | Malformed JSON and malformed result never crash | Unit | Passed | Both malformed forms map to stable `invalidResponse` |
| RPC-09 | All three validators converge before and after a transfer | Integration | Partial | All validators now expose consecutive RPC ports and agree on height, funded balance, and event IDs after funding; the same assertion around an in-test transfer remains |

## K. V1 settings and destructive actions

| ID | Automated requirement | Test layer | Status | Evidence or missing automation |
| --- | --- | --- | --- | --- |
| SET-01 | Open settings and return to wallet | UI | Passed | `testSettingsNavigationAndV1Inventory` opens Settings from a created wallet and returns to the native wallet home |
| SET-02 | View recovery phrase only after correct passcode | UI | Passed | Backup settings warning plus wrong/correct passcode UI flow asserts all 24 exact imported words only after authentication |
| SET-03 | Edit, validate, persist, reset, and use the RPC endpoint | Unit + UI + Integration | Partial | Unit tests plus UI rejection, normalization, cold-launch persistence, and restore pass; app-originated request routing assertion remains |
| SET-04 | Delete wallet requires explicit confirmation | UI | Passed | Confirm action is disabled before backup acknowledgement; cancellation/relaunch preserves and unlocks the wallet |
| SET-05 | Deleting the last wallet returns to clean onboarding | UI + Storage | Passed | Acknowledged deletion plus passcode returns to onboarding and remains deleted after relaunch |
| SET-06 | Legal/privacy/license links and reachable copy use approved TOS branding | Static + UI | Passed | Legal inventory UI passes; static gate rejects inherited legal copy and non-HTTPS/non-TOS built URLs |
| SET-07 | Settings inventory contains only V1 options | Unit + UI | Passed | UI asserts the Backup, RPC, Delete Account, and Legal inventory and rejects deferred product entries |

## L. Automated quality and build checks

| ID | Automated requirement | Test layer | Status | Evidence or missing automation |
| --- | --- | --- | --- | --- |
| QLT-01 | Every reachable V1 control has a non-empty accessibility identifier or label | Static + UI | Passed | Recursive UI assertion checks every hittable button, text field, secure field, link, and switch across all retained V1 flows |
| QLT-02 | V1 screens do not clip at supported simulator text sizes and screen dimensions installed on this host | Multi-destination UI | Not covered | Add screenshot geometry assertions, not human review |
| QLT-03 | Light and dark modes preserve readable elements and stable layouts | Snapshot + UI | Not covered | Add pixel/geometry thresholds with stored baselines |
| QLT-04 | Launch time, memory, and repeated refresh/send flows stay within encoded budgets | XCTMetric | Not covered | Define numeric budgets and performance tests |
| QLT-05 | Process logs and telemetry contain no fixture secret or passcode | Static + Runtime log scan | Passed | `test_v1_runtime_secrets.sh`, wired into `make test_ui`, rejects the exact fixture phrase and passcode/password log patterns |
| QLT-06 | TLS, certificate, and proxy failures return safe errors | Unit + Integration | Passed | Deterministic URL-protocol tests return safe TLS/certificate errors without retry and preserve bounded proxy/network failures |
| BLD-01 | Debug simulator build succeeds | Build | Passed | `make compile` |
| BLD-02 | Unsigned generic-device release build/archive succeeds | Build | Passed | `make archive_v1_release`; signing-disabled `TonkeeperRelease` archive succeeded for generic iOS |
| BLD-03 | Built V1 app contains required privacy metadata and only approved entitlements/permission strings | Build artifact | Passed | Main app privacy manifest is embedded, valid, and non-tracking; deferred schemes, permissions, entitlements, and extensions are rejected |
| BLD-04 | `make test_all`, `make test_tos_live`, and `make test_ui` all succeed | Test orchestration | Passed | Latest local run passed with zero failures |

## Excluded human/external validation

The following activities are intentionally not rows and do not affect the automated completion percentage:

- Physical-iPhone installation or smoke testing
- Biometric hardware behavior
- Manual VoiceOver, visual, color, or usability review
- Distribution certificate/provisioning-profile validation
- App Store Connect or TestFlight upload, review, installation, and upgrade
- Human approval, observation, or subjective acceptance
- External production-service availability outside the local three-node TOS environment

## Automated release gate

The matrix is 100% complete only when every row is `Passed`. The authoritative commands are:

```sh
make compile
make test_all
make test_tos_live
make test_ui
```

Additional tests introduced for this matrix must be wired into one of those commands. `make test_v1_acceptance` is the aggregate autonomous gate. Test evidence must record the commit, test command, simulator/runtime, local RPC endpoint, date, result, and defect ID for failures.

## Current evidence

- UI automation: `TOSWalletUITests/TOSWalletUITests.swift`
- RPC tests: `LocalPackages/core-swift/Tests/KeeperCoreTests/API/`
- Other unit tests: `LocalPackages/**/Tests/`
- Detailed report: `docs/ios-v1-acceptance-test-report.md`
- Test entry points: `Makefile`
