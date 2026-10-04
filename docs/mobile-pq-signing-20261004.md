# ML-DSA / Falcon wallet signing and verification

This change adds separate PQ wallet identities under **Settings → PQ Wallets**.
The selected ordinary native TOS V5 wallet pays deployment and transport fees.
Only the PQ key authorizes spending the PQ account. Ordinary recovery phrases,
legacy addresses and ordinary signing rules retain their existing profiles.
An ordinary mnemonic is not silently converted into a PQ seed or account.

## Frozen protocol

The contract fixtures are pinned to TOS source
`9d470d7ccf809a5960ac68c3092b2551830d995d`. The isolated Linux validation checkout
`ee5ad71c343eb2227a8bd42d57bea259da4da0ec` has identical production source trees;
its differences are CI/documentation. The tested chain was a disposable VM19
three-node localnet, separate from the operator's existing VM18 nodes.

| Profile | Public key | Signature | Minimum VM |
| --- | ---: | ---: | ---: |
| ML-DSA-44 | 1312 bytes | 2420 bytes | 16 |
| TOS Falcon-512 padded v1 | 897 bytes | 666 bytes | 19 |

ML-DSA uses the pure-signature context `TOS-AUTH-ML-DSA-44-v1` over the canonical
32-byte AUTH commitment. Falcon signs the 97-byte domain/workchain/module/commitment
message with the chain's strict padded verifier. This is the TOS experimental
Falcon profile; it is not a claim of a finalized FN-DSA encoding or FIPS validation.

The immutable verifier module is a StateInit-derived address. The Wallet V5 account
starts with classical authentication disabled, zero Ed25519 key, no extensions,
and module-only authority (mode 2, epoch 0, nonce 0). There is no classical/PQ
fallback. Every AUTH request binds network, account, epoch, nonce, expiry and payload.
Only native TOS transfers with canonical UTF-8 comments and send mode 3 are exposed.
The request's signature is checked locally before the classical payer signs its
transport. Canonically tagged addresses are required in both requests and messages.

The verifier checks the PQ signature, then forwards the original authenticated
request. The account checks the verifier source, authorization mode, network,
account, counters and expiry before emitting its transfer. A fresh forged AUTH
sent directly from the fee wallet is rejected with 1800; malformed signatures
are rejected with 1808 and replayed requests with 1804. Replay rejection can
produce a legitimate bounce returning transport funding to the verifier; that
bounce is not an authorized asset transfer or a recipient receipt.

## Keys and backups

Both platforms compile the same portable C implementation: mldsa-native v2.0.0
`834a90d5e846ffa1e1611bd24e160bb2e9b86d35`, and Falcon-impl-20211101 archive
SHA256 `d9f982bd825b9903b57b686d6d26018dac173a1dff09f224cc39302f9d85a595`.
Vendored source hashes and licenses are recorded in `PROVENANCE.json`; licenses
are included in the application and accessible from the PQ wallet screen.

Seeds are 32 bytes from the checked OS CSPRNG. Every signature obtains fresh OS
entropy. Expanded secret keys and native temporary buffers are wiped before
returning; managed buffers use best-effort clearing. Managed runtimes, OS copies,
and process compromise prevent a general claim of complete memory erasure.
Falcon seed recovery uses the fixed `TOS-MOBILE-FALCON512-SEED-v1` domain. The
restored public key must equal the registered identity before signing.

A PQ backup is an authenticated, portable 121-byte capsule, Base64 for sharing:
`TOSPQB01`, algorithm byte, signed network ID, SHA256(public key), 16-byte salt,
12-byte nonce, 32-byte encrypted seed and 16-byte GCM tag. PBKDF2-HMAC-SHA256
uses 600000 iterations and a 256-bit AES-GCM key; the entire 61-byte header is AAD.
Passwords use identical UTF-8 encoding on both platforms, including Unicode;
the current input minimum is 12 UTF-16 code units. Only encrypted capsules are
exported. Wrong password, network, algorithm, public-key binding, tampering,
duplicate identities and overwriting an existing seed fail closed. Losing device
key material requires an encrypted backup and its password; ordinary mnemonics
cannot recover these PQ seeds. Algorithm changes require a new account.

## Submission and receipt handling

