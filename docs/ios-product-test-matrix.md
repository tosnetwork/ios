# TOS iOS Wallet V1 Product Test Matrix

- Product: TOS Wallet for iOS
- Release scope: V1
- Baseline date: 2026-08-06
- Code baseline: `main` at `2fd8ea4`
- Brand rule: user-facing product, asset, network, links, and copy must use **TOS**, not TON or Tonkeeper

## V1 product scope

V1 is a native-TOS-only wallet. Its supported business capabilities are:

1. Create a native TOS wallet.
2. Import an existing native TOS wallet with a recovery phrase.
3. Secure wallet access with an app passcode.
4. Display the native TOS address and balance.
5. Receive native TOS.
6. Send, sign, broadcast, and confirm native TOS transfers.
7. Display native TOS transaction history and transaction details.
8. Configure the TOS JSON-RPC endpoint required by the wallet.

TRC20, TRON, Jetton, NFT, Swap, Staking, DNS, Battery, fiat Buy/Sell/Ramp, DApps, TonConnect, hardware wallets, widgets, and other inherited TON/Tonkeeper features are **out of scope for V1**. They must not be presented as supported V1 functionality and are excluded from the V1 completion percentage.

## Status definitions

| Status | Meaning |
| --- | --- |
| `Unit: Passed` | A repeatable unit test exists and its latest recorded run passed. |
| `Integration: Passed` | A repeatable client/process/network test exists and passed. |
| `UI: Passed` | XCUITest verifies the full behavior described by the row and passed. |
| `Device: Passed` | A physical-iPhone run records the device, iOS version, build, date, and passing result. |
| `Partial` | Only an entry point, screen, primitive, or lower-level behavior is covered. |
| `Not covered` | No traceable evidence exists. This is neither a pass nor a failure. |
| `Failed` | The test ran and the expected outcome failed, with a linked defect. |
| `Out of scope (V1)` | Deliberately excluded from V1 and not counted in V1 coverage. |

## A. Branding and V1 feature gating

| ID | V1 requirement | Unit | UI | Device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| BRD-01 | App name and onboarding use TOS Wallet | Not covered | UI: Passed | Not covered | Partial | Onboarding title asserted; full-app copy audit missing |
| BRD-02 | Native asset symbol is TOS | Not covered | Not covered | Not covered | Not covered | Audit balance, receive, send, confirmation, history |
| BRD-03 | No user-facing TON/Tonkeeper branding | Not covered | Not covered | Not covered | Not covered | P0 static string/resource and screenshot audit |
| BRD-04 | No user-facing TRON/TRC20 entry points | Not covered | Not covered | Not covered | Not covered | P0 runtime menu/navigation audit |
| BRD-05 | No Jetton/NFT/Swap/Staking entry points | Not covered | Not covered | Not covered | Not covered | P0 runtime feature-gating audit |
| BRD-06 | Production links and RPC endpoints use approved TOS domains | Unit: Partial | Not covered | Not covered | Partial | RPC default covered; audit all external URLs |
| BRD-07 | Legacy modules cannot be opened by deep link or stale state | Not covered | Not covered | Not covered | Not covered | P0 negative navigation tests |

## B. Installation and lifecycle

| ID | V1 requirement | Unit | UI | Device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| APP-01 | Fresh install launches to TOS onboarding | Not covered | Partial | Not covered | Partial | Current UI test does not explicitly reset Keychain/UserDefaults |
| APP-02 | Existing wallet cold-launches to wallet home | Not covered | Not covered | Not covered | Not covered | Seeded wallet fixture required |
| APP-03 | Force quit preserves wallet and settings | Not covered | Not covered | Not covered | Not covered | P0 persistence test |
| APP-04 | Backgrounding hides sensitive wallet content | Not covered | Not covered | Not covered | Not covered | P0 lifecycle/device test |
| APP-05 | Offline launch shows a recoverable state | Not covered | Not covered | Not covered | Not covered | Network fault injection required |
| APP-06 | Reconnect refreshes balance and history | Not covered | Not covered | Not covered | Not covered | Network recovery test |
| APP-07 | Upgrade preserves native TOS wallet data | Not covered | Not covered | Not covered | Not covered | Cross-version/TestFlight test |

## C. Native TOS wallet creation

