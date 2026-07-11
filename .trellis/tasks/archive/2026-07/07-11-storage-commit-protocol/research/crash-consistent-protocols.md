# Crash-Consistent SQLite + Managed-File Protocols

## Decision Summary

Use a **hybrid of immutable/versioned managed payloads, an explicit SQLite mutation journal/outbox, and payload compare-and-swap**.

- A published managed payload is immutable and has a unique relative name. A mutation never overwrites the file currently referenced by a row.
- SQLite remains the authority for the current item state. A small `storage_mutations` table records only unfinished ownership transitions and post-commit cleanup/ingest acknowledgement.
- External insertion/replacement writes and validates a new file before the row transaction. The row mutation and the journal transition to `committed` happen in the same `BEGIN IMMEDIATE` transaction.
- The old managed file and durable ingest source remain recoverable until the committed journal entry is drained.
- Search/cache updates and UI events are derived only from a typed `committed` result; `notFound` and `conflict` are distinct non-success results.
- Startup drains the bounded journal before monitoring starts. A conservative mark-and-sweep remains a low-frequency safety net, not the primary commit protocol.

This is more work than the current schema-free orphan scan, but it is the smallest option here that covers **insert, replace, delete, durable-spool acknowledgement, cancellation, and post-commit cleanup with one explicit recovery model**. Content-addressed storage is a plausible future evolution, not a prerequisite. Moving all large payloads into SQLite would simplify atomicity but is a high-cost reversal of Scopy's current storage/performance design.

## Scope And Durability Vocabulary

“Atomic” and “durable” are different properties:

| Level | Failure boundary | Required outcome |
| --- | --- | --- |
| D0: operation failure/cancellation | Swift error, task cancellation, disk-full/permission error while the app remains alive | No success result; old row/payload or durable ingest source remains usable; retry is idempotent |
| D1: application-process crash | abort, `SIGKILL`, crash, machine remains running | On reopen, every mutation converges to old or new committed state; no row points to a partial/missing payload |
| D2: OS crash/restart | kernel panic or forced restart while storage remains powered | Same convergence, provided file and directory sync ordering plus SQLite durable commit are enabled |
| D3: sudden power loss/device cache loss | storage controller may reorder or retain writes | Requires the strongest macOS `F_FULLFSYNC`/SQLite full-sync policy and hardware cooperation; it is expensive and must not be claimed from `rename` or Foundation `.atomic` alone |

The task acceptance requires D0 and D1. The implementation should be structured to support D2. D3 must be an explicit, measured policy decision rather than an accidental claim.

