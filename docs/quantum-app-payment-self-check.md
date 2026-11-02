# Quantum App payment integration self-check

The App now has a dedicated native-coin Quantum route with exact decimal amount
parsing, recipient/comment/bounce review, existing App passcode authentication,
protected production custody, local signed-message fee estimation, separate final
fee confirmation, and authenticated sender-result lookup. Classic-wallet signing
is not used for Quantum wallets. DNS, jettons, NFTs and withdrawals are refused
by this route. Recipient metadata is checked on the wallet's configured network;
it cannot replace the original raw recipient or an already saved intent.

The published source keeps `Wallet.isSendEnable` false for Quantum. Recovery is
still incomplete: only a durable `signed` request can be re-estimated without
signing again. A submitting/unknown request can be verified, but is not silently
recreated or treated as an unbroadcast signature. Receipt lookup does not release
the authorization. Archival, safe verified-time expiry release and uncertain-write
recovery remain open. Full backup/cold recovery and physical-device custody are
not claimed by this increment.

## Isolated-chain App evidence (2026-10-28)

A temporary unpublished candidate changed only the Quantum availability branch
in `Wallet.isSendEnable`. It retained the production default coordinator,
`WhenPasscodeSetThisDeviceOnly` plus `userPresence` Keychain policy, real App
entropy, original network proofs, native signature verification, simulation and
durable exact-message rules. A public fixture signer funded the new App address;
it never signed the App payment or read its secrets.

Root Make ran the opt-in UI test
`TOSWalletUITests/testQuantumAppSignsDeploysAndVerifiesPaymentOnIsolatedChain`
on iPhone 17 / iOS 27 simulator. It passed with no fixture signing substitute:

- Created a new wallet and funded its undeployed address with 10 TOS.
- Reviewed exact 1.000000001 TOS, raw recipient, non-bounce transfer and comment.
- Entered the App passcode, read protected custody through the production signer,
  and displayed estimated fee 0.003658597 TOS / debit 1.003658598 TOS.
- Durably confirmed the displayed estimate before forwarding the exact BOC.
- Forwarded to a real three-validator chain, delayed the relay response for 12
  seconds then returned HTTP 503; backgrounded and reactivated the App meanwhile.
- Verified the exact sender transaction and retained the original operation,
  BOC hash and fee approval across App termination and relaunch. No replacement
  signature or automatic unknown retry was used.

The authenticated sender transaction was
`54d8aeb6d2468b822f5b0f67c10c57ee773678527e120c2e47411a4960f76750`,
logical time `1274000001`. This proves the sender result; the App does not claim
recipient credit based on relay acceptance. The delay test covers the actual
background path, but is not a demonstrated mutation control for every stale-task
interleaving. Simulator user-presence behavior is distinct from hardware testing.
The test funded before opening the payment reminder page, so it does not prove
the first-user-funding backup-reminder requirement.

Local evidence is retained outside Git under
`/Users/tomisetsu/validation/mobile-quantum-handoff/`:

- `ios-app-payment-candidate-1793192717931480000/`: gatefalse/candidate complete
  source manifests, sole gate patch and SHA, precise command, App/native artifact
  hashes, raw test log and seven public UI attachments.
- `ios-app-payment-ui-enabled-first.log`: successful unpublished-candidate run.
- `ios-app-payment-proxy-20261028-first/`: public funding, exact App BOC capture,
  original-journal dispatch checks and delayed-response events.
- `build/TestResults/TOSWalletUITests-20261028T220715-77992.xcresult` in the worktree.

The availability file was restored byte-for-byte after testing, and every source
hash matched the separately recorded gatefalse manifest. Final gatefalse core
and App/static validation is recorded separately; this UI result is not a claim
that the published Send gate is open or all wallet acceptance tasks are done.

## Gatefalse validation

The restored final source passed the two selected root-Make KeeperCore suites:
24 tests, zero failures, zero skips, 19.240 seconds. Result bundle:
`build/TestResults/WalletCore-20261028T221438-80392.xcresult`; local log
`ios-app-payment-selected-final-gatefalse.log`. This covers exact decimal parsing,
unsigned-only discard, exact saved-BOC recovery in `signed` phase, original expiry
refusal, unknown refusal, cancellation and the existing payment capabilities.

Root Make `test_v1_static BUILD_JOBS=2` then passed on gatefalse source: ordinary
App simulator build, brand/upstream boundary, and V1 static/build-artifact checks.
Local log: `ios-app-payment-static-final-gatefalse.log`. These results are separate
from the unpublished enabled-candidate UI result. Hosted CI on the prior `ee55d120`
head failed its existing legacy phrase-import UI readiness assertion; that failure
is under investigation and is not represented as passing by these local checks.
