# TOS iOS protocol modernization — 2026-10-04

Validation is in progress. Pending checks below are not release acceptance.

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
- Xcode 27 compiler diagnostics are resolved with explicit ownership and handled
  asynchronous errors. Biometry setup now propagates Keychain failures to its
  caller. CI selects an installed Xcode >=26 and an available simulator, then
  runs the full package suite plus an offline legacy wallet-home UI regression
  through the root Makefile. The UI scheme explicitly receives the RPC override;
  runtime gates select the same simulator as Xcode, including multiple runtimes.

The wallet remains an Ed25519 user wallet compatible with PQ validator consensus.
ML-DSA/Falcon user-wallet signing and advanced arbitrary-cell signing are outside
the enabled V1 surface. Config43 is not interpreted as a PQ capability switch.

## Automated checks

Environment: Xcode 27, iOS 26.5 / 27.0 simulators; disposable three-validator ML-DSA
localnet, VM18, global ID 3. Transactions use public development fixtures only;
the deployed toserver network is not mutated.

| Check | Result | Evidence |
| --- | --- | --- |
| Simulator build and V1 static/artifact gates | Passed | `make test_v1_static`; `/tmp/ios-pq-static.log` |
| Full package suite | Passed before final VM-capability change | 178 tests, no failures/skips; `make test_all`; `/tmp/ios-pq-tests-all-passed.log`. Final full Core rerun passed on iOS27.0: 153 tests, including five live-chain tests; `/tmp/ios-pq-core-final.log`, retained `build/TestResults/WalletCore-20261004T020831-33678.xcresult`. The other packages remain 28/28 passed (181 combined). |
| TOS signing-vector mutation control | Passed red / restored green | Removing signed global ID failed 3 of 6 tests / 9 assertions; `/tmp/ios-pq-global-id-red.log`; retained `build/TestResults/WalletCore-global-id-red.xcresult`; restoration rerun passed all six. |
| UI suite | Full rerun pending; targeted restores passed | Initial two dual-domain restores reproduced the iOS27 tab-bar exception. Both restore choices now pass with the fix and their official addresses; `/tmp/ios-pq-ui-{legacy,tos}-home-green.log`. |
| Offline legacy wallet-home regression | Passed | Generic root Make target, RPC127.0.0.1:1, no proxy/performance; 1/1 passed in66.7s; `/tmp/ios-pq-ui-legacy-offline.log`; added to CI. |
| Layout matrix | Pending | iPhone 17e / iPhone 17 Pro Max, iOS 26.5 |
| Runtime secret gate and mutation control | Passed green / injected red / restored green | `/tmp/ios-pq-secret-gate-{green,red,restored}.log`; public fixture injected into task-owned simulator clipboard, original clipboard restored, existing logs preserved. Post-UI scan pending. |
| Unsigned generic-device release archive | WIP archive passed; final incremental rebuild pending | Initial build ran while UIKit source changed; `/tmp/ios-pq-archive.log` is not final-source acceptance. |

The added regressions cover independent SDK address/signing/key vectors, both
valid mnemonic domains, retained legacy keys/identity, malformed network/seqno
responses, node editing during in-flight operations, deployment versus active
fee estimates, and real URI `bin`/`init` routing to rejected raw transfers.

Physical-device behavior, biometric hardware, distribution signing, TestFlight,
App Store publication, and GitHub final-head CI have not been verified locally.
The app deployment target remains iOS 15.6 (the core package declares iOS 15);
local runtime coverage uses iOS 26.5 and 27.0. No old-OS runtime claim is made.
