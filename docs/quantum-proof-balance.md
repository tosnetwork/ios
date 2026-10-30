# Quantum proof-backed balances

Quantum native balances use the original public creation record and the existing
per-wallet native proof checkpoint. The currently selected RPC endpoint is an
untrusted relay; changing it does not change the wallet's enrollment or genesis
anchor. A read cannot enroll a missing checkpoint.

The reader verifies CP19's signed network ID, requests the account at that exact
masterchain checkpoint, binds it to the retained QSI1 birth identity and checks
masterchain and shard freshness again before returning. Reading a retired or
rescue-only account does not require PRIMARY signing eligibility or CP48 admission.
A balance is not a signing capability, spendable amount, fee estimate or receipt.

Amounts retain the full unsigned 120-bit coin range as `BigUInt`. New JSON uses
canonical decimal strings; older UInt64 numeric caches remain decodable. Quantum
does not load or save the ordinary persisted balance cache. Its presentation uses
native TOS at rate 1, independently of the selected fiat currency, and does not
invent a fiat price or insert unsupported asset placeholders.

Failed verification hides previous numeric values in the wallet header, native
asset list, wallet chooser and token details. Receive remains available; pull to
refresh and the existing periodic refresh retry through proof verification. Reads
are coalesced per wallet loader, with at most two process-wide native readers and
no queue for excess readers. The HTTP relay bounds response sizes and each query
to 20 seconds. Swift task cancellation currently waits for the blocking worker;
it does not immediately interrupt an in-flight HTTP read. Busy reads fail closed.

## Validation

All builds and tests run through the repository Makefile. Relevant targets:

```sh
make test_keeper_core
make test_project_scheme SCHEME=WalletCore \
  TEST_ONLY=KeeperCoreTests/TOSQuantumAccountReaderTests
make test_project_scheme SCHEME=TOSWalletUITests \
  TEST_ONLY=TOSWalletUITests/TOSWalletUITests/testQuantumProofBalanceReceivesFundingAndRefusesPoisonedRelay
make test_v1_static
```

Live tests additionally require a dedicated disposable simulator, a fresh native
self-pay test chain, an independently generated genesis anchor supplied through
`TOS_QUANTUM_GLOBAL_ID`, `TOS_QUANTUM_ROOT_HASH`, `TOS_QUANTUM_FILE_HASH`, and a
`TOS_UI_RPC_URL` served by `scripts/tests/quantum_balance_fixture.py`. The helper
accepts explicit node source, public genesis fixture and test signer paths; it
reads only the simulator's bounded public creation record. It funds the newly
created address from the isolated genesis account using the public regression
seed. This proves reception and authenticated balance reading, not mobile signing.
Never use that helper with production accounts or custody.

The retained 2026-10-27 run used node source `295d5029`, mobile proof pin `1aa8821c`:

- Restored complete KeeperCore: 264 tests, 258 passed, 6 conditional live skips,
  no failures. The new live reader case was also run separately against the real
  chain and passed in 0.598 seconds.
- Actual default creation, signed test-account funding of 10 TOS, authenticated
  display, corrupt-proof refusal, previous-value hiding, ordinary-RPC fake-balance
  positive control, and successful pull-to-retry: one UI test passed in 70.984 s.
  Enrollment UUID, identity and profile remained unchanged. Owned native network
  and relay process groups were cleaned successfully.
- Removing CP19 comparison produced runtime assertion failures (including 5
  queries instead of 3). Truncating serialization to 64 bits failed the maximum
  amount test. Both changes were restored before the full green Core run; the 24
  measured source hashes match the passed UI run.
- Scoped independent review accepted this read-only increment. Its unsupported
  asset-management placeholder observation was fixed. It did not approve the
  whole PR, native verifier or test helper. Cancellation, busy-state presentation
  and deletion-race residue remain non-blocking observations to track.

See `quantum-proof-balance.validation.json` for artifact hashes and the final build
result. Earlier UI and helper setup failures are retained separately and are not
counted as expected negative controls. The actual installed simulator App bundle
was retained independently of later builds.

## Delivery boundaries

The current native proof pin is a recorded stage, not the final unified revision.
This does not complete mobile-signed deployment/payment, transaction-history
acceptance, backup, rescue, migration, legacy-version entry hiding, final ABI and
artifact freeze, or whole-PR review/CI/merge. Widget extensions remain V1-deferred;
the widget controller change has source coverage only.
