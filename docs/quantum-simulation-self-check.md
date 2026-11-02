# Local simulation session boundary

This increment updates the source-built proof pin and adds a session call needed
by the dedicated Quantum payment confirmation flow. It does not enable Send or
call custody/broadcast. A `LocalSimulation` is a distinct native capability with
an estimate payload; it cannot be supplied where a `BoundRead` is required.

The pinned native function holds the same checkpoint lock as ordinary reads,
requires existing enrollment, acquires same-target account/full configuration,
authenticates and executes the exact signed message locally, then fsyncs and
commits next-state before publishing the estimate. Missing state is refused,
never recreated by simulation. The session passes its original anchor/private
directory and has no initialization or reset option for simulation.

The Swift boundary validates clock and 1 MiB anchor/request/message limits before
native calls. Separate arrays ensure disjoint borrowed input storage. A 2 MiB
output bounds parsing; callback capacity/query lengths are checked before copies.
The callback copies only proof queries and never receives the signed message.
Transport exceptions propagate unchanged. Native errors retain their typed code,
including persistence -7 and busy -8, and no failed result is returned. The new
capability also checks interface, local-estimate scope, tagged status and the
exact message byte digest. Native output is not put in the account balance cache.

All callback/context/buffer state is call-local. `withExtendedLifetime` keeps the
unretained context valid until the synchronous native call ends. No new cache,
queue, thread, timer or production file is introduced. The transport owns timeout
and cancellation; a future async payment coordinator must call this off the main
thread and bound concurrency. Device RSS/concurrency is not inferred from fixed
logical byte limits or simulator tests.

The real-framework tests use bounded public VM16 chain material with its recorded
clock and public fixture signer. They explicitly check original enrollment,
local signed-message hash, no message in transport queries, complete configuration
receive cap, committed checkpoint, transport errors, stale proof and lost state.
The fixture provenance records source revision and file hashes; its node capture
was f2d, while the executing proof library uses the new pin. This is not fresh-chain
acceptance, phone custody, broadcast or physical-device evidence.

The relevant three test suites contain seven tests. All three Apple slices are
built through root Make before tests. The previous read bridge/session suites run
with the new pin. A compiled Swift control removes the empty-message preflight;
the specific test must reject the resulting native error type, then restoration
reruns all seven. Raw results and source/artifact identities live in the companion
mobile memo index. The control is not a production fault hook.

The entire native dependency is an unmerged Draft candidate. Its local scoped
reviews/tests do not replace relevant hosted CI, final third-party review or
mobile release gates. Still required: a proof/checkpoint-bound fee model, explicit
user confirmation, durable outbox/custody integration, deployment/broadcast,
authenticated receipt reconciliation, backup/recovery and physical-device tests.
No simulation result releases an outbox slot or promises an on-chain fee ceiling.
