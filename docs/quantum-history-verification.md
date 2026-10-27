# Authenticated Quantum history backend

`TOSQuantumHistoryReader` obtains the head from the enrolled wallet's fresh
native account proof, rather than RPC transaction metadata. Each raw BOC is
checked by the portable `tos_proof_verify_wallet_transaction` ABI against the
expected account, transaction hash and UInt64 logical time. The reader follows
the committed predecessor hash/time, bounds each page to 20 transactions and
retains the original proof/checkpoint in its private pagination cursor.

The reader checks wallet identity, proof freshness before/after the walk,
transaction timestamps against the proven shard time, and monotonic times
within a page. Reads for the same wallet are bounded by permits; cancellation
and a 60-second history deadline stop subsequent work. The RPC transport bounds
response size and JSON depth, refuses redirects and checks the JSON-RPC id.
RPC metadata is never an authority for amounts or execution status.

The native codec validates complete transaction layouts while treating message
bodies as opaque. Swift borrows separate owned buffers and limits BOC/result
sizes to 1MiB. UInt64 logical times and 120-bit coin values stay exact; the
account-head integer parser rejects floating-point storage rather than rounding.
The generated proof framework is source-built from the immutable checked-in pin
for device arm64 and both simulator architectures.

`matchesOutgoingTransfer` requires a committed outgoing internal message matching
the sender, recipient, exact amount and body hash, together with the expected
inbound external message. Successful execution alone is insufficient: a +2
send can be skipped. This predicate does not establish recipient credit or
finality.

The frozen public three-transaction fixture covers the formerly unsupported
opaque body and the successful-but-skipped transfer. Additional tests exercise
wide unsigned times/amounts, wrong bindings, malformed layouts, bounded walks
and transport errors. The optional live-history test requires a disposable
network and explicit test environment; a default conditional skip is not a live
network acceptance result.

The product History tab and Quantum native-coin details now use
`TOSQuantumHistoryService` and its native-derived presentation records, without
creating the ordinary event list for Quantum wallets. The UI retains the current
20 records and at most 128 pagination positions, cancels on disappearance, checks
request identity before publishing, clears stale rows on error and retries only
the bounded reader-busy refusal. An interrupted initial read can restart when
the page returns. Details preserve exact decimal money and UInt64 time, display
actual transaction fees and keep message bodies opaque.

The additional public receiver fixture covers compute-skipped/aborted incoming
messages that still credit undeployed accounts: these records are Included,
not failed incoming payments. A skipped outgoing action remains Send skipped.
Product UI tests use a fresh chain and public-source prefunding, then exercise
history/detail, raw timestamp corruption, clearing old rows, restored retry and
coin details. They do not sign payments from phone custody.

Actual protected-custody deployment/payment, durable prebroadcast outbox and fee
budgeting, backup/rescue/migration, final artifacts and release gates remain
required. Run package tests only through the repository Makefile.
