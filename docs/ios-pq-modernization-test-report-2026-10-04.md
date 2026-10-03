# TOS iOS protocol modernization — 2026-10-04

Validation is incomplete. The frozen `3377e5a` UI suite finished with 40 passes
and five failures. The follow-up repairs below require a new build and runtime
regressions; prior passing artifacts do not certify the repaired source.

This update starts from iOS `49152555` and follows TOS reference
`ee5ad71c343eb2227a8bd42d57bea259da4da0ec`. The app version is 1.1.0, build 2.
Dependencies remain pinned by the app's existing SwiftPM lockfile.

## Resulting behavior

- New wallets use the TOS SDK's mnemonic salts and TOS V5 contract. The signed
  body contains separate `global_id:int32` and plain `wallet_id:uint32` fields;
  the Ed25519 signature follows the body. The frozen contract code hash is
  `086a86aa9913c0ec52277adbb7e4b5695964dbb8c817ad0c305cdd345bbfac69`.
- Creation/import discovers Config19 and persists the chain identity. Config8
  must report VM version >=6, as confirmed by a native VM 0–18 boundary scan. Unknown
  identity fails closed. Each broadcast/estimate verifies identity against the
  captured endpoint, so editing the node during an await cannot redirect it.
  Invalid active-account sequence numbers fail instead of becoming zero.
  Fees and seqnos reject floating JSON storage, including fractions rounded to an
  integral double, and fees use overflow-checked UInt64 totals.
- First-deployment fee estimation supplies contract code/data; active accounts
  use chain state. The signer checks that the reviewed sequence number remains
  current before signing.
- Existing TON-domain wallet storage tags, contract code, addresses and keys
  remain recoverable. Import explicitly offers legacy recovery. Phrases valid
  in both domains require a format choice; automatic ambiguous detection fails.
  Revision changes cannot cross mnemonic domains, and signing binds the derived
  public key to stored wallet metadata.
- Node configuration is available on onboarding and after create/import errors,
  allowing an unreachable default endpoint to be replaced before wallet creation.
- On iOS 26+, release builds use the existing native system-bars path. Legacy
  tab-bar class replacement and custom blur constraints are restricted to older
  UIKit, avoiding the wallet-home hierarchy exception reproduced on iOS 27.
  Self-sizing collection layouts use positive initial estimates.
  Both navigation-bar paths honor the disabled V1 scanner. Settings and wallet
  switching expose stable identifiers and readable accessibility labels.
  Settings and setup cards now honor the existing V1 scope for notifications,
  fiat-currency controls, Security/Change Passcode and biometry; supported node,
  language, theme and authenticated backup flows remain reachable. The actual
  Sign Out action removes wallet data behind acknowledgement and passcode checks.
- Native History updates are being moved from an unconfigured legacy SSE source
  to endpoint-bound RPC transaction cursors. The poller refreshes after cursor
  changes, initial/resumed reads and connection recovery, deduplicates unchanged
  healthy reads, and stops on backgrounding or deletion. Generation checks
  suppress cancelled requests and queued stale deliveries. A batched delete/add
  reconciles the current active wallet, so dropping an older queued callback
  cannot leave its replacement without updates. This repair is
  implemented for review; its new runtime tests remain pending.
- Alert presentation preserves UIKit ownership of `UIAlertController` delegates,
  addressing the iOS27 exception reproduced when an unreachable node caused
  wallet creation to fail. Native Send Continue exposes a button identifier,
  label and enabled state; input tests query that control rather than its label.
- Blocking Xcode 27 compiler diagnostics are resolved with explicit ownership and handled
  asynchronous errors. Biometry setup now propagates Keychain failures to its
  caller. CI selects an installed Xcode >=26 and an available simulator, then
  runs the full package suite plus an offline legacy wallet-home UI regression
  through the root Makefile. Make forwards the RPC override with Xcode's documented
  `TEST_RUNNER_` environment prefix; the runner validates its URL and expected value
  and logs only the endpoint's scheme, host and port. A scheme build-setting macro
  was observed to arrive literally and was removed.
  Runtime gates select the same simulator as Xcode, including multiple runtimes.