One user-selected RPC endpoint is pinned throughout the screen's operation session.
The app validates chain identity, active code/data, immutable verifier and counters,
shows the native payer's estimated submission fee, then asks for payer authentication.
Verifier/account execution fees come from funding and balances; the displayed
payer estimate is not a total execution quote. The verifier's storage deposit is
not withdrawable. Unused transport funding is credited to the PQ account.
Both fee-payer sequence and PQ counters/expiry are rechecked after authentication.

Public pending metadata is persisted before broadcast. A timeout or restart never
causes an automatic resend. New submissions to the same PQ account are blocked
until the previous operation is reconciled or its fee request is provably expired
with the original payer sequence still unused. A changed sequence or nonce alone
never proves delivery.

Reconciliation binds the exact external message hash, then each original outgoing
message hash through fee payer → verifier → PQ wallet → recipient. It checks
successful compute/action for sending contracts, exact destination and value,
and a transaction-bound recipient receipt. A passive uninitialized recipient can
credit the exact incoming transfer with compute skipped for `no_state`; this is
credited delivery, not successful contract execution. Rejected operations require
an aborted receipt with no non-bounced asset output. Partial/unknown outcomes
remain unresolved. These receipts use the selected node as trust anchor, not an
independently verified light-client proof. The current lookup is bounded to the
latest 64 transactions per hop; missing archival receipts remain unresolved.

## Reproducible tests

All signature/backup/contract/receipt fixtures contain public test material only.
Golden commitments are independently generated chain-wire vectors, not official
algorithm KATs. The independent ML-DSA interoperability fixture comes from OpenSSL
3.6.3; backup vectors come from Python PBKDF2 and AES-GCM, including Unicode input.

```sh
python3 scripts/test_pq_native.py --library "$PQ_LIBRARY" \
  --interop scripts/fixtures/tos-pq-openssl-interop.json --out "$OUT/native.json"
python3 scripts/test_pq_vm.py --tos-root "$TOS_ROOT" --emulator "$TOS_EMULATOR" \
  --wire "$OUT/ios-public-wire-1.json" "$OUT/ios-public-wire-2.json" \
         "$OUT/android-public-wire-1.json" "$OUT/android-public-wire-2.json" \
  --out "$OUT/vm.json"
```

Mobile GUI tests bind the sender output to the recipient transaction using the
serialized BOC message hash, and assert exact net credit after the BOC-bound fee.
An already-funded no-code recipient can pay storage fees on a repeated run; the
tests never replace this accounting with a gross-value assertion or tolerance.

The actual transaction emulator checks successful original-message forwarding,
account action success, exact recipient credit less fees, wrong signatures,
replay, unchanged authority on rejection, and pre-activation VM15/18 rejection.
A verifier-always-accepts mutation was caught by the wrong-public-key negative;
the unchanged backend then passed the green suite again.

For actual full-node tests, start an owned, disposable localnet with network ID 3,
VM19, RPC28545 and control28745 using the pinned TOS tree/build. Use its Python
validation environment (`pytosiq_core` and the TOS test harness). Never point these
funding tests at an operator's production network. Put the two initial public iOS
wire records in `$OUT/live/initial/`. The runner writes `ready.json` with chain time
and current counters, then waits for fresh `ios-live-1.json`/`ios-live-2.json` exported
by the mobile signer. After those cases, it writes `android-ready.json` and waits
for fresh Android records. Export tests accept `TOS_PQ_CHAIN_TIME`/`TOS_PQ_NONCE`
on iOS and instrumentation arguments `pq_chain_time`/`pq_nonce` on Android; nonce
input is either one value or the two comma-separated algorithm values.

```sh
python3 scripts/test_pq_live.py --tos-root "$TOS_ROOT" --build "$TOS_BUILD_DIR" \
  --workdir "$LOCALNET_DIR" --records "$OUT/live"
python3 scripts/test_pq_live_authority.py --tos-root "$TOS_ROOT" --build "$TOS_BUILD_DIR" \
  --workdir "$LOCALNET_DIR" --records "$OUT/live"
```