| ID | V1 requirement | Unit | UI | Device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| CRT-01 | Create Wallet entry point | Not covered | UI: Passed | Not covered | Pass on simulator | Existing onboarding UI test |
| CRT-02 | Set and confirm a four-digit passcode | Not covered | UI: Passed | Not covered | Pass on simulator | Happy path `1234` only |
| CRT-03 | Reject mismatched passcode confirmation | Not covered | Not covered | Not covered | Not covered | Negative UI case required |
| CRT-04 | Backspace and cancel behave safely | Not covered | Not covered | Not covered | Not covered | Navigation/keypad tests required |
| CRT-05 | Generate a valid native TOS recovery phrase | Not covered | Not covered | Not covered | Not covered | P0 TOS wallet primitive test |
| CRT-06 | Display recovery phrase securely | Not covered | Partial | Not covered | Partial | Test stops at backup introduction |
| CRT-07 | Recovery-phrase confirmation challenge | Not covered | Not covered | Not covered | Not covered | Complete backup flow |
| CRT-08 | Skip-backup warning and persistent backup state | Not covered | Not covered | Not covered | Not covered | Warning/state tests required |
| CRT-09 | Complete creation and reach native TOS wallet home | Not covered | Not covered | Not covered | Not covered | P0 end-to-end UI test |
| CRT-10 | Created address is valid on the TOS network | Not covered | Not covered | Not covered | Not covered | Validate through local TOS JSON-RPC |
| CRT-11 | Duplicate creation does not overwrite existing wallet | Not covered | Not covered | Not covered | Not covered | P0 data-safety test |

## D. Native TOS wallet import

| ID | V1 requirement | Unit | UI | Device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| IMP-01 | Import Wallet entry reaches phrase screen | Not covered | UI: Passed | Not covered | Pass on simulator | Existing import UI test |
| IMP-02 | Import a valid native TOS recovery phrase | Not covered | Not covered | Not covered | Not covered | P0; Tron mnemonic tests are not TOS import evidence |
| IMP-03 | Paste a recovery phrase | Not covered | Partial | Not covered | Partial | Paste button existence only |
| IMP-04 | Normalize spaces and word capitalization safely | Not covered | Not covered | Not covered | Not covered | Input normalization tests |
| IMP-05 | Reject invalid word count | Not covered | Not covered | Not covered | Not covered | Negative test |
| IMP-06 | Reject unknown words and invalid checksum | Not covered | Not covered | Not covered | Not covered | Negative test |
| IMP-07 | Imported address matches the expected TOS address | Not covered | Not covered | Not covered | Not covered | Deterministic vector + local RPC |
| IMP-08 | Imported wallet reaches home with correct balance/history | Not covered | Not covered | Not covered | Not covered | P0 end-to-end UI/integration test |
| IMP-09 | Import cancellation leaves no partial secret data | Not covered | Not covered | Not covered | Not covered | Keychain/data cleanup assertion |

## E. Passcode and secret protection

| ID | V1 requirement | Unit | UI | Device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| SEC-01 | Correct passcode unlocks the wallet | Not covered | Not covered | Not covered | Not covered | Existing UI test creates but does not unlock |
| SEC-02 | Wrong passcode is rejected without data loss | Not covered | Not covered | Not covered | Not covered | P0 negative test |
| SEC-03 | Retry behavior and lockout policy | Not covered | Not covered | Not covered | Not covered | Product policy and tests required |
| SEC-04 | Change passcode | Not covered | Not covered | Not covered | Not covered | P1 if exposed in V1 settings |
| SEC-05 | Recovery phrase requires authentication | Not covered | Not covered | Not covered | Not covered | P0 UI/device test |
| SEC-06 | Recovery phrase is not logged or leaked to pasteboard | Not covered | Not covered | Not covered | Not covered | P0 security audit |
| SEC-07 | Secrets persist in Keychain with appropriate protection | Not covered | Not covered | Not covered | Not covered | P0 device/security test |
| SEC-08 | Screenshot/app-switcher privacy protection | Not covered | Not covered | Not covered | Not covered | P1 physical-device test |
| SEC-09 | Biometric unlock | Out of scope (V1) | Out of scope (V1) | Out of scope (V1) | Out of scope (V1) | Enable only after an explicit V1 scope decision |

## F. Native TOS wallet home and balance

