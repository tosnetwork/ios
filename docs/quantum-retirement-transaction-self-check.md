# R03-B retirement transaction checkpoint

This is an implementation checkpoint, **not yet compiled or tested**. The A
checkpoint and its verification remain separate. B still needs actual core FI
runs/controls, App completion/history wiring, current App compilation and device/
chain acceptance. C random-pending corruption repair and unknown retry are not
included, and the published Send gate remains closed.

The store now uses its original mutex/flock for canonical and retirement work.
Ordinary APIs block on global random pending files, pending retirement records,
a descriptor/stage/workspace or unresolved diagnostic. The dedicated opaque
source can read the original complete snapshot when canonical is absent; both
expiry and receipt readers revalidate this source rather than treating pending()
returning nil as availability to sign.

A root descriptor retains exact same-FD canonical file hash, snapshot file hash,
a stable semantic authorization fingerprint and the decision digest. Snapshot
publication copies the validated raw canonical bytes without Entry/identity BOC
reserialization. The bounded sequence is descriptor/staging material durability,
full workspace entry+decision, durable release_pending local summary, locked fresh
capability/operation recheck, exact canonical unlink+directory sync, durable
release_completed, then workspace-only cleanup. Entry/decision/descriptor and
parent directories are resynced on resume before publication/deletion. A visible
completed rename is resynced before deleting the only snapshot. Root descriptor
removal is last, after workspace rmdir+parent sync.

Limits: one workspace plus one staging directory; complete entry <=2MiB;
workspace materials <=2MiB+2*64KiB+16KiB; 64 local records <=64KiB each and <=4MiB
total. Only durable completed unreferenced records are eligible for bounded
reclamation. Local JSON records/target locators are never reconstructed into
private receipt/expiry capabilities and never authorize canonical deletion.

Known-stage partial snapshot reconstruction requires a strict same-operation
descriptor, intact matching canonical, no decision/ambiguous temporary, no public
record for that operation, no global pending, private owner/mode/noFollow/link
checks and a newly fresh expiry capability. Partial size/hash diagnostics are
retained in the completed local summary. Missing/conflicting canonical, ambiguous
decision or random corrupt pending is held, not guessed away or silently deleted.

The new tests are written but **unrun** at this checkpoint:

- Enumerate reachable publication/unlink/sync/cleanup FI points, reopen the store,
  and require blocking plus fresh-snapshot resume or strictly completed-only
  cleanup. No signer/broadcaster or automatic next operation may run.
- Completed rename/history-dirsync failure must retain snapshot when re-sync fails.
- Existing full entry/decision must be resynced after restart before pending
  publication or canonical deletion, including decision-write/sync interruption.
- Canonical-missing recovery must use exact raw snapshot and new native proof;
  damaged proof must not be replaced by a local summary/status flag.
- Sample freshness again immediately before unlink; old operation cannot delete
  a later slot.
- Partial-stage fresh/same-current-operation controls, decision ambiguity and
  global random-pending blocking, with partial byte/hash preservation.
- Symlink, hardlink and nonprivate directory refusal without canonical mutation
  or chmod of an existing rejected directory. UID/nlink checks are explicit;
  isolated foreign-owner runtime evidence is not claimed yet.
- Bounded 64-record reclamation, exclusion of active/pending/retiring references,
  and no permanent 64-operation ceiling.

These use the existing captured public native proofs with their recorded clock;
future actual runs must retain exact source hashes, commands, failures, designated
counterfactual controls and restored regressions. They are not yet results, real
power-loss evidence, hardware Data Protection evidence or a completed R03 claim.

## Review repair in progress

Review confirmed a P2 in the first checkpoint: readdir EOF and errno failure were
not distinguished, so a partial listing could omit a pending file. The repair
clears errno immediately before each actual readdir and rejects nil+nonzero errno
without returning partial names. Its specified FI returns nil/EIO after at least
one real name, exercises that production error branch, and asserts original
canonical/pending bytes and zero signer calls. The test is written but unrun; it
is injected syscall-error evidence, not a physical disk failure claim. Coverage additions are now written, still uncompiled/unrun:

- Signed and UNKNOWN payment entries retain exact original signature/request/BOC
  across canonical-unlink interruption and public Coordinator inspect -> review ->
  complete. Different operation IDs and a stale review against a new slot refuse.
