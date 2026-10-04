# TOS iOS protocol modernization — 2026-10-04

The functional/test head `3143594ab51e696342da9370acc2d0a2add701db` passed all
47 real-node UI methods and the whole root Make wrapper, including runtime-secret
and performance gates. The complete seven-package suite passed 213 methods,
including five live-chain methods, on the identical product sources committed
as `e6db98c`. Current-head static/artifact checks and
[functional CI 37183642297](https://github.com/tosnetwork/ios/actions/runs/37183642297)
also passed. The unsigned Release archive passed build, artifact and ZIP checks.
The documentation-only delivery head and its CI are recorded separately in the
delivery manifest after this report is committed.

This update starts from iOS `49152555` and follows protocol/SDK reference
`ee5ad71c343eb2227a8bd42d57bea259da4da0ec`. The App is version **1.1.0 (2)**.
Dependencies remain pinned by the existing SwiftPM lockfile.

## Resulting behavior

- New wallets use TOS-domain mnemonic salts and the current TOS V5 contract.
  The signed body contains separate `global_id:int32` and plain
  `wallet_id:uint32` fields, followed by the Ed25519 signature. Frozen code hash:
  `086a86aa9913c0ec52277adbb7e4b5695964dbb8c817ad0c305cdd345bbfac69`.
- Native creation/import discovers and saves Config19 chain identity. Config8
  must report VM version >=6; unknown or incompatible identity fails closed.
  Verification, sequence reads, estimation and broadcast use a captured endpoint,
  so changing node settings during an await cannot redirect the operation.
  Invalid active sequences never become zero. Integer/fee parsing rejects
  floating JSON storage and rounded fractions; totals check UInt64 overflow.
  Deployment estimation supplies sender code/data; active wallets use chain state.
- Existing TON-domain tags, keys, addresses and contract revisions are preserved.
  Import offers explicit legacy restoration; phrases valid in both domains require
  a format choice. Automatic ambiguous detection rejects. Revision changes cannot
  cross derivation domains, and signing checks the derived public key against
  saved metadata. The inherited stored BIP39/SLIP10 derivation is unchanged;
  the baseline V1 already required TON checksum validity for fresh imports.
- Ordinary legacy V3R1/V3R2/V4R1/V4R2/V5R1 sends handle the node's active
  `wallet=false, seqno=null` classification gap through one endpoint-bound
  `getAddressInformation` snapshot. Exact known code, revision, key, wallet ID,
  signature authorization, data shape and reconstructed original address must
  agree. Generic fallback remains restricted to that classification gap and
  rejects a later uninitialized snapshot. Only a typed known empty uninitialized
  wallet may begin deployment. Native and Beta code cannot enter this fallback.
- A shared preflight protects Legacy and Config8/19 RPC BOCs before the pinned
  SDK's unchecked array accesses. It accepts a bounded ordinary V3 BOC format:
  one reachable root-first level-zero cell graph, optional complete start/end index and
  CRC lengths, valid forward references/top-up bits, <=1 MiB, <=16,384 cells and
  depth <=1,023. Exotic/high-level/cache/absent/malformed forms reject; the SDK
  checks CRC values. This is a bounded mobile RPC decoder, not a general BOC codec.
- RPC node editing is available before a wallet exists. Create/import failures
  preserve phrase, name and passcode, clear pending submission before showing the
  error and allow a valid retry. Unknown words, ambiguous domains and invalid names
  remain guarded. The picker chevron is decorative, so tapping its center selects
  the import row on small screens.
- Native History polls endpoint-bound transaction cursors every three seconds.
  Initial/resumed reads, changes and recovery refresh existing observers;
  unchanged reads deduplicate. Cancellation/generation checks suppress stale
  responses and deliveries, including deletion and batched replacement. All
  15 new cursor/poller/RPC/lifecycle methods passed, and preloaded History updates
  were exercised through actual signed transfers.
- iOS 26+ native bars avoid the old custom tab-bar hierarchy exception. Collection
  estimates stay positive; Settings and wallet switching expose semantic controls.
  Existing V1 scope hides scanner, notification, fiat and deferred security/biometry
  placeholders while retaining node, language, theme and authenticated backup.
  Sign Out requires acknowledgement/passcode and removes the wallet. Alert
  presentation preserves UIKit delegate ownership. Blocking Xcode 27 Swift compiler diagnostics
  have explicit capture/error handling; existing nonblocking warnings remain.
- Onboarding keeps DynamicType, a full multiline Configure TOS Node title and a
  44-point target. A flexible visible galaxy fits safe-area/status bounds on SE3
  at Accessibility XXXL. Tests select the real App theme, check background pixels,
  recognize the complete node title and check the whole logo frame.
- Receive emits `tos://transfer/<address>` for both supported wallet formats on
  TOS network profiles; inbound `ton://` parsing is retained. The existing UI case
  decodes actual QR pixels and requires the entire payload, then checks Copy/Share.
  V1 rejects raw/bin/init/TonConnect arbitrary-cell entry points.
- CI selects an installed Xcode >=26, builds the App and runs all package suites
  plus an actual-port1 offline legacy-home regression through the root Makefile.
  Make forwards runner RPC/resource overrides, selects explicit Debug package
  configuration and avoids stale embedded fixture bundles. Test results use
  distinct bundles and explicit simulator identities.

The user wallet remains **Ed25519, compatible with PQ validator consensus**.
ML-DSA/Falcon user-wallet signing and advanced arbitrary-cell signing are outside
V1. Config 43 is not treated as a PQ switch; experimental Falcon requires VM 19.

## Completed validation

Artifacts are retained under
`/Users/tomisetsu/Documents/Codex/mobile-pq-validation-20261004/`.
Paths below are relative to that directory. Local runtime uses Xcode 27
(27A266a), SDK 27.0 (24A430), owned iPhone 17/iOS 27 (24A434), and owned iOS 26.5
(23F77) SE3/17e/Pro Max devices. The isolated three-validator ML-DSA chain uses
node `0ee44a3e3983376c6206f5ac859ae2fe803eafde`, VM 18/global ID 3.
Only public development fixtures were funded/signed; toserver remained read-only.

| Check | Completed result | Evidence and bound |
| --- | --- | --- |
| Current 314 real-node UI | **47/47; whole root Make exit 0** | `ios/314-full47-final/acceptance.result.json`, raw/wrapper/summary and `TOSWalletUITests-20261004T155601-48639.xcresult`. Zero failures/skips/runtime warnings; XCTest execution 2159.670s. Verified runner port 18645; fresh native 100/legacy 25 TOS uninitialized fixtures. |
| Runtime-secret/performance | **Passed in the same whole wrapper** | `ios/314-full47-final/ios-pq-314-full47-root.log`: launch command mean 0.223s/max 0.325s; sampled RSS max 21.5MiB. No claim of production TTFI, continuous peak memory or exhaustive leakage audit. |
| All package methods | **213/213; whole root `make test_all` exit 0** | `ios/core-legacy-full213/acceptance.result.json`. Seven invocations 185+5+2+1+1+1+18; zero failures/skips/runtime warnings, all five live-chain cases actually executed. Reviewed patch 57e7c6 was committed unchanged as e6db98c; only UITests changed afterward. Parameterized iterations are not counted as additional methods. |
| Focused Legacy/network | **21/21; whole root Make exit 0** | 16 new Legacy methods plus five extended network methods; method total 0.872s. `ios/legacy-independent-static-qa/focused21-independent-xcresult-summary.json`; exact code/key/ID/address/state guards and malformed/valid indexed BOC controls. |
| Legacy two-send target | **1/1; whole root Make exit 0** | Frozen UI patch later committed unchanged as 3143594; 120.256s, zero failures/skips/runtime warnings, secret/performance passed. `ios/legacy-credit-targeted-normalized-pass`. Current full 47 repeats the method 94.459s. |
| Frozen 314 root static/build gate | **Whole root Make exit 0** | `ios/314-full47-final/final-make-static.result.json` and `final-make-static-root.log`; exact command `make test_v1_static BUILD_JOBS=2`. Current App compiled for generic iOS Simulator arm64/x86_64, followed by brand boundary and static/build-artifact checks. Log SHA256 `f99f6eb126d4a4c5995d0c96f47138d6987f370e5ff7b34dcc4b3ef3f57acc5d`. The earlier script-only check is separately retained in `final-static.log`. |
| SE3 offline home/layout | **2/2 methods; generic root Make exit 0** | `ios/se3-47ff-offline`, verified port 1: legacy home 27.494s plus four Light/Dark×XS/AXXXL layouts 25.299s. Generic `test_project_scheme` does not include the secret/performance wrapper. Reused at identical App tree ccf0; no fresh 314 SE run is claimed. |
| iOS 26.5 layout matrix | **2/2 methods; eight configurations; whole root Make exit 0** | `ios/layout-47ff-matrix`: 17e 29.700s and Pro Max 28.439s, four theme/text configurations each. Both secret/performance legs passed. Independent original-pixel reports are `ios/visual-47ff-se3` and `ios/visual-47ff-matrix`. With SE3: three methods/12 configurations. App tree is identical; this is 47ff-bound evidence reused on 314. |
| Unsigned Release | **Root Make exit 0; 15/15 inspection checks; independent archive/ZIP review passed** | `ios/release-e6db`: version 1.1.0(2), SDK 27, arm64 device iOS, effective minimum 15.0; seven unsigned frameworks, no provisioning/embedded entitlements. All 114 ZIP file payloads match the archive, all CRCs valid. Current product sources are identical to this archive. |
| Functional CI | **Completed SUCCESS on 3143594** | [Run 37183642297](https://github.com/tosnetwork/ios/actions/runs/37183642297), `ios/ci-314-recipient-fee-ui/acceptance.result.json`, full-log SHA256 `7d67491fe35e95077c4b1f048daf35e86f3c71e6fd0a6bc6ed729929d5c3d362`. App build, all packages and offline legacy home passed. CI skips five unavailable live-chain cases; local 213 included all five. Delivery-head CI is recorded separately after the documentation commit. |

Current full 47 also passed Unicode 0.5-TOS signing/recipient/preloaded History
in 61.210s, exact real-pixel Receive in 45.202s, node persistence/restore 64.091s,
creation error→configure→retry 45.219s and import error→Cancel→retry 46.034s.
Onboarding's four real theme/text configurations passed 48.852s. Max coverage
is fee/cancel UI plus send-all unit controls, not an actual full-balance cashout.
Independent final full 47 filesystem QA corroborates all 47 unique passing methods
against committed source and reviewed eight original 1206×2622 public images:
Legacy/TOS homes, Receive, four actual Light/Dark×XS/AXXXL onboarding frames,
and Legacy Unicode History details. No visible clipping/overlap was found;
the complete logos, node titles, controls and Terms fit. The actual Receive QR
is `tos://transfer/UQD2mnXTMAfVqNeThUDRlckiA_6oOhEXF91xnbaVBY6na7rL`,
with valid friendly CRC16 bacb/workchain 0. It belongs to a newly recreated f69a…
wallet, separate from seeded 8826. Exact report:
`ios/independent-full47-314/ios314-full47-independent-review.result.json`
(SHA256 `1cf7bc3c2fbf99161c453bfeed9d5585c9b2d7bea5635ec904194d4e0f2d4761`).
This selected-pixel review does not certify formal contrast/VoiceOver or create
new iOS 26.5 execution evidence.

## Transaction-bound completion

The new Legacy method starts original 8915 uninitialized with 25 local TOS,
explicitly restores TON metadata, sends 0.01 TOS through the App, relaunches the
stored wallet and sends 0.02 TOS from the active original contract. There is no
external bootstrap. A bounceable EQ4a input exercises the `uninitialized`
force-non-bounce correction. Both original outgoing messages are matched to
recipient incoming cells by hash/source/destination/gross/nonbounced flags.
BOC total fees match canonical RPC fee strings, satisfy fee<gross, and determine
exact positive net/cumulative credit; no generic shortfall is accepted.

Independent current 314 decoding confirms original code hash beginning 20834
and public key beginning 54298c…,
packed wallet ID 2147483409, original 8915 address and actual stored sequence 2,
although the node classifier still returns null. The first sender external has
its original StateInit/signed sequence 0; the second has no StateInit/sequence 1.
Gross 10,000,000+20,000,000 nanos, recipient fees 0+1, exact cumulative credit
29,999,999 and captured sender balance 24,969,838,444. The no-code recipient's
skipped compute is normal coin credit, not mistaken for delivery failure.

The native lost-response first-deployment method passed 54.517s. Independently
decoded original StateInit (code hash beginning 086a86…, public key
beginning a71563…, subwallet 0), signed global ID 3 and
sequence 0 match saved 8826 metadata; actual stored data advances to 1. Captured
sender balance 101,749,782,421. The original 250,000,000-nano outgoing cell matches
workchain -1/all-zero recipient's incoming cell and credit phase, with fee 0/no
outgoing messages. This proves that transaction's net credit. Unrelated faucet
history prevents claiming an entire recipient current-balance delta. UI also
asserts one broadcast/event despite the deliberately dropped broadcast response.

Both proofs are retained in
`ios/independent-completed-method-314/ios314-completed-legacy-native-independent-review.result.json`
(SHA256 `a3be8a649fe832d7e9ab28d6c108e4333c96ce614b64e73e56854a60f7e56fba`).
Five distinct ordinary-contract protocol probes separately deployed/executed
V3R1/V3R2/V4R1/V4R2/V5R1 and delivered exact 1,000,000-nano credits. Frozen real
snapshot fixtures cover all five; App UI deployment/second-send proof is V5R1.
Beta/exotic contract fallback is not enabled.

## Source and release binding

The five product trees are unchanged between package/archive commit
`e6db98c0c894bb5507341a4830e72ebd6103761c` and functional/test head 3143594:

| Tree | Git object |
| --- | --- |
| App | `ccf0ccb9b0608a541ff04191cc6a5865e1adaf26` |
| Core | `5c5686c8d850a14d0cac7222ed92d0b91a125ce1` |
| Core Sources | `e0db4f39b14e029001efd450de77748211769210` |
| TKCoordinator | `02371258270276bfb81525f9e030c5e9c02d495a` |
| TKUIKit | `f31cb1759bba87d14e762e73e79535a3f61ea645` |
| Current UITests | `44e497454ff1c46ae7153dddeaec8f5b82bf8b23` |

Archive app binary SHA256:
`2130d135405e2702205b4f15099e84a93310d9bc5d9af38e24a059d3e9a4acb3`.
Deliverable `ios/release-e6db/TOSWallet-1.1.0-2-unsigned.xcarchive.zip`:
51,266,224 bytes/SHA256
`f374bc2b66c9f5f0002981dcb1da25aeffcb2edf7a3f4e6dc1b58cf0ece589e1`.
Independent review matched all 114 file payloads/CRCs to the actual archive,
not a historical ZIP directory count. Root inspection SHA256
`33660fef5fea382b102f398b99a3548e5c33ee1873abe0f697c8141e2db119b0`;
independent review SHA256
`16708f580efb45991c6eb8ab921f9065d3bc6704854df8d500bbadbe1760effb`.

The effective App minimum remains iOS 15.0; some defaults specify 15.6 but the App
target overrides them. CryptoSwift framework min 11/sdk 18.2, Lottie min 13/sdk 17.2,
other five min 15/sdk 15 are independently parsed Mach-O values; plist build-SDK
metadata is recorded separately. The archive is unsigned and requires signing
and export for physical-device installation.

## Reproduced defects and controls

Earlier attempts are retained as history, not current-head acceptance:

- 3377e5a: 40/45; stale preloaded History despite delivery, unreachable-node alert
  exception, Continue-label queries and a no-op unknown-word mutation. RPC polling,
  UIKit ownership and actual-control/real-input checks repaired these paths.
- 04a1: partial 20/20 stopped to repair a confirmed 375-point SE chevron hit deadzone.
  The decoration no longer intercepts taps; exact-chevron and original right-edge
  regressions remain. b7 then 44/45 exposed pending-loader retry state; both create
  and import catches reset it and preserve recovery data. b458's 46/46 passed but
  independent pixels exposed node-title truncation/false theme labels. 1b15 repaired
  text/themes; its SE pixels exposed logo/status overlap. 47ff repaired safe-area fit.
- 47ff: 46/46 passed the former weak QR assertion, but actual PNG decoding found
  `ton://transfer/` inconsistent with registered `tos`. A discriminating Core RED
  reproduced one failed method/two prefix assertions in 1.285s before the generator
  fix; current full packages and exact-payload UI pass. 41bc's later 46/46 remains
  historical before ordinary active-legacy repair.
- Five ordinary legacy probes reproduced active false/null classification despite
  real execution. Exact-bound fallback repaired send/estimation. Initial focused
  fixture run 15/15 failed resource lookup; Make now forwards the current resource
  parent/configuration. The next 14-pass/two pre-RPC `Cell.empty` fixture crashes were
  corrected with initialized cells. Separately, unchecked SDK BOC indices prompted
  shared preflight plus raw malformed-root/ref/length/depth controls. Current 21 and
  complete 213 runs pass.
- New Legacy target initially failed exact sender lookup because node event hashes
  use uppercase hex. Retained rows prove identical LT/32-byte hash after casefold;
  only textual normalization changed. Normalized target and current full 47 pass,
  preserving all original-message/fee/net guards.
- Omitting native global ID made three of six signing methods fail with nine
  assertions; restored source passed all six. SDK/Python vectors, recompiled FunC
  hash matching and actual VM controls validate signature enforcement and recipient
  action/value/counter. Disabling VM signature checking made a targeted control red.
  VM 0–18 scan establishes ordinary native minimum 6, distinct from ML-DSA 16/Falcon 19.
- Runtime-secret injection failed as expected and restored green, confined to a
  task-owned public-fixture channel and preserving user logs. Literal RPC-macro,
  endpoint-invalid, precompile-sandbox and interrupted attempts are excluded from
  current pass totals. Baseline source inspection disproved a suspected new BIP39
  import regression: strict V1 import checks already existed, and stored derivation
  blob 9ddb6bd91ee3dce55d44e033a0bb21a372f33040 is unchanged.

No old-OS runtime, physical-device, biometric-hardware, distribution-signing,
TestFlight or App Store acceptance is claimed. Existing five inherited Core warning
kinds remain; blocking diagnostics were resolved, not every warning. Layout evidence
covers visible geometry/OCR/theme pixels, not VoiceOver or numerical per-control
contrast certification; white galaxy details remain faint on Light. The secret gate
checks configured public phrases/passcodes in two hours of App logs and the current
clipboard, not an exhaustive memory/privacy audit. No main merge or store publication
was performed.