| ID | V1 requirement | Unit | UI | Device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| WAL-01 | Display the correct native TOS address | Integration: Partial | Not covered | Not covered | Partial | RPC account query exists; UI value untested |
| WAL-02 | Display native TOS symbol and balance | Integration: Partial | Not covered | Not covered | Partial | UI formatting and value untested |
| WAL-03 | Zero-balance and empty-history state | Not covered | Not covered | Not covered | Not covered | Seeded account fixture |
| WAL-04 | Manual refresh updates balance | Not covered | Not covered | Not covered | Not covered | UI + RPC fixture |
| WAL-05 | Loading, timeout, malformed response, and retry | Unit: Partial | Not covered | Not covered | Partial | Malformed result covered; timeout/retry missing |
| WAL-06 | Balance uses correct TOS decimal precision | Not covered | Not covered | Not covered | Not covered | Boundary formatting tests |
| WAL-07 | Large balance does not overflow or truncate incorrectly | Not covered | Not covered | Not covered | Not covered | Numeric boundary tests |
| WAL-08 | Only native TOS is shown in the V1 asset list | Not covered | Not covered | Not covered | Not covered | P0 feature-gating UI test |

## G. Receive native TOS

| ID | V1 requirement | Unit | UI | Device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| RCV-01 | Receive button opens native TOS receive screen | Not covered | Not covered | Not covered | Not covered | P0 UI test |
| RCV-02 | Receive screen shows the wallet's TOS address | Not covered | Not covered | Not covered | Not covered | Compare with wallet/RPC fixture |
| RCV-03 | QR code decodes to the same TOS address | Not covered | Not covered | Not covered | Not covered | Decode rendered QR |
| RCV-04 | Copy address writes the exact TOS address | Not covered | Not covered | Not covered | Not covered | Pasteboard assertion |
| RCV-05 | Share action contains the correct TOS address/QR | Not covered | Not covered | Not covered | Not covered | Share-sheet assertion |
| RCV-06 | Incoming native TOS transfer updates balance | Integration: Partial | Not covered | Not covered | Partial | Backend transfer passed; App update untested |
| RCV-07 | Incoming transfer appears in history | Integration: Partial | Not covered | Not covered | Partial | App history untested |
| RCV-08 | No TRC20/Jetton/NFT receive options are visible | Not covered | Not covered | Not covered | Not covered | P0 V1 feature-gating test |

## H. Send native TOS

| ID | V1 requirement | Unit | UI | Device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| SND-01 | Send button opens native TOS send screen | Not covered | Not covered | Not covered | Not covered | P0 UI test |
| SND-02 | Enter/paste a valid TOS address | Integration: Partial | Not covered | Not covered | Partial | App form untested |
| SND-03 | Reject invalid TOS address with clear UI error | Unit: Passed at RPC layer | Not covered | Not covered | Partial | UI error untested |
| SND-04 | Enter valid whole and fractional TOS amounts | Not covered | Not covered | Not covered | Not covered | Decimal boundary matrix |
| SND-05 | Reject zero, negative, excessive-precision, and overflow amounts | Not covered | Not covered | Not covered | Not covered | P0 validation tests |
| SND-06 | Max amount reserves the required fee | Not covered | Not covered | Not covered | Not covered | P0 fee calculation test |
| SND-07 | Optional native TOS comment is encoded correctly | Not covered | Not covered | Not covered | Not covered | Unit + UI assertion |
| SND-08 | Confirmation shows recipient, amount, fee, and comment | Not covered | Not covered | Not covered | Not covered | P0 confirmation UI test |
| SND-09 | Back/cancel returns safely without broadcasting | Not covered | Not covered | Not covered | Not covered | Negative navigation test |
| SND-10 | Passcode signs the native TOS transfer | Unit: Partial | Not covered | Not covered | Partial | App end-to-end signing missing |
| SND-11 | Broadcast succeeds against the three-node TOS network | Integration: Partial | Not covered | Not covered | Partial | Existing demo was not initiated by iOS |
| SND-12 | Confirmed transfer updates balance and history | Integration: Partial | Not covered | Not covered | Partial | P0 end-to-end App test missing |
| SND-13 | Insufficient TOS balance is handled clearly | Not covered | Not covered | Not covered | Not covered | P0 negative test |
| SND-14 | Insufficient fee is handled clearly | Not covered | Not covered | Not covered | Not covered | P0 negative test |
| SND-15 | Node timeout/disconnect supports safe retry | Not covered | Not covered | Not covered | Not covered | Fault injection |
| SND-16 | Duplicate confirm taps do not double-submit | Not covered | Not covered | Not covered | Not covered | P0 idempotency test |
| SND-17 | App relaunch resolves pending transaction state | Not covered | Not covered | Not covered | Not covered | Persistence/RPC reconciliation |
| SND-18 | No token/NFT/TRC20 transfer options are visible | Not covered | Not covered | Not covered | Not covered | P0 V1 feature-gating test |

