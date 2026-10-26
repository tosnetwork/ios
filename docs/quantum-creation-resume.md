# Interrupted Quantum creation

New Wallet can resume an interrupted self-pay enrollment after the existing
passcode is confirmed. It retains the original UUID, QSI1 birth identity and
locally provisioned network anchor. Editing the currently selected network does
not replace an enrollment's profile. This is creation recovery from retained
local material, not backup restoration or an independent rescue-custody claim.

The main controller reads the UUID-indexed encrypted mnemonic through the
existing repository. The creation service reads fresh configuration through the
original private proof checkpoint, checks global ID/namespace and rederives both
birth keys before any role write. Existing protected roles are opened and
compared; only an absent item permits insertion. Access errors, corrupt records
and mismatched keys cannot authorize replacement. A concurrent duplicate insert
is accepted only after reopening and matching the stored key. All incoming and
intermediate seed buffers are consumed and wiped.

After both roles and recovery material exist, proof freshness is checked again,
then the main wallet is durably published. An atomic public `published` marker
closes the creation journal without re-encoding its original QSI1 payload. A
failed journal close is logged for reconciliation after successful main
publication; it does not report a failed wallet creation. Completed records are not proposed as pending after
a wallet is removed; normal wallet removal/sign-out also cleans their creation
metadata. The Quantum deletion path and sign-out propagate main-registry write
or removal failures before publishing successful wallet-store events. This is a
recoverable sequence of stores, not one transaction across Keychain and files.

The public enrollment directory contains at most 64 records, each at most
32 KiB. Enumeration stops at the limit before decoding files. Valid records must be
ordinary files with a matching UUID; directory permissions are checked. A scan
isolates unreadable/stray entries instead of failing every enrollment. Reads and
closing a specific journal never scan unrelated entries. New records are staged
then exposed with an exclusive hard link; closing uses an atomic rename. A
partially written staging file cannot become a live record. New
creation records use account/generation/wallet ID zero and ready rescue policy.
Only published state can change; journal closing checks the retained profile and
identity before replacing the same record. Missing or corrupt recovery material
is refused, without replacing existing custody or inventing a new birth identity.
The UI displays six entries per page and permits explicitly discarding one
unregistered enrollment. Unpublished, readable entries with a usable recovery vault require
the existing password and delete only their UUID-indexed roles/mnemonic and
checkpoint. Published or damaged entries, or an absent vault, permit public-file cleanup only;
unknown private material is retained. Registered wallets are protected from this
entry point. Inventory, resume and discard strictly read the persisted main registry;
read errors are refused even if the startup cache is empty. UUID comparisons are
case independent. Discard repeats the registry and unpublished identity checks
after the password prompt. A failed registry read shows recovery unavailable
without offering destructive actions. Capacity can be recovered without signing out unrelated wallets.
At capacity, the UI offers management and hides creation until space is available.
Warm retry retains the same enrollment UUID after mnemonic persistence.
Checkpoints created before a public record is saved are reclaimed on failure;
normal removal/sign-out also clean the associated checkpoint directories.

## Author checks and validation scope

- Followed creation UI, main registration, encrypted mnemonic repository,
  protected roles, proof-session enrollment/read and deletion/sign-out callers.
- Recovery is separate from chain authorization: stored metadata alone cannot
  produce signing authority; the original checkpoint and fresh native policy are
  required. Current authority rotation, payment and rescue are separate flows.
- Tested partial role persistence, repeated recovery, unchanged UUID/identity/
  profile, wrong birth keys, policy/namespace changes, late proof expiration,
  bounded/corrupt/transplanted records, completion and scoped cleanup.
- Removing birth-key validation produces a runtime assertion failure before
  restoring the source. The restored focused suite passed; this control predates
  the additional journal/deletion work, whose final regression is tracked below.
- Latest full KeeperCore result: 255 total, 250 passed / 5 conditional live
  skipped / 0 failed. Controller-level cases cover malformed and partial entries,
  unrelated creation/closing, capacity recovery by scoped discard, invalid
  password/custody failures, published/registered protection, strict disk reads
  after a corrupt-registry restart, lowercase UUIDs, conflicting saved identities
  and public-only cleanup without a usable vault.
- The initial reviews rejected journal availability/capacity and subsequently
  the empty-cache cleanup decision. Those findings were fixed and the scoped
  final review accepted N1 and B1/B2/M1. It is not approval of all PR8.
- Latest real live UI: one passed, including the exact durable-registration I/O
  failure, same-UUID warm retry, damaged-public-file management, process death,
  passcode recovery and publication with unchanged identity/profile hashes.
  Five app-hosted custody tests and 28 component tests also passed on this source.
  The normal dual-architecture App/static checks passed on that source;
  the final legacy-update hardening rebuild remains running.
- A marker test previously detected changed serialized QSI1 bytes during
  re-encoding; closing now preserves the original encoded identity. Earlier setup,
  compilation and packaging failures are retained separately from successful runs.
- The scoped review identified an inherited cached-update path that could
  remove or replace an unreadable registry. Legacy updates now use the strict
  persistence path. The real settings-toggle regression failed before the fix
  and passed afterward for cold and preloaded caches within the full255 run.
  A separate follow-up review accepted this change; it ran no tests itself.
  Legacy nonthrowing callbacks still cannot report persistence errors; their
  existing UI events are outside the durable Quantum deletion path.
- Simulator success is not physical-device user-presence acceptance, backup
  recovery, signed deployment/payment/migration or complete default-wallet
  readiness. The broader handoff remains incomplete.

## Real I/O fixture

`scripts/tests/quantum_creation_resume_fixture.py` is a loopback shim for a fresh,
dedicated simulator. Supply `--device`, `--bundle-id`, `--port`, `--upstream` and
an unused `--out`. It refuses an existing main registry, exclusively creates an
empty directory at the registry file location, and removes only that owned empty
fault on release. This makes the real main-registry read/write fail after role
storage; it adds no production fault-injection hook. Control replies contain
only the public UUID, journal phase and hashes of the birth identity/profile.
Do not publish the native node's private runtime directory.

Run the live UI through Make with an independently provisioned anchor:

```sh
make test_project_scheme SCHEME=TOSWalletUITests \
  TEST_ONLY=TOSWalletUITests/TOSWalletUITests/testQuantumCreationResumesAfterDurableRegistrationFailureAndRelaunch \
  TEST_DESTINATION="$TEST_DESTINATION" TOS_UI_RPC_URL="$FIXTURE_RPC_URL" \
  TOS_QUANTUM_GLOBAL_ID="$GLOBAL_ID" TOS_QUANTUM_ROOT_HASH="$GENESIS_ROOT" \
  TOS_QUANTUM_FILE_HASH="$GENESIS_FILE"
```

The UI test requires the precise main-registry error, terminates the app, releases
the fault, and resumes with the original passcode. It checks the journal closes
while UUID/identity/profile hashes remain equal, then verifies the address after
another relaunch. Missing anchor parameters cause a skip, not acceptance.
Use the documented [hosted workflow](quantum-hosted-custody-tests.md) on the same
installation to verify actual role keys and signatures. Normal App packaging
must be rebuilt after hosted tests so test bundles are not shipped.
