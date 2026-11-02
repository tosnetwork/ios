# Quantum payment outcome reader: scoped self-check

This change adds read-only reconciliation for the original durable self-pay
authorization. It preserves the native message bounce flag and adds a strict
single-payment predicate. It does not change the native VM, consensus rules,
proof source pin, custody implementation, or the closed Quantum Send entry.

The reader loads the original creation record and validates the journal entry
against its identity and network profile. It obtains the transaction head from
an authenticated account proof, verifies each raw transaction against that hash
and logical time, and follows the committed predecessor chain. RPC amounts,
statuses and transaction identifiers are not evidence. Before publishing, it
checks that the same journal operation and exact signed BOC are still present.

A `senderSent` receipt requires the exact external message, successful ordinary
compute/action phases, no abort/destruction, no skipped actions or extra fee
currencies, and exactly one internal output with the authorized sender,
recipient, amount, bounce and body hash. It does not establish recipient credit.
`includedWithoutExactTransfer` describes the matched transaction conservatively;
it does not mean the payment was never sent or that funds were refunded.

Each page contains at most 20 transactions. A private, non-Codable continuation
binds the wallet ID, operation, identity, profile and exact BOC to an authenticated
historical predecessor. It retains the original shard time and checks timestamp
ordering across pages. Every page separately obtains a fresh account observation;
historical evidence never becomes a current balance or expiry capability. The
walk stops at the exact message, so a found receipt does not depend on fetching
unrelated older transactions beyond the node's retention window.

There are at most two concurrent reader jobs and one per birth identity, shared
by aliases with different local IDs. Jobs have a monotonic 60-second cancellation
boundary, propagate cancellation to HTTP, and refuse a late result. They do not
enqueue more work. A missing signed BOC, damaged proof, changed operation, busy
reader or cancellation leaves the original authorization untouched.

Expiry is observed only when fresh proven account-shard time is strictly beyond
the signed deadline. Local time, masterchain time alone and advanced counters
cannot substitute for that observation. A false expiry flag is not a validity
or signing grant. This reader never signs, broadcasts, archives, unlinks or
releases an authorization. In particular, a successful receipt does not release
the slot before deadline: storage deletion/redeployment can invalidate a simple
counter-consumption argument.

Verification is indexed in the companion memo's
`IOS-PAYMENT-OUTCOME-20261028.json`. It distinguishes controlled-clock recorded
proof tests, real three-validator core execution with the public fixture signer,
native-backed mutation controls, skipped conditional tests and hosted CI. The
real test exercises 20+2 pagination while the head advances and rejects reuse by
another fully enrolled local wallet ID. Original BOCs/proof transcripts are
exported from XCTest attachments, including on failure. The external root and
transaction linkage were also checked with the independent vendored Python BOC
parser. Fixture history activity is not labelled as independently verified
payment success.

The App confirmation/authentication flow, protected App custody payment and first
deployment, recipient acceptance, durable terminal summaries, expiry/uncertain
write recovery, Android parity and device acceptance remain separate required
work. This increment does not complete R03/R04 or enable Quantum Send.
