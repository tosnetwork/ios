# Original authorization and fresh expiry capability (R03-A)

This increment is read-only authorization groundwork. It does not archive,
unlink, release a slot, sign, broadcast, enable Send or enable unknown retries.
R03 still requires the bounded durable retirement transaction, uncertain-write
recovery, actual chain expiry/release tests and App integration.

A strict shared codec parses the original request's complete header and payload:
network/namespace/wallet/authority/role/epoch/nonce/deadline, execute/configure/
lock/migrate action and their complete tails. It preserves the existing builder's
encoded-request bounds: positive deadline, execution nonce below UInt64.max and
nonexecution epoch below UInt64.max. It does not infer expiry from current chain
counters. Outbox reads, signed recovery and outcome expiry use this shared codec.

A non-Codable capability with a private issuer is minted only from a fresh
original-profile account proof whose **proven shard time is strictly greater**
than the original request deadline. Masterchain time, local time, a cursor,
receipt or nonce advancement cannot mint it. All canonical phases are supported,
including `signing` with an explicitly missing signature/BOC; a later signature
or phase change invalidates the prior binding. Consumers must recheck freshness
and the reread complete authorization under the outbox lock. No release consumer
is added here; uncertain `.pending` files continue to block ordinary reads.

The binding uses stable typed fields: birth cell hash, complete profile/global,
operation/role, original request bytes/root and parsed fields, signing public key,
deploy/phase, exact original signature/BOC bytes with presence tags, visible intent
with exact comment UTF-8 bytes, and fee-approval fields. Equivalent identity cell
encodings are the same birth identity; equivalent-root request/message encodings
with different saved bytes are different authorizations. Receipt capabilities
have the same complete binding but remain separate from fresh expiry capability.
Receipt and expiry readers share two global permits and one per birth identity.

## Evidence and rejected prototype

The first prototype hashed an entire encoded Entry. This was wrong: the SDK's
BOC topological sort chooses from a Set, while Identity.encode reserializes its
cell graph. An initial 50-test pass did not expose the unstable identity encoding;
strict-deadline and freshness controls then failed at an unrelated keyBinding.
Those two controls are **invalid**, not accepted sensitivity evidence. The old
binding control reached its operation assertion but belongs only to that rejected
source; neither its result nor a subsequent old-source 50-test pass substitutes
for the stable implementation's evidence. The SDK dependency was not modified.

The stable implementation passed root-Make payment/coordinator/outbox/self-pay
suites twice: **51 total, 50 passed, one physical-device Data Protection skip,
zero failures**. The final byte-restored run took 50.001s. Tests include 32 repeated
identity reencodings/canonical loads, equal-root/different-original-byte refusal,
all five phases and strict deadline boundaries, missing-BOC transitions, stale
capability consumption, complete binding, damaged proofs, pending-write blocking,
concurrent phase changes and shared receipt/expiry permits.

Three newly compiled controls on that exact stable source reach their designated
runtime assertions: replacing strict `>` with `>=` at issue/consume allows
nonexpired expiry; removing consume freshness permits a stale capability; removing
consume binding permits an altered operation. Each control has its own source SHA,
command, xcresult and raw log. Production source was byte-restored, every frozen
source SHA rechecked, and the full selected 51-test scope passed afterward.

Tests use real native verification with captured public proofs and their recorded
clock. They are not a new live-chain expiry/release run, physical-device acceptance,
receipt/slot-release integration, App acceptance or hosted-CI success. A current
ordinary App/static build is still required separately; prior App artifacts are
not reused as evidence for this core change.

Local evidence stays outside Git in `/Users/tomisetsu/validation/mobile-quantum-handoff/`:

- `ios-r03-a-1793196105085371000/`: rejected prototype, original source hashes,
  first 50-test pass, invalid/old-scope controls and restored old-source run.
- `ios-r03-a-stable-binding-1793196955036576000/`: stable source manifest, exact
  original/control variants, control/final commands and raw logs, restored SHA,
  and accepted-verdict index.
- Stable baseline xcresult: `build/TestResults/WalletCore-20261028T231610-97333.xcresult`.
- Stable restored xcresult: `build/TestResults/WalletCore-20261028T232138-1484.xcresult`.
