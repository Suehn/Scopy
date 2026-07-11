# Crash-Consistent Storage Commit Protocol

## Goal

Eliminate the two confirmed P0 storage-consistency failures without replacing Scopy's working storage architecture:

1. A durable ingest payload must never be lost between filesystem publication and the SQLite commit, and replay of the same envelope must be exactly-once.
2. Cleanup must never delete an item from a stale plan after the item was pinned or its payload changed, and the visible history must converge to the committed deletion set.

The change must preserve current clipboard/history behavior, IDs, search ranking, event meaning, storage thresholds, and Settings semantics. It targets process-crash/restart consistency (D1). It must not claim power-loss durability (D2/D3) while SQLite remains WAL `synchronous=NORMAL` and file publication is not explicitly synced.

## Evidence And Priority

The audit in `research/current-storage-failure-map.md` shows:

- **P0 data loss:** the normal external `.file` ingest moves the only spool payload before `insertItem` commits. Insert failure or process termination can leave an envelope whose payload is gone, after which restart discards the envelope.
- **P0 incorrect deletion:** cleanup selects unpinned IDs in one transaction and later deletes those IDs unconditionally. A pin or payload replacement between plan and apply can be lost.
- **P1 projection drift:** scheduled cleanup invalidates search but emits no deletion/reload event, so visible history can retain ghost rows.
- Explicit external-image optimization already stages an immutable unique file, uses payload CAS, and retains the old file. Rebuilding that path behind a general journal is not justified by current evidence.

These issues outrank smaller API cleanups, broad refactors, and speculative storage redesigns because they can destroy user data or violate an explicit pin.

## Accepted Architecture Decision

Use a narrow hybrid of immutable file ownership, an atomic SQLite ingest receipt, and transactionally revalidated cleanup.

### Selected: retained source + ingest receipt + atomic cleanup result

- Keep the durable spool source until SQLite has committed the item/dedup result and acknowledgement has reached a terminal non-replay state.
- Carry the envelope UUID as the ingest idempotency key into storage.
- Add an additive receipt table. Receipt creation and item insert/dedup increment occur in the same `BEGIN IMMEDIATE` transaction.
- Publish search/UI changes only for a newly committed insert/update. Replaying an existing receipt is an internal `alreadyApplied` result and must not increment usage or republish success.
- Apply cleanup eligibility and deletion in one repository transaction and return the exact deleted item IDs/storage refs. Files and UI projections consume only that returned committed set.

### Deferred: general mutation journal/outbox

A generic journal would improve diagnosability and exact retry of every old-file unlink, but it adds a second transaction, recovery state machine, schema/revision model, and rollback constraints to paths that are already safe. It remains a future option if measured orphan-retry failures or ambiguous SQLite commit outcomes justify it.

### Rejected for this task

- Content-addressed global object store: large migration/refcount/GC surface with no need for global deduplication.
- Store all payloads as SQLite BLOBs: reverses the current large-payload design and increases WAL/memory/backup cost.
- Enabling `synchronous=FULL`, `fsync`, or `F_FULLFSYNC`: a separate durability/performance decision requiring dedicated benchmarks.

## Scope

### Slice A — durable, idempotent ingest

1. Move the default replay spool from `Library/Caches/Scopy/ingest` to an Application Support-owned directory. Migrate or drain legacy pending envelopes idempotently; never overwrite a destination or delete the legacy source before the new envelope is replayable.
2. Validate every envelope URL and decoded payload filename against the owned spool root. Reject traversal, symlink escape, and arbitrary acknowledgement URLs without reading or deleting outside the root.
3. Distinguish a durable spool-owned file from a transient derived/working file in the internal content model.
4. Never move, delete, or mutate a durable spool-owned source before commit. Managed publication copies (or uses an equally safe immutable publication primitive) to a unique destination. Automatic pngquant work uses a separate transient copy.
5. Give derived work files a controlled namespace and bounded startup cleanup. Envelope creation failure must clean its unowned payload; corrupt artifacts must fail closed and be quarantined or safely removed only when ownership is proven.
6. Add a schema migration from v7 to v8 with a content-free receipt such as `(ingest_id PRIMARY KEY, item_id, committed_at)`. Do not use a cascading foreign key: deletion of an item must not permit an old envelope to resurrect it.
7. Make repository upsert atomic for an ingest ID:
   - existing receipt -> `alreadyApplied(currentItem?)`, no insert and no usage increment;
   - existing content hash -> increment once and insert receipt in the same transaction;
   - new content -> insert item and receipt in the same transaction.
   A final transaction-time hash recheck is required even if a preflight lookup avoids unnecessary file work.
8. Acknowledge by atomically moving a validated pending envelope to a non-replay terminal marker before best-effort payload/marker cleanup. Remove the receipt only after that terminal transition succeeds. Startup cleanup must finish terminal markers idempotently.
9. Storage/ack failure must retain enough durable evidence for restart replay. A post-commit acknowledgement failure is not a storage rollback.

### Slice B — conditional cleanup and projection convergence

1. Replace select-now/delete-later cleanup plans with a repository operation that re-evaluates all selection predicates and deletes in one `BEGIN IMMEDIATE` transaction, or conditionally deletes exact candidates with equivalent protection.
2. At minimum, a row that became pinned or whose payload identity/storage ownership changed after planning must be skipped.
3. Return the exact committed deletion set: item IDs and validated storage refs captured from those same rows inside the transaction.
4. Delete external files only for that returned set, using existing managed-ref containment and orphan safety.
5. Invalidate/update search from the committed set and send a bounded bulk removal or authoritative reload signal so an open unfiltered history cannot retain deleted rows. Do not enqueue thousands of per-item events into the bounded event queue.
6. Log planned, committed, skipped, and file-cleanup counts without clipboard content or arbitrary paths.

