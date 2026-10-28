# Payment quote and confirmation coordinator self-check

This increment connects prepared Quantum intents, the protected production
signer, the durable outbox and the native local simulation capability. The App
Send route remains disabled until its confirmation and authenticated receipt
flow are implemented and accepted. Passing these tests is not phone payment.

## Authorization, fee basis and call order

The two user actions are distinct: authorize local signing/estimation of the
visible intent, then confirm the displayed estimate for broadcast. The App must
apply its declared authentication gate before the first call. The public
coordinator constructor uses the existing protected seed custody; only its
internal test initializer can replace signer/transport/broadcaster closures.
No product verification-bypass or fee-vault path is added.

Preparation remains a fresh account/network/retirement-policy capability. Before
signing, its wallet ID, birth identity/profile and custody account/generation are
checked against the original creation record. Reservation and the signing phase
are durable before key access. The actual signature is verified and its exact
external BOC durably saved before local simulation. Any cancellation or failure
after signing can begin retains the authorization rather than issuing another.

Simulation requests the latest target: an unrelated balance read may have
advanced the persisted checkpoint since preparation, so forcing the earlier
target would needlessly trigger rollback refusal. The native call authenticates
its account and complete execution configuration at one target under the original
anchor and executes the exact signed message with real verification. The result
capability records anchor/request/message digests and the local verification time.
Fee consumers must bind all three byte sequences and enforce the confirmation
window; the local estimate is never a receipt or authenticated balance-cache write.

Only an executed ordinary transaction with successful compute/action phases,
no abort/destroy/no-funds/skipped action and exactly one matching internal output
can produce a quote. Sender, destination, value, bounce and exact body hash must
match the visible intent; the inbound message root must match the stored BOC.
All money uses canonical decimal strings/BigUInt bounded to 120 bits. Fees equal
the simulation's authenticated observed balance minus expected balance minus
the exact output value. Subtractions check ordering first. Earlier preparation
balances are not mixed into this equation, and transaction `total_fees` alone
is not used as full cost.

Quotes expire at the earlier of the original authorization deadline and 30
seconds after native verification. This is a local refusal policy, not a chain
fee cap. Explicit refresh uses the same operation/request/deadline/signed bytes
and never accesses the signer. Consumed or expired requests require receipt
reconciliation. A quote cannot confirm a replacement operation or changed BOC.

Submission re-reads the durable entry under the outbox lock, checks the native
quote capability again, then durably saves confirmation metadata and `submitting`
before exposing bytes to transport. The generic raw submission API refuses
entries with a payment intent. Approval metadata is not a reusable capability;
stored amounts/hash are revalidated on read. Both RPC acceptance and transport
failure retain `unknown`; cancellation does too. RPC responses never mean paid.
The quote is checked again after lock waits/full fsync and immediately before
network dispatch. A refusal there keeps the signed slot and unknown attempt.

## Bounds, lifetime and failure evidence

The coordinator admits at most two workers globally and one per wallet ID.
The outbox independently has one slot per birth identity across wallet IDs/roles.
Cancellation is lock-protected; its permit is retained until the worker completes.
Each job has a fixed 60-second monotonic budget; the same cancellation/deadline
predicate reaches proof and broadcast HTTP receives, in addition to their own
20-second query bounds. The native callback checks before and after each query.
Bounded synchronous native execution is not preempted mid-call. Every continuation completes
once. Per-call contexts/buffers and quotes have no global cache or growing queue.
The existing 64-entry/2 MiB journal and 1 MiB message limits remain; reservation
leaves 2 KiB for bounded confirmation fields. Native bounds and phone RSS gates
remain separate. No secret seed is put in the journal, query, result or log.

Root Make tests run the real source-built framework, full account/config proofs,
production coordinator/outbox path and public fixture signing primitive. The
injected broadcaster asserts that the actual durable record already contains the
confirmation and exact BOC. These are local public replay tests, not Keychain
user-presence, fresh-chain broadcast or inclusion evidence. The existing prepare,
outbox/account-reader and proof bridge regressions remain in the selected run.

Initial failures are retained: a fixture initializer captured an uninitialized
property; then the default empty message body had no precomputed hash and crashed
the quote path. The local builder now constructs the canonical hashable empty
body, with an explicit regression. A test also incorrectly reused the older host
message's cost and guessed a total-fee split. The actual Swift message has relaxed
source/creation fields and an inline empty body, so it is a different input. The
test now pins its measured full deduction and checks that `total_fees` undercounts
that deduction, without inventing a split from the older message.

Independent review of the initial coordinator requested two corrections. An
actual read-only journal directory during cancelled broadcast showed that raw
Foundation write error 513 was masked as CancellationError; Cocoa/POSIX storage
errors now keep their original identity. A clock that advances 31 seconds after
the pre-write sample showed a stale quote could reach broadcast after durable
publication; the final freshness check closes that gap. Both original failures
and the corrected regression are retained, without weakening their assertions.

Compiled source controls must reject using total fees alone, omitting fresh-quote
validation, omitting pre-broadcast persistence, reusing a quote for a replacement
operation and dropping exact-message capability binding. Raw failure/restoration,
source hashes, commands and final results are indexed in the companion memo.
Only the restored source may be reviewed or pushed. App compile/brand/static,
independent exact-head review and relevant hosted CI remain distinct gates.

Still incomplete: App confirmation/authentication UI, authenticated settlement,
expiry and uncertain-write recovery, fresh-chain deployment/payment/receipt,
Android parity, backup/recovery, physical-device acceptance and final release
review/CI/merge. No pending or skipped gate is counted as passed.