- Public local SENT/mismatch record formats are covered only as untrusted data;
  these tests deliberately cannot construct a private receipt or authorize unlink.
- A separate opt-in live test obtains actual native receipts for a normal public
  fixture payment and a deliberately unaffordable/skipped output, waits for true
  proven shard expiry, then calls public review -> complete. It uses public fixture
  custody, not App custody. It has not run and is not receipt-branch evidence yet.

The original signing-only matrix was never full B acceptance. Actual receipt
branches and App end/history/lifecycle behavior remain acceptance gaps until run.


## App wiring checkpoint (source only)

The Saved payment page now uses retirement inspection before ordinary pending
reads, so a missing canonical with a full retirement snapshot remains recoverable
and blocked. It displays the strict original deadline independently of the fee
quote, offers explicit fresh verification and optional explicitly unverified
expiry review, then a separate confirmation to finish. A completed local record
clears old input and requires Start another payment. Reload/relaunch with no
pending but completed local history returns to this ended screen; local history
only gates UI and cannot release a slot. UNKNOWN retry stays disabled.

An opt-in continuation of the existing protected-App candidate test is written
for pre-deadline refusal, fresh expiry/end confirmation, ended-page relaunch and
history, followed by an explicitly entered second payment with a new passcode
confirmation, new operation/BOC and sender receipt. It has not run. A designated core test now stops at completedWorkspaceDirectorySync, cancels the
public complete Task, then releases the transaction. It expects cancellation only
after durable completion, restarts inspection/history, and refuses the old review
against a new signed slot with exact-byte preservation. This test is also unrun.
The UI reload gate, this core cancellation control and actual device execution
are separate evidence; ordinary relaunch does not alone prove the narrow window. The
committed production Send gate is unchanged and closed.


## First exact run and fixture repair pending validation

The exact 3e3c03e source first compiled and ran 63 selected methods: 60 passed,
2 failed, 1 physical-device Data Protection skip. Five assertion failures belong
to those two methods, not five failed tests. New B fault-matrix, signed/UNKNOWN,
public Coordinator, readdir EIO and durable-completion cancellation methods
passed. Actual receipt live tests and App/device B flow were not selected/run.
Raw logs/xcresult summary are indexed in validation's
`ios-r03-b-first-1793221994326654000/first-result.json`.

Both failing old tests chmod the root to 0500; the new strict 0700 enumeration
check now refuses before creating a pending file, and also refuses ordinary
pending reads. Production checks/error preservation stay unchanged. The first
fixture now checks both refusals, restores its original mode, and verifies the
signed canonical bytes and phase. The cancellation fixture preserves its original
ACL/mode, prepends only current-uid ADD_FILE denial, and requires actual kernel
O_CREAT|O_EXCL EACCES while mode remains 0700 and existing lock/list/read work.
Only then does it cancel/resume the broadcast and require real Foundation write
failure (Cocoa 513), restore ACL/mode and check the retained submitting BOC.

This test-only repair is uncompiled/unrun. SDK declarations alone do not establish
Simulator ACL support. Unsupported ACL installation or a non-EACCES probe is a
real failure to report; it is not skipped, mocked, or converted into a product
permission change. Controls and final restored regression have not yet run.


The ACL fixture explicitly imports `Darwin.membership` for the SDK's explicit
membership module and its `mbr_uid_to_uuid` declaration. No ACL logic or product
source changed in this import repair. The test file SHA-256 is
`8864060866818ce0efdeca7b44a7b48ca6882604cfde0c1ef4c79455b4277a1f`. This repair remains uncompiled/unrun pending review and the next
exclusive iOS build lease.


The exact 5e0764e ACL attempt failed at compilation in the two `acl_free` calls:
the imported ACL type is an OpaquePointer and the C API takes void*. No tests ran
and no runtime ACL support was established. Both cleanup arguments now use an
explicit `UnsafeMutableRawPointer` bridge, without changing ACL logic or product
source. Current test SHA-256: `f610a23c0ae26cb82efd5da05dd65b4d690f037b8341087ea4bf57d17607130b`. This bridge repair is uncompiled/unrun.
The original first ACL build log remains in
`ios-r03-b-acl-first-1793228344827035000/first-result.json`.