## State Machines

### Durable ingest

```text
payload written -> pending envelope -> work queued
      |                  |                 |
      +------ restart replayable ----------+
                                           v
                         unique managed candidate (source retained)
                                           v
                    BEGIN IMMEDIATE: receipt check + upsert + receipt
                              |                         |
                           rollback                  committed
                              |                         v
                      source remains        search/UI only for new result
                                                        v
                                  pending envelope -> terminal marker
                                                        v
                                  receipt removal + bounded artifact cleanup
```

### Cleanup

```text
policy request -> BEGIN IMMEDIATE: re-evaluate + delete eligible rows
                                   |
                                   v
                         exact deleted IDs + refs
                          /          |          \
                  file cleanup   search sync   bulk UI convergence
```

## Required Outcomes

Internal APIs must distinguish at least:

- newly inserted;
- existing item updated once by deduplication;
- ingest already applied (item may since have been deleted);
- no cleanup rows committed versus exact cleanup rows committed.

Payload replacement `notFound` versus `conflict` remains desirable, but is not allowed to expand this task unless needed by the two selected P0 flows.

## Fault And Race Matrix

| Fault/race | Required result after return/restart |
| --- | --- |
| payload write succeeds, envelope write fails | no unbounded orphan; capture remains retryable |
| process dies after pending envelope | original source replays |
| process dies during derived transform | original source replays; controlled work file is reclaimable |
| managed candidate publication fails | pending envelope/source remain; no row/event |
| SQLite insert/commit fails | pending envelope/source remain; candidate is safely reclaimable |
| commit succeeds before acknowledgement | receipt makes replay a no-op; usage count stays exact |
| terminal envelope rename fails | receipt and pending envelope remain for retry |
| terminal rename succeeds before cleanup | envelope is not replayed; marker/payload cleanup resumes |
| committed item later deleted before old envelope replay | receipt prevents resurrection; replay only finishes acknowledgement |
| malformed payload filename or ack URL | fail closed; no path outside spool is read/deleted |
| cleanup plans an unpinned row, then user pins it | row/file remain; returned deletion set excludes it |
| cleanup plans a row, then payload CAS commits | current row/current payload remain; stale ref is not treated as committed deletion |
| cleanup commits, file unlink fails | row stays deleted; existing orphan reconciliation can retry safely |
| cleanup commits while history is open | visible list reloads/removes the exact committed rows without queue overflow |

## Acceptance Criteria

- [x] Every matrix row has deterministic fault/race coverage or equivalent restart evidence. A real `_exit`/SIGKILL harness is not used because XCTest cannot preserve an in-process seam after terminating its host; deterministic persisted-artifact restart tests cover the same D1 boundaries. See `verification.md`.
- [x] Duplicate replay of one envelope produces one item-side mutation total, including the existing-hash path.
- [x] Insert failure cannot turn a valid envelope into a missing-payload envelope.
- [x] Default pending data resides in Application Support; legacy cache artifacts migrate/drain without loss.
- [x] Spool containment tests cover traversal, foreign envelope URL, symlink escape, and terminal-marker recovery.
- [x] Cleanup race tests prove post-plan pin and payload replacement are preserved.
- [x] Cleanup returns actual deleted IDs/refs and the open history/search projections converge from that result.
- [x] Normal inline text, transient file, explicit optimization, copy/replay, item IDs, and visible product behavior remain unchanged.
- [x] Schema v7 -> v8 migration, reopen, `user_version`, and integrity checks pass on an isolated copy of a real snapshot.
- [x] `make build`, `make test-unit`, `make test-strict`, and `make test-tsan` pass.
- [x] `make test-snapshot-perf-release` and the final full/include-hover frontend profiles pass their execution gates; mixed broad-profile variance is recorded without a causal claim.
- [x] Release/spec documentation and verification evidence agree. Implementation commits and gates completed before the separately authorized release/tag/Homebrew mutation.

## Performance And Complexity Budgets

- Inline payloads must not gain an extra filesystem copy or receipt lookup when no ingest ID exists.
- Durable external ingest may add one retained-source copy; it must stay off the main actor and use bounded concurrency.
- Exactly-once correctness lives in one final SQLite write transaction; preflight checks are optimization only.
- Receipt and terminal-marker cleanup are bounded by pending work, not a full content scan on every capture.
- Measure external ingest at representative thresholds and run the repository's real snapshot gates before claiming no regression.

## Rollback

- Keep the existing `clipboard_items` and `storage_ref` format; v8 is additive and older explicit-column reads remain possible.
- Commit Slice A and Slice B separately. A regression in cleanup can be reverted without reverting durable ingest, and vice versa.
- Before reverting Slice A to a binary that does not understand receipts/terminal markers, drain pending envelopes/markers and verify receipts are empty.
- Never delete user payloads as part of schema rollback. Unknown artifacts fail closed and remain for a later validated sweep.

## Out Of Scope / Next High-Value Queue

- Power-loss durability policy and its `FULL`/`fsync` performance study.
- General mutation journal/outbox and exact retry counters for post-delete unlink failures.
- The accepted->unreadable payload mismatch above 100 MiB.
- Typed outcomes for every repository mutation, global row revisions, multi-process writers, encryption, and content-addressed deduplication.
- Release publication, tags, pushes, PRs, or Homebrew changes.

## Definition Of Done

- Both P0 failure paths are impossible by construction and covered by deterministic tests.
- Search/UI consume only committed repository outcomes and visibly converge after cleanup.
- Fault-injection/restart evidence, migration evidence, performance evidence, specs, release notes, and implementation agree.
- Work lands as small coherent local commits while `.codex/config.toml` and `.trellis/tasks/07-11-markdown-preview-architecture/` remain untouched.