The wallet remains an Ed25519 user wallet compatible with PQ validator consensus.
ML-DSA/Falcon user-wallet signing and advanced arbitrary-cell signing are outside
the enabled V1 surface. Config43 is not interpreted as a PQ capability switch.

## Automated checks

Environment: Xcode 27, iOS 26.5 / 27.0 simulators; disposable three-validator ML-DSA
localnet, VM18, global ID 3. Transactions use public development fixtures only;
the deployed toserver network is not mutated.

| Check | Result | Evidence |
| --- | --- | --- |
| Simulator build and V1 static/artifact gates | Earlier source passed; repaired-source build blocked before compilation | `make test_v1_static`; earlier `/tmp/ios-pq-static.log`. Current brand-only Make check and `git diff --check` passed. `make compile BUILD_JOBS=2` failed at package resolution; `/tmp/ios-pq-compile-repair-sandbox{,-raw}.log`. |
| Full package suite | Earlier Core tree passed; polling repair needs a new full Core run | Core tree `dbd163bde5b8355df80687f74363a5602b252397`: 153/153 on iOS27.0 including five live-chain tests, `/tmp/ios-pq-core-final.log`, `WalletCore-20261004T020831-33678.xcresult`. Other package trees passed 28/28 (181 distinct cases combined). The 15 new cursor/polling/RPC/lifecycle methods are not included in those totals. The repaired-source full Core Make attempt was blocked at package resolution, before compiling or running tests; `/tmp/ios-pq-core-repair-sandbox{,-raw}.log`. |
| TOS signing-vector mutation control | Passed red / restored green on the earlier Core tree | Omitting signed global ID failed 3 of 6 tests / 9 assertions; `/tmp/ios-pq-global-id-red.log`, `WalletCore-global-id-red.xcresult`. Restored source passed all six. |
| Frozen `3377e5a` full UI suite | **Failed: 40/45 passed, five failures; zero skips** | iPhone17/iOS27.0, 3483.314s. `/tmp/ios-pq-ui-final-3377e5a{,-raw}.log`, `/tmp/ios-pq-ui-final-3377e5a-summary.json`, complete `TOSWalletUITests-20261004T040235-58472.xcresult`. Successful cases include actual first deployment/transfer, lost/delayed broadcast-response reconciliation, Max/fee rejection, node editing/persistence, dual/legacy recovery, backup authentication and destructive-action acknowledgement. |
| Follow-up amount diagnostic | Passed 1/1 before the final accessibility/wait repair | 199.606s, `/tmp/ios-pq-ui-amount-diagnostic{,-raw}.log`, `TOSWalletUITests-20261004T050710-67803.xcresult`. Extra hierarchy reads observed `Continue` as enabled StaticText (type48); this does not prove the original failure's exact cause or certify the final control query. Runtime-secret and command-latency/RSS gates also passed for this diagnostic snapshot. |
| Settings/deletion targeted regression | Passed 3/3 on `3377e5a` | 311.597s combined, `/tmp/ios-pq-ui-settings-final-green{,-raw}.log`, `TOSWalletUITests-20261004T034917-56664.xcresult`; stronger home and actual Sign Out assertions. |
| Offline legacy wallet-home regression | Passed with verified endpoint on the earlier App snapshot | Actual runner RPC127.0.0.1:1, generic root Make target, 1/1 in117.625s; `/tmp/ios-pq-ui-legacy-offline-final{,-raw}.log`, `TOSWalletUITests-20261004T031712-48158.xcresult`. Earlier66.7s pass had invalid endpoint forwarding and proves home behavior only. |
| Layout matrix and iOS26.5 wallet-home smoke | Pending | Owned iPhone17e / iPhone17ProMax simulators; no completed matrix claim. The iPhone17/iOS27 full suite's onboarding appearance/text-size case passed. |
| Runtime secret gate and mutation control | Earlier green / injected red / restored green; final-source scan pending | `/tmp/ios-pq-secret-gate-{green,red,restored}.log`; public fixture injected only into task-owned simulator clipboard and original restored. Existing user logs were preserved. |
| Unsigned generic-device archive | Passed on `3377e5a`; superseded by follow-up source changes | Root Make `archive_v1_release BUILD_JOBS=2`, `/tmp/ios-pq-archive-3377-final.log`, `/tmp/tos-mobile-ios-release-3377-20261004/release-summary.result.json`, `build/release-archive/TOSWallet.xcarchive`. Version1.1.0(2), SDK27, arm64, effective minimum15.0; app and seven embedded frameworks unsigned, no embedded provisioning/entitlements. Repaired-source archive remains pending. |