## I. Native TOS transaction history

| ID | V1 requirement | Unit | UI | Device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| HIS-01 | Load native TOS transaction history | Not covered | Not covered | Not covered | Not covered | P0 API + UI fixture |
| HIS-02 | Render incoming and outgoing native TOS transfers | Not covered | Not covered | Not covered | Not covered | Direction, sign, counterparty, amount |
| HIS-03 | Show pending, confirmed, and failed states accurately | Not covered | Not covered | Not covered | Not covered | Status fixture matrix |
| HIS-04 | Show timestamp, fee, address, amount, and comment in details | Not covered | Not covered | Not covered | Not covered | P0 details test |
| HIS-05 | Paginate without duplicates or missing records | Not covered | Not covered | Not covered | Not covered | Pagination integration test |
| HIS-06 | Empty/loading/error/retry states | Not covered | Not covered | Not covered | Not covered | UI state matrix |
| HIS-07 | New transfer appears after confirmation | Integration: Partial | Not covered | Not covered | Partial | Local-chain event exists; App UI untested |
| HIS-08 | History contains no TRON/Jetton/NFT event UI in V1 | Not covered | Not covered | Not covered | Not covered | P0 feature-gating test |

## J. TOS RPC and local three-node integration

| ID | V1 requirement | Unit | UI | Device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| RPC-01 | Default debug RPC points to local TOS endpoint | Unit: Passed | Not covered | Not covered | Pass at config layer | `TOSRPCSettingsTests` |
| RPC-02 | Release RPC points to approved TOS endpoint | Unit: Partial | Not covered | Not covered | Partial | Add archive/config assertion |
| RPC-03 | RPC URL validation and `/json_rpc` normalization | Unit: Passed | Not covered | Not covered | Pass at config layer | Existing settings tests |
| RPC-04 | Query funded native TOS account | Integration: Passed | Not covered | Not covered | Pass | Live local-network test |
| RPC-05 | Query advancing masterchain | Integration: Passed | Not covered | Not covered | Pass | Live local-network test |
| RPC-06 | Structured node error is preserved | Unit: Passed | Not covered | Not covered | Pass at client layer | HTTP 422 regression test |
| RPC-07 | Timeout, unavailable node, and reconnect | Not covered | Not covered | Not covered | Not covered | Fault injection required |
| RPC-08 | Malformed JSON/result does not crash the app | Unit: Partial | Not covered | Not covered | Partial | Malformed result covered |
| RPC-09 | Three validators remain synchronized during transfer | Integration: Partial | Not applicable | Not applicable | Partial | Add explicit per-node convergence assertions |

## K. Settings required for V1

| ID | V1 requirement | Unit | UI | Device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| SET-01 | Open settings and return to wallet | Not covered | Not covered | Not covered | Not covered | Basic navigation test |
| SET-02 | View recovery phrase after passcode | Not covered | Not covered | Not covered | Not covered | P0 secret flow |
| SET-03 | Edit, validate, save, and reset RPC endpoint | Unit: Passed at config layer | Not covered | Not covered | Partial | Settings UI untested |
| SET-04 | Delete wallet with explicit warning | Not covered | Not covered | Not covered | Not covered | P0 destructive-action test |
| SET-05 | Last-wallet deletion returns to onboarding | Not covered | Not covered | Not covered | Not covered | P0 lifecycle test |
| SET-06 | Legal/privacy/license pages use TOS branding | Not covered | Not covered | Not covered | Not covered | Copy and link audit |
| SET-07 | Legacy feature settings are hidden | Not covered | Not covered | Not covered | Not covered | P0 menu inventory test |

## L. Accessibility, compatibility, security, and release