Four actual mobile signatures (both platforms × both profiles) passed on the
owned Linux Release full-node chain, with exact recipient credit, independent
bad-signature rejection and replay rejection. Fresh-counter wrong-verifier-source
controls passed for both profiles. Production nodes, DNS and public RPC settings
were not modified. Public `rpc.tos.network` was not used.

## Recorded local validation

The following evidence was collected on 2026-10-04 in the isolated validation
workspace. The final regression logs and commit-bound manifest are retained with
the validation artifacts; failed setup/diagnostic runs are retained as well.

| Check | Recorded result |
| --- | --- |
| Android complete PQ App UI | Both profiles passed: create, protected device-key storage, paid deployment, signed transfer, receipt/history reconciliation, deletion |
| iOS App-hosted PQ UI | Both profiles passed; exact deployed/delivered statuses, 186.142 seconds |
| Mobile-to-full-node signatures | All four platform/profile combinations passed on Linux Release VM19 |
| Chain rejection controls | Wrong signature 1808, replay 1804, fresh wrong authority source 1800; no unauthorized recipient credit |
| Native negative/interop tests | Passed, including independent OpenSSL ML-DSA fixture and verifier-accepts-all mutation detection |
| Actual transaction VM | All four exported mobile signatures passed forwarding, action, recipient credit, replay and pre-activation controls |
| Android optimized Release artifact | Four PQ JNI ABIs passed ELF/ZIP 16KB alignment; cryptography notices packaged |
| Backend provenance | Both platform trees are byte-identical; all vendored source hashes match the manifest |

The Android root emulator runner includes 52 scenarios when run from the start:
44 ordered product UI methods, three native page-size checks and five PQ
crypto/repository/receipt methods. Use an owned fresh localnet and task emulator.
Fund the public legacy fixture
`0:8915a85ac195336246b8bb31537969ecfa840d7e86b454d54e027f1ef012675c`
with 25 test TOS while still uninitialized; fund the ordinary fixture from
`scripts/test_v1_localnet.sh` and populate its pagination history before the runner.
The legacy regression intentionally requires a fresh first deployment.

Python assertion-based test scripts reject optimized Python execution (`-O`).

## Release boundaries

This is implemented local validation, not production activation or a store release.
Falcon must remain unavailable on VM18. Android API24/25 provider compatibility
uses the lightweight SHA256 PBKDF2 implementation without SHA1 fallback; runtime
validation here uses API36 with actual 16KB pages, not an older physical device.
No physical iPhone is connected. Device-passcode removal, biometric changes,
reinstallation, background locking, real-device user presence and device-loss
recovery must be checked on a physical iPhone before distribution. A simulator
can exercise App Keychain APIs but does not establish physical-device protection.
Neither platform claims hardware PQ signing, a side-channel certification, or
independently proved RPC consensus/finality.

## iOS integration

PQ seeds use nonsynchronizing Keychain records with
`WhenPasscodeSetThisDeviceOnly` and `userPresence`, with no weaker fallback.
App PIN confirmation precedes secret operations; OS user presence also gates seed
retrieval. The App uses a shared actor for registry mutations, and hides the PQ
screen while inactive. PBKDF2 uses CommonCrypto; authenticated encryption uses
CryptoKit. The core package links the shared C backend for arm64 and x86_64.

```sh
make test_project_scheme SCHEME=WalletCore
make test_project_scheme SCHEME=TOSWalletUITests \
  TEST_ONLY=TOSWalletUITests/TOSWalletUITests/testPQWalletsCreateDeploySignReconcileAndDeleteBothProfilesOnLocalTos \
  TOS_UI_RPC_URL=http://127.0.0.1:18545
make compile
make archive_v1_release
```

The independent WalletCore test host lacks Keychain entitlements (-34018), so its
protection test verifies propagation of unavailable protection rather than proving
a device-user-presence path. App-hosted simulator testing is reported separately.
The full UI test uses only the owned local chain and public regular-wallet fixtures.

## Unified development protocol baseline

The `codex/unify-protocol-v16` branch uses protocol version 16 for both
ML-DSA-44 and Falcon-512 padded. Both profiles reject versions below 16.
Node support must come from the matching unified TOS branch; the version
number alone cannot distinguish older development binaries. Recreate
development chains with its genesis configuration before using this baseline.
Earlier VM19 measurements above remain historical evidence of the prior head.