The frozen full-suite source pins were App `8b043e201cb744bd301d35de786ea17a5e0cac6e`,
Core `dbd163bde5b8355df80687f74363a5602b252397`, TKUIKit
`f31cb1759bba87d14e762e73e79535a3f61ea645`, and UITests
`7810b6d866d856d89774dd47dd84d843e713e62c`. They identify the failed run and the
archive candidate, not the later repaired source.

### Findings and repair status

1. The Unicode0.5TOS transfer was delivered once, and RPC value/comment/event
   checks passed, but the already-loaded History screen omitted its new row.
   The native RPC cursor poller/lifecycle repair addresses the disconnected SSE
   update path; no appearance-only or test pull-to-refresh workaround was added.
2. The unreachable-node test reached the actual port9 connection error quickly.
   App process66135 then crashed with `NSInternalInconsistencyException` because
   the router replaced an alert presentation controller's delegate. The exact
   stack is retained in `/tmp/ios-pq-ui-unavailable-node-presentation-3377.log`;
   the router now exempts `UIAlertController`. The recovery path must be rerun.
3. Comment120-byte and amount-positive cases failed their enabled predicates.
   Failure videos show valid input; the amount case's gold Continue was visible
   above the keyboard. The narrow diagnostic passed with extra snapshot reads
   and confirmed a StaticText match. A semantic button identifier and explicit
   existence/current-enabled query replace that ambiguous descendant query;
   the two boundary cases and full suite must be rerun before acceptance. This
   change does not establish the exact original enabled-predicate failure cause.
4. The unknown-word fixture mutation replaced `mansion`, which is absent from
   the new TOS phrase, so it tested a valid phrase. The test now replaces the
   actual first word and asserts both distinctness and the pasted invalid word.

Earlier UIKit home, literal RPC macro, navigation accessibility, stale deletion
selector and V1 inventory failures remain retained in their original logs and
bundles. Endpoint-invalid and interrupted runs are not counted as successful
full-suite evidence.

### Environment checkpoint and remaining validation

After the environment changed to restricted filesystem/network access, both
`make compile BUILD_JOBS=2` and the full `make test_core_swift` target failed
before compilation with xcodebuild exit74 / Make exit2. The recorded errors
include `sandbox-exec: sandbox_apply: Operation not permitted` and unavailable
CoreSimulator/runtime-image service connections. No workaround to disable
sandbox restrictions was attempted. The later source repairs and all 15 new
methods have received static review only; they are not a tested release.

When simulator/toolchain access is available, run the full Core and UI suites
through the root Makefile on the owned iOS27 simulator, then the owned iOS26.5
layout matrix plus a real wallet-home smoke, final static/runtime-secret gates,
and an unsigned release archive on the frozen repaired commit. The existing
normal-transfer test must observe History without a manual refresh. Preserve
`3377e5a` failure evidence and its archive as historical candidates. GitHub
final-head CI and publication remain outside this local checkpoint.

The added regressions cover independent SDK address/signing/key vectors, both
valid mnemonic domains, retained legacy keys/identity, malformed network/seqno
responses, node editing during in-flight operations, deployment versus active
fee estimates, and real URI `bin`/`init` routing to rejected raw transfers.

Physical-device behavior, biometric hardware, distribution signing, TestFlight,
App Store publication, and GitHub final-head CI have not been verified locally.
The app target's effective deployment target remains iOS 15.0, confirmed in every
App target configuration at baseline and current HEAD and in the release archive.
Some project/dependency configurations specify15.6; the App target overrides them.
Local runtime coverage uses iOS 26.5 and 27.0. No old-OS runtime claim is made.
Existing nonblocking package warnings remain, including deprecated API calls and
the best-effort scam-report task/capture diagnostics outside the enabled PQ wallet
flow; this report does not claim a warning-free build.