| ID | V1 requirement | Unit | UI | Device | Overall | Evidence or missing coverage |
| --- | --- | --- | --- | --- | --- | --- |
| QLT-01 | VoiceOver labels/order for every V1 control | Not covered | Partial | Not covered | Partial | Only onboarding/keypad controls partially covered |
| QLT-02 | Dynamic Type and small/large iPhone layouts | Not covered | Not covered | Not covered | Not covered | Multi-destination visual tests |
| QLT-03 | Dark mode and color contrast | Not covered | Not covered | Not covered | Not covered | Visual/accessibility audit |
| QLT-04 | Supported minimum and latest iOS versions | Not covered | Partial on latest simulator | Not covered | Partial | Add CI version matrix |
| QLT-05 | Launch time, memory, and long-running stability | Not covered | Not covered | Not covered | Not covered | Establish baselines |
| QLT-06 | No sensitive logs, telemetry, or pasteboard leakage | Not covered | Not covered | Not covered | Not covered | P0 static/runtime audit |
| QLT-07 | TLS/certificate/proxy failures are safe | Not covered | Not covered | Not covered | Not covered | P0 transport-security tests |
| REL-01 | Debug simulator build | Not applicable | Not applicable | Not applicable | Pass | GitHub CI run `31071145514` |
| REL-02 | Release archive and distribution signing | Not covered | Not covered | Not covered | Not covered | P0 archive/export test |
| REL-03 | Physical-device install and native TOS smoke test | Not covered | Not covered | Not covered | Not covered | P0 release-device test |
| REL-04 | TestFlight upgrade preserves wallet and history | Not covered | Not covered | Not covered | Not covered | P0 upgrade test |
| REL-05 | Privacy manifest, entitlements, and permission strings | Not covered | Not covered | Not covered | Not covered | P0 archive audit |

## Deferred inherited features — excluded from V1 coverage

The repository still contains inherited TON/Tonkeeper modules. Their presence in source code does not make them supported TOS V1 features. They must remain hidden or disabled until separately specified, rebranded, implemented for TOS, and tested.

| Deferred area | V1 status | Release requirement |
| --- | --- | --- |
| TRON and TRC20 wallets, balances, receive, send, fees | Out of scope (V1) | Must not be visible or reachable |
| Jetton token list, details, receive, and transfer | Out of scope (V1) | Must not be visible or reachable |
| NFT list, details, purchases, spam, and transfer | Out of scope (V1) | Must not be visible or reachable |
| Swap and Web Swap | Out of scope (V1) | Must not be visible or reachable |
| Staking and Ethena | Out of scope (V1) | Must not be visible or reachable |
| Buy/Sell, fiat Ramp, and P2P Express | Out of scope (V1) | Must not be visible or reachable |
| DNS management | Out of scope (V1) | Must not be visible or reachable |
| Battery and gasless features | Out of scope (V1) | Must not be visible or reachable |
| DApp browser and TonConnect | Out of scope (V1) | Must not be visible or reachable |
| Sign Data and Sign Raw external requests | Out of scope (V1) | Must not be reachable by deep link |
| Ledger, Keystone, and external Signer wallets | Out of scope (V1) | Must not be visible or reachable |
| Watch-only, testnet, Tetra, and public-key import | Out of scope (V1) | Must not be visible unless separately approved |
| Balance and rate widgets/App Intents | Out of scope (V1) | Remove from V1 target or explicitly disable |

## V1 release gate

V1 may be described as fully tested only when:

1. Every in-scope `P0` scenario has automated coverage at the appropriate layer and passes.
2. Create, import, receive, send, and history each have a complete simulator UI path.
3. A native TOS transfer is created, signed, broadcast, confirmed, and displayed in history by the iOS app against the local three-node network.
4. Required Keychain, lifecycle, install, upgrade, and security scenarios pass on a physical iPhone.
5. Branding and feature-gating tests prove that inherited TON/Tonkeeper and deferred token features are not visible or reachable.
6. Release archive, signing, privacy, and TestFlight checks pass.
7. Every failure links to a defect and every fix retains a regression test.

## Execution record requirements

Each executed case must record: priority, named owner, commit/build, test type, Xcode/iOS/device, network and RPC endpoint, date, result, CI/report link, evidence, and defect ID when failed.

## Current evidence

- UI automation: `TOSWalletUITests/TOSWalletUITests.swift`
- RPC tests: `LocalPackages/core-swift/Tests/KeeperCoreTests/API/`
- Other unit tests: `LocalPackages/**/Tests/`
- Test entry points: `Makefile` targets `test_all`, `test_tos_live`, and `test_ui`
- Detailed run report: `docs/ios-wallet-test-report-2026-08-06.md`
- GitHub CI baseline: `https://github.com/tosnetwork/ios/actions/runs/31071145514`