SQLite documents that WAL + `synchronous=NORMAL` remains consistent and survives application crashes, but a recently committed transaction can roll back after an OS crash or power loss. WAL + `synchronous=FULL` adds a WAL sync on each commit and is the SQLite durability boundary for that stronger failure class ([SQLite `PRAGMA synchronous`](https://sqlite.org/pragma.html#pragma_synchronous), [WAL performance/durability](https://sqlite.org/wal.html#performance_considerations)). Scopy currently opens WAL with `synchronous=NORMAL` (`Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:78-99`), so the present configuration can support D1 but must not be described as D2/D3 durable.

POSIX requires `rename` to be atomic as a directory operation, meaning observers do not see a half-renamed destination. It does **not** by itself make the new directory entry durable after a crash. POSIX guidance explicitly describes the sequence “sync temporary file, rename, then sync the affected directory”; two directory syncs may be needed when a rename changes directories ([POSIX `rename`](https://pubs.opengroup.org/onlinepubs/9799919799/functions/rename.html), [POSIX directory-operation durability rationale](https://pubs.opengroup.org/onlinepubs/9799919799/xrat/V4_xbd_chap01.html)).

On macOS, `fsync` flushes host buffers but Apple warns that a drive may still reorder or buffer data; `F_FULLFSYNC` asks the drive to flush its cache and may be much slower ([Apple `fsync(2)`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html), [Apple `fcntl(2)` / `F_FULLFSYNC`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fcntl.2.html)). SQLite exposes the same stronger macOS behavior through `PRAGMA fullfsync`, but its own atomic-commit documentation warns that it is profoundly slow and affects unrelated I/O ([SQLite fullfsync discussion](https://sqlite.org/atomiccommit.html#_things_that_can_go_wrong)). Therefore:

- use file `fsync` + directory sync and benchmark WAL `synchronous=FULL` for a D2 release profile;
- do not enable `F_FULLFSYNC`/`PRAGMA fullfsync=ON` by default without a separate latency/throughput study;
- if the project stays on WAL `NORMAL`, retain the durable ingest/old payload until recovery can prove the transaction and explicitly scope the guarantee to D1.

## Current Scopy Evidence

The current worktree is authoritative and is already ahead of part of the July 10 audit:

1. **External image optimization no longer overwrites its live managed file in place.** It publishes a staged image to a new UUID path, then runs a repository CAS; the old path is left for orphan cleanup (`Scopy/Services/StorageService.swift:597-648`). This is a valuable foundation and should be generalized, not replaced.
2. **The publication is atomic in visibility but not durable in ordering.** `replaceFileAtomically` calls `Darwin.rename`, while `writeAtomically` writes `path.tmp`, removes an existing destination, and moves the temporary file; neither path syncs file contents or the parent directory (`Scopy/Services/StorageService.swift:1709-1743`). Removing the destination before moving also creates a visibility gap for replacement paths. Apple Foundation's `.atomic` option only promises auxiliary-file replacement; its documentation does not promise stable-media durability ([Apple `NSData.WritingOptions.atomic`](https://developer.apple.com/documentation/foundation/nsdata/writingoptions)).
3. **The large-ingest source can be destroyed before SQLite owns it.** For `>=100 KiB` file payloads, `upsertItemWithOutcome` calls `moveOrCopyFile` before `insertItem`; both the normal move and copy fallback remove the spool source before the database commit (`Scopy/Services/StorageService.swift:381-500`, `:1745-1763`; threshold at `Scopy/Infrastructure/Configuration/ScopyThresholds.swift:7-20`). If insertion fails or the process dies, the envelope can remain while its payload is gone.
4. **The purported durable spool is in a discardable location.** The default is `~/Library/Caches/Scopy/ingest` (`Scopy/Services/ClipboardMonitor.swift:262-289`). Apple defines `Caches` as regenerable/discardable and says apps must not rely on cache files existing; app-managed user data belongs in Application Support ([Apple macOS Library directory guidance](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/MacOSXDirectories/MacOSXDirectories.html), [Apple app-specific file guidance](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/AccessingFilesandDirectories/AccessingFilesandDirectories.html)). A replay source cannot be called durable while it lives only in `Caches`.
5. **Envelope acknowledgement is after the normal store call, but is not idempotent across the commit/ack crash window.** The monitor writes payload then envelope and replays envelopes on startup (`Scopy/Services/ClipboardMonitor.swift:944-1009`); the service commits and publishes, then acknowledges (`Scopy/Application/ClipboardService.swift:2053-2098`). A crash after DB commit but before acknowledgement replays the envelope. Current content-hash dedup turns that replay into another usage increment rather than recognizing the same ingest operation.
6. **CAS conflates two different failures.** `compareAndSwapItemPayload` returns `nil` when the row is absent or when its payload snapshot conflicts (`Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:248-300`). The transaction correctly uses `BEGIN IMMEDIATE`, but callers cannot make typed recovery/publication decisions from the result.
7. **Delete is DB-first and safe from deleting a live row on DB failure, but cleanup is not journaled.** Single and batch deletes commit the row removal before unlinking files (`Scopy/Services/StorageService.swift:875-930`, `:1457-1478`). A crash after DB commit leaks a file until a later full orphan scan.
8. **Orphan cleanup is carefully race-hardened inside one process, but remains scan-derived recovery.** It unions in-process protected filenames, aborts on generation changes, reserves paths, checks DB ownership twice, and separately ages hidden optimization stages for 24 hours (`Scopy/Services/StorageService.swift:1267-1402`, `:1593-1657`). These in-memory protections disappear at process death, and they do not coordinate a second process.
9. **Search/UI publication is already moving in the right direction.** The ingest path awaits storage success before synchronizing authoritative search state and emitting events (`Scopy/Application/ClipboardService.swift:2073-2095`); authoritative publication re-reads the current row and repairs/invalidates derived search state (`:1817-1921`). The storage result needs to become typed so this invariant is structural rather than caller convention.

## Required Invariants

The selected design must make these statements true at every return and restart boundary:

1. A DB row may reference only a complete, validated inline payload or a complete, validated managed file.
2. Once published, a managed payload is immutable. Replacement creates a new path.
3. Before a row commits to a new managed file, at least one replayable source exists: the old referenced file, the durable ingest payload, or both.
4. The old file/durable source is not removed until the DB commit that supersedes it is confirmed and recoverable.
5. An operation has a stable idempotency key. Ingest uses the envelope UUID; user transforms use a generated operation UUID plus expected payload revision.
6. `committed`, `notFound`, and `conflict` are distinct repository outcomes. Only `committed` may update derived search state or publish a success event.
7. Cleanup acts only on validated managed relative names and rechecks DB/journal ownership immediately before unlink.
8. Cancellation is honored before commit. Once commit succeeds, cancellation cannot turn a committed mutation into an apparent rollback; post-commit recovery work remains scheduled/durable.
9. Recovery work is bounded by the number of unfinished operations. Full mark-and-sweep is only a safety audit and has an age fence.
10. Unknown/corrupt journal rows fail closed: log/quarantine them, but never delete an arbitrary path.

## Protocol Alternatives

### Option A — Schema-Free Immutable Files + Row CAS + Mark-And-Sweep

Sequence:

1. Keep old/spool source.
2. Write a unique hidden stage in the destination directory.
3. Validate hash and size; sync the stage.
4. Rename to a unique final managed name; sync the directory.
5. CAS/insert the SQLite row.
6. After commit, delete the old file/ack the envelope best-effort.
7. On startup, remove stale stages and files not reachable from DB rows.

Strengths:

- Lowest code/schema/rollback cost.
- One DB transaction per item and no steady-state journal rows.
- Very close to the current optimized-image path.
- Safe for replacement if old/source retention and sync ordering are correct.

Weaknesses:

- Recovery requires an `O(number of managed files + rows)` scan and an age rule.
- A scanner cannot distinguish “abandoned” from “published but not yet referenced by another process” without a process lock or prepared-ref set.
- Delete retry and spool acknowledgement are not explicit; repeated failure can leak until the next full scan.
- The commit/ack window still needs an ingest receipt to avoid replay inflating usage.
- It covers a single writer/process reasonably well, but it is not a complete cross-layer protocol by itself.

Verdict: viable smallest D1 fix, but too implicit for the task's full insertion/replacement/delete/spool acceptance.

### Option B — SQLite Mutation Journal/Outbox + Immutable Files + CAS (Recommended)

Add an internal, additive table (illustrative fields):

```sql
CREATE TABLE storage_mutations (
    operation_id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    state TEXT NOT NULL,
    item_id TEXT,
    expected_payload_revision INTEGER,
    old_ref TEXT,
    new_ref TEXT,
    stage_name TEXT,
    ingest_envelope_id TEXT,
    content_hash TEXT,
    size_bytes INTEGER,
    created_at REAL NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    last_error_code TEXT
);
CREATE INDEX storage_mutations_state_created
    ON storage_mutations(state, created_at);
```

Store controlled relative names/IDs, not arbitrary absolute user paths or clipboard content. An internal `payload_revision` column is also worth adding to `clipboard_items` so the CAS predicate is one explicit monotonic value rather than a large equality bundle. Pin/note/usage updates do not advance it; payload identity/hash/size/ref/raw-data transitions do.

State model:

```text
source retained
     |
     v
PREPARED intent committed in SQLite
     |
     v
stage written -> validated -> synced -> renamed -> directory synced
     |
     v
BEGIN IMMEDIATE
  conditional row insert/CAS/delete
  PREPARED -> COMMITTED (or record cleanup action)
COMMIT
     |
     v
authoritative search/UI publication
     |
     v
idempotent outbox drain: old-file unlink / envelope ack
     |
     v
operation row removed (or short-lived receipt tombstone retained)
```

Deletion does not need a prepare transaction: capture the current `storage_ref`, delete the row, and insert a committed `delete_file` outbox action in the same DB transaction. SQLite `RETURNING` can return rows actually modified, and `sqlite3_changes64` can verify affected-row count, but the existing select/update transaction can also produce a typed result without adding API assumptions ([SQLite `RETURNING`](https://sqlite.org/lang_returning.html), [`sqlite3_changes64`](https://sqlite.org/c3ref/changes.html)).

Strengths:

- One explicit state machine covers insert, replace, delete, ingest acknowledgement, and retry.
- Startup recovery is `O(pending operations)`; ordinary startup need not scan every file.
- Prepared `new_ref` values can be included in orphan ownership, making cleanup safe across service instances/processes.
- DB row mutation and cleanup intent are atomic because they share one SQLite transaction.
- Ingest UUID receipt makes replay idempotent without altering user-visible DTOs.
- Additive schema can remain backward-readable once the journal is drained.

Weaknesses:

- External insert/replace normally adds a small prepare transaction before the final row transaction.
- Requires migration, recovery code, bounded retry/backoff, and more fault-injection tests.
- A journal does not replace file sync ordering; it makes an ambiguous partial state recoverable.
- Rolling back to an older binary is safe only after draining the journal, because the old orphan scanner does not know prepared refs.

Verdict: best fit for the stated reliability and architecture goal.

### Option C — Content-Addressed Immutable Object Store

Store payloads under a cryptographic digest (for example, `objects/ab/<sha256>`) and let DB rows reference the object key. Inserts/replacements become “ensure object exists, then CAS row”; deletion decrements a transactional reference count or relies on mark-and-sweep.

Strengths:

- Immutability and deduplication are structural.
- Retry of the same bytes is naturally idempotent.
- Multiple rows can safely share one object.
- Later encryption/compaction can be layered behind an object-store interface.

Weaknesses:

- Reference counting, hash collision defense, object verification, and GC are more complex than UUID versions.
- Scopy currently tolerates external managed files changing out of band and has reconciliation logic; a content-addressed object must never change, so an out-of-band edit becomes a new imported object.
- Hash names reveal equality of payloads within the local store unless names are keyed/encrypted.
- Migration and rollback are much larger, and the current task does not need global deduplication.
- It still needs a journal/receipt for spool acknowledgement and post-commit deletion if strong recovery is required.

Verdict: good future `ManagedObjectStore` backend after the mutation protocol exists; not the first implementation.

### Option D — Put Every Payload In SQLite BLOB Storage

One SQLite transaction can own payload bytes, metadata, FTS triggers, and ingest receipt, eliminating the cross-resource commit problem. SQLite has published favorable results for many small BLOBs, but those measurements are workload-specific ([SQLite “35% Faster Than The Filesystem”](https://sqlite.org/fasterthanfs.html)).

Strengths:

- Simplest atomicity and backup model.
- No file orphan/replacement race.
- One transaction and one recovery engine.

Weaknesses:

- Reverses Scopy's explicit `>=100 KiB` external-storage design.
- Large images/files amplify WAL, checkpoint, backup, vacuum, mmap, and read-memory costs.
- Migrating existing payloads is expensive and rollback requires extracting them again.
- A single large SQLite file increases blast radius and makes Finder/AirDrop materialization unavoidable.

Verdict: reject for this task. It optimizes for implementation simplicity at a high product/performance/migration cost.

## Comparison Matrix

| Criterion | A: UUID + CAS + sweep | B: journal + UUID + CAS | C: CAS objects | D: all SQLite BLOB |
| --- | ---: | ---: | ---: | ---: |
| D1 crash convergence | Good if source retained | Excellent/explicit | Good with journal | Excellent |
| Insert + replace + delete + spool under one model | Partial | Excellent | Partial without journal | Excellent |
| Normal recovery cost | Full scan | Pending-row scan | Refcount or full scan | SQLite open/recovery |
| DB commits per external mutation | 1 | Usually 2 | 1-2 | 1 |
| Extra file I/O | One new file | One new file | Ensure/hash object | WAL + DB page writes |
| Current-code fit | High | High | Medium | Low |
| Migration cost | None | Additive/medium | High | Very high |
| Rollback locality | Excellent | Good after drain | Poor | Poor |
| Future encryption/compaction seam | Medium | High | High | Medium |
| Operational diagnosability | Low-medium | High | Medium | High |

## Recommended Commit Protocol

### 1. File Publication Boundary

For a new managed payload:

1. Allocate `operation_id` and controlled relative names under one managed root:
   - stage: `content/objects/.<operation_id>.stage`
   - final: `content/objects/<operation_id>.<validated-extension>`
2. Open the stage with exclusive creation; never reuse `path + ".tmp"`.
3. Stream/copy bytes while retaining the durable source. Do not move the source.
4. Validate exact byte count and content hash against the mutation request.
5. Call `fsync` on the stage for D2; for a separately approved D3 policy, use `F_FULLFSYNC` and measure it.
6. Close the file, then same-directory `rename` stage -> final. This avoids `EXDEV` and reduces directory-sync scope.
7. Sync that directory. If directory sync is unsupported on the active filesystem, surface the weaker durability tier and keep the source/outbox; do not silently report D2/D3.
8. Only then begin the row transaction.

The final name is unique, so publication never needs “remove existing destination, then move”. If the final already exists for the same operation ID, verify hash/size and treat it as an idempotent retry; otherwise fail closed.

### 2. SQLite Boundary

Use `BEGIN IMMEDIATE`, which obtains the write transaction before validation/mutation and is already the repository convention ([SQLite transaction semantics](https://sqlite.org/lang_transaction.html)). Inside one transaction:

- **insert:** reject an existing operation receipt; insert the item and transition its prepared mutation to committed;
- **replace:** fetch row by ID, distinguish absent from revision mismatch, update only when `payload_revision == expected`, increment revision, and transition the mutation to committed;
- **delete:** capture the exact current ref, delete the row, and insert a committed delete-file outbox action;
- **inline/external transition:** store enough non-content metadata to restore the old authoritative state; when inline -> external rollback needs the old bytes, retain a controlled managed recovery copy referenced by the journal instead of placing clipboard content in the journal row.

Return one of:

```swift
enum StorageMutationOutcome: Sendable {
    case committed(ClipboardStoredItem, operationID: UUID?)
    case notFound
    case conflict(currentRevision: Int64)
}
```

Do not return `nil` for both absent and conflicting state. Do not emit success before `COMMIT` returns. If commit outcome is uncertain after an I/O error, reopen and resolve by `operation_id` rather than guessing.

### 3. Post-Commit Boundary

After a typed committed result:

1. Re-read/synchronize the authoritative row into search/cache state.
2. Publish the existing user-facing event shape.
3. Drain the mutation idempotently:
   - verify the new row/ref/file/hash/size;
   - delete `old_ref` only if no DB row or prepared/committed mutation references it;
   - acknowledge the ingest envelope only after the row/new file is verified;
   - sync the ingest directory if D2 is claimed;
   - remove the mutation row, or retain a bounded receipt tombstone long enough to reject a reappearing envelope.

Post-commit cleanup failure is not mutation failure. Persist retry count/error class, apply backoff, and avoid a hot loop. Logs contain operation IDs/counts, never clipboard data or arbitrary source paths.

### 4. Durable Ingest Ownership

- Move the replay source from `Library/Caches` to an Application Support subdirectory before calling it durable.
- Persist payload first, then envelope; use unique names and the same file-sync/rename/directory-sync sequence appropriate to the selected durability tier.
- The envelope UUID is the idempotency key. A replay first checks the receipt/mutation table:
  - committed receipt + matching item: acknowledge without incrementing usage;
  - prepared operation: resume/recover it;
  - no operation: begin a new prepared transition;
  - conflicting/corrupt receipt: quarantine and log, never discard the only payload silently.
- Never mutate the spool payload in place during pngquant preparation. Transform into a separate stage so the original envelope remains replayable.

### 5. Recovery And Cleanup Boundary

Run recovery after repository open/migration and before monitor/search publication starts:

1. Read pending mutations ordered by creation time, with a bounded batch size.
2. Validate every relative name against the managed root and allowed namespace.
3. For `prepared` publish operations:
   - if the DB row does not reference `new_ref`, remove stage/final only when unreferenced, keep source/envelope, and retry or clear the intent;
   - if the row already references a valid `new_ref`, promote to committed (defensive resolution of an uncertain commit).
4. For `committed` publish operations:
   - valid row + new file: drain old-file cleanup and envelope acknowledgement;
   - missing/corrupt new file: for insert, replay from retained envelope; for replacement, CAS back to the retained old payload snapshot if the row still owns the failed new revision; otherwise leave the independently superseded row untouched.
5. For committed delete actions, unlink only if the ref is still unreferenced, then complete the action.
6. Reclaim stale controlled `.<operation_id>.stage` entries with an age fence.
7. Keep periodic full mark-and-sweep as a leak detector/safety net. It must union refs from both `clipboard_items` and unfinished journal entries and must never delete an unknown namespace.

Recovery is idempotent: crashing during recovery leaves the same row actionable on the next launch.

## Fault Matrix For The Recommended Protocol

| Crash/failure point | Durable evidence after restart | Required recovery/result |
| --- | --- | --- |
| Before prepared intent commit | Old file or ingest envelope/source | No mutation; retry normally |
| After prepared intent, before stage write | `prepared` row + source | Remove empty/absent stage, retain source, retry/clear intent |
| During stage write | `prepared` + source + partial hidden stage | Never publish partial bytes; remove stage and retry |
| After stage sync, before rename | `prepared` + durable stage + source | Verify and resume rename, or delete/retry |
| After rename, before directory sync | `prepared`; final may exist or disappear after D2/D3 crash | Check final; source/old remains authoritative; retry safely |
| After durable final publication, before row transaction | `prepared` + unreferenced final + source/old | Remove/reuse final by operation ID; DB remains old/absent |
| During `BEGIN IMMEDIATE` transaction | SQLite rolls back; prepared intent remains | Same as pre-transaction state |
| CAS row missing | `prepared`, old row absent | Typed `notFound`; clean new file; no search/UI success |
| CAS revision mismatch | `prepared`, different current row | Typed `conflict`; clean new file; publish only authoritative current state if needed |
| Commit succeeds, process dies before return | committed row + committed journal | Resolve by operation ID; treat as committed, then drain |
| Commit succeeds, before old-file unlink | row -> new; old retained; committed journal | New state wins; retry unlink only after ref check |
| Old file unlinked, before journal completion | row -> new; old absent; journal remains | Missing old file is idempotent success; complete action |
| Insert commits, before envelope ack | row/new valid + ingest receipt + envelope | Replay recognizes same operation; no duplicate usage increment; ack |
| Envelope unlinked, before receipt completion | row/new valid + receipt; envelope may be absent | Missing envelope is idempotent; retain tombstone until durability boundary |
| Delete row/outbox transaction commits, before unlink | row absent + delete action + file | Retry validated unlink; no resurrection |
| Disk full/permission denial before commit | prepared/source/old retained | Return failure, no event; cleanup/retry bounded |
| Cancellation before commit | prepared/source/old retained | Abort/cleanup; no success |
| Cancellation after commit | committed row/journal | Finish/schedule drain; return committed semantics, not rollback fiction |
| Crash after search update, before UI event | DB row authoritative | Startup hydration converges; no persistent ghost state |
| Corrupt/invalid journal path | journal row only | Quarantine/fail closed; never unlink arbitrary path |

## Performance And Complexity Boundaries

### Expected Cost

- External ingest/optimization already writes a complete new payload, hashes it, and performs a DB write. The recommended protocol adds a small prepared-row transaction, file/directory sync according to durability tier, and a tiny outbox drain.
- The extra prepare commit occurs only for external payloads (`>=100 KiB`), not ordinary inline text.
- Recovery becomes proportional to unfinished mutations rather than every managed file. A periodic mark-and-sweep can remain hourly/full-cleanup work.
- Old/new double storage exists only across the short commit/drain window; this is the necessary rollback reserve.

### Important Performance Decisions

1. Keep all copying, hashing, sync, and cleanup off the main actor. `StorageService` may remain the orchestration boundary, but file operations need a narrow sendable `ManagedFileStore`/executor seam.
2. Do not run `F_FULLFSYNC` blindly. Apple and SQLite both warn about its cost. Measure before selecting D3.
3. Benchmark WAL `synchronous=FULL` against the current `NORMAL` configuration. If FULL meets ingest/search/UI budgets, it is the clean D2 choice. If not, retain sources and batch a durable checkpoint/ack boundary; do not simply claim durability from NORMAL.
4. Batch journal drains and delete actions, but never batch the row mutation outside the user operation's transaction.
5. Keep journal indexes narrow and rows content-free. Prune completed receipt tombstones by age and count.

### Required Measurements

- External insert and replacement at 100 KiB, 1 MiB, 10 MiB, and 100 MiB: p50/p95 wall time, main-actor longest segment, bytes written, and peak temporary disk usage.
- Burst ingest at the existing concurrency limit of 3: throughput, backlog, and DB busy time.
- WAL NORMAL vs FULL; file `fsync`; optional `F_FULLFSYNC` as a separate experiment.
- Recovery with 0/1/100/10,000 pending journal rows and with a realistic managed-file directory.
- Existing `make test-snapshot-perf-release` plus frontend smoke to prove no user-visible interaction regression.

No performance claim is valid until the same workload is measured before and after.

## Rollback Plan

Implement in coherent, reversible slices:

1. Add typed mutation outcome and internal payload revision tests; no behavior switch.
2. Add `ManagedFileStore` with unique staging, validation, sync/rename seams, and fault injection; keep legacy path selectable internally.
3. Add additive journal migration and recovery reader; old item schema/DTO remains readable.
4. Route external replacement, then external insert/spool, then delete cleanup through the journal.
5. Move durable spool to Application Support with one-time discovery/migration from the legacy Caches path.
6. Enable the new path only after restart/fault/performance gates pass; remove the legacy path in a later commit.

Reverting code remains possible because `storage_ref` continues to point at ordinary managed files and the schema additions are ignorable by the old explicit-column queries. Before rollback:

- stop new mutations;
- run recovery/drain until `storage_mutations` is empty;
- verify DB refs and managed files;
- only then run an older binary, whose orphan scanner does not know journal-owned prepared refs.

Do not combine a durability-policy change (`NORMAL` -> `FULL` or `fullfsync`) with the state-machine code in one rollback unit.

## Verification Strategy

Thrown-error tests are insufficient because Swift `defer` cleanup runs on ordinary errors/cancellation but not on process death. Use both in-process interlocks and a crash-worker process:

1. Launch a small test helper against an isolated temp root/database.
2. At each named fault point, flush a “reached” sentinel and terminate with `_exit`/`SIGKILL` so no cleanup executes.
3. Reopen a fresh `StorageService`, run recovery, and assert:
   - DB row existence/revision/ref/hash/size;
   - managed file existence and exact hash/size;
   - old file/source/envelope ownership;
   - pending journal count/state;
   - replay idempotency/use count;
   - search hydration and emitted event semantics.
4. Add deterministic in-process races for delete vs optimize, duplicate envelope replay, metadata-only update vs payload CAS, and orphan cleanup vs prepared/committed refs.
5. Inject disk-full, permission, rename, sync, SQLite begin/step/commit, and unlink failures through narrow file/repository seams.
6. Run full `make build`, `make test-unit`, `make test-strict`, `make test-tsan`, `make test-snapshot-perf-release`, frontend smoke, docs, and release validation.

Acceptance should include a machine-readable matrix mapping every fault point above to the expected old/new committed state. “No crash” is not proof of recovery correctness.

## Final Recommendation

Adopt **Option B** in stages: generalize the already-present immutable optimized-image publication into one managed-file commit primitive; add an additive SQLite mutation journal/outbox and internal payload revision; keep spool/old files until committed recovery completes; and make search/UI publication consume only a typed committed result. Preserve a conservative mark-and-sweep as a safety audit. Treat WAL/file sync policy as a separately benchmarked durability tier, with no D2/D3 claim while Scopy remains on WAL `synchronous=NORMAL` and unsynced file renames.
