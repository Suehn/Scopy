# Database Guidelines

> SQLite, repository, migrations, settings persistence, search indexes, and file-backed storage rules.

---

## Storage Model

Scopy uses SQLite plus external files. Small clipboard content is stored in the database; large payloads use external storage under the app support directory, with metadata and storage_ref kept in SQLite. StorageService owns the threshold and external path setup (Scopy/Services/StorageService.swift:51-55, Scopy/Services/StorageService.swift:87-135).

Do not bypass StorageService or SQLiteClipboardRepository for clipboard item persistence. StorageService coordinates external files, cleanup, cache invalidation, and DB operations; direct file or SQL changes can desynchronize the two stores.

---

## SQLite Access

SQLiteClipboardRepository is an actor and owns repository-level SQL (Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:4-17). SQLiteConnection and SQLiteStatement wrap raw SQLite handles, prepare, bind, finalize, close, and WAL checkpoint behavior (Scopy/Infrastructure/Persistence/SQLiteConnection.swift:4-92, Scopy/Infrastructure/Persistence/SQLiteConnection.swift:98-159).

Required patterns:

- Use prepared statements and typed bind helpers; do not interpolate user/content values into SQL.
- Keep writes inside repository transaction helpers; existing insert/update paths call performWriteTransaction (Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:127-167).
- Keep repository methods actor-isolated. Do not share raw sqlite3 handles across actors or the main actor.
- On open, preserve the current WAL/cache/temp/mmap pragmas and schema verification flow (Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:63-84).

## Scenario: Lossless Swift `Int` Persistence

### 1. Scope / Trigger

- Trigger: any SQLite column or expression whose Swift contract is `Int`, including byte counts, pagination, booleans, use counts, limits, and offsets.
- On the supported 64-bit macOS baseline, the adapter must preserve the full signed Swift `Int` domain. Do not infer a 32-bit storage limit from SQLite parameter indexes, which remain `Int32` by C API contract.

### 2. Signatures

```swift
func bindInt(_ value: Int, at index: Int32) throws
func columnInt(_ index: Int32) -> Int
func columnIntOptional(_ index: Int32) -> Int?

func bindInt64(_ value: Int64, at index: Int32) throws
func columnInt64(_ index: Int32) -> Int64
```

- `bindInt` must call `sqlite3_bind_int64(statement, index, Int64(value))`.
- `columnInt` and `columnIntOptional` must call `sqlite3_column_int64` before converting to Swift `Int`.
- Keep explicit `Int64` helpers for row IDs, SQL aggregates, and other durable contracts that are intentionally `Int64`.
- SQLite `INTEGER` is already signed 64-bit; correcting an adapter is not, by itself, a schema migration or `PRAGMA user_version` change.

### 3. Contracts

- Input: every Swift `Int` accepted by the current 64-bit target, including values above `Int32.max`.
- Output: exact round-trip equality; `NULL` remains `nil` through `columnIntOptional`.
- Byte-count fields such as `size_bytes` and `file_size_bytes` must stay exact across insert, reopen, payload compare-and-swap, batch reconciliation, cleanup planning, search/recent hydration, and presentation-facing DTO construction.
- Filesystem logical-size aggregation returns the exact `Int` sum or `nil` when no readable sizes exist or the sum overflows. It must not wrap, saturate, or trap.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|-----------|-------------------|
| Ordinary boolean, limit, offset, or byte value | Preserve existing value and behavior |
| `Int32.max + 1` through `Int.max` | Bind and read exactly through SQLite int64 APIs |
| SQLite `NULL` through optional helper | Return `nil` |
| SQLite bind failure | Throw `SQLiteConnectionError.bindFailed` |
| File metadata unavailable or input empty | Return `nil` |
| File-size aggregate addition overflows `Int` | Return `nil` without a trap or fabricated value |
| Adapter-only correction with unchanged columns | Keep schema version unchanged |

### 5. Good / Base / Bad Cases

- Good: a sparse 5 GiB file is measured from metadata, persisted, reopened, updated, hydrated, and displayed with the exact positive byte count.
- Base: pagination values, booleans, and small clipboard payload sizes retain their current behavior through the same shared adapter.
- Bad: `Int32(value)`, `sqlite3_bind_int`, or `sqlite3_column_int` in a helper whose public contract is Swift `Int`; values above 2 GiB can crash, become negative, or become zero and can make cleanup over-select rows.

### 6. Tests Required

- Statement unit test: round-trip `0`, `1`, an ordinary value, `Int32.max`, `Int32.max + 1`, 5 GiB, `Int.max`, and `NULL`.
- Disk repository test: insert, close, reopen, fetch, update payload/file metadata, close, reopen, and assert exact large values and totals.
- Cleanup regression: inject an old row above 2 GiB followed by a small row; assert the first row alone satisfies the target.
- Filesystem regression: create a sparse 5 GiB file with `FileHandle.truncate(atOffset:)`, read metadata without materializing contents, and assert exact aggregation.
- Overflow seam: assert `Int.max + 1` returns `nil` rather than trapping.
- Run `make build`, `make test-unit`, `make test-strict`, and `make test-snapshot-perf-release`; use `make test-tsan` when the changed storage path overlaps concurrency-sensitive code.

### 7. Wrong vs Correct

#### Wrong

```swift
sqlite3_bind_int(statement, index, Int32(value))
Int(sqlite3_column_int(statement, index))
```

#### Correct

```swift
sqlite3_bind_int64(statement, index, Int64(value))
Int(sqlite3_column_int64(statement, index))
```

---

## Scenario: Crash-Consistent Ingest And Conditional Cleanup

### 1. Scope / Trigger

- Trigger: a clipboard ingest uses a durable external payload, or a retention policy plans deletion separately from the final database write.
- The contract covers D1 process termination and restart. It does not claim D2/D3 power-loss durability while SQLite uses WAL `synchronous=NORMAL` and file publication does not issue `fsync`/`F_FULLFSYNC`.
- Inline payloads without an ingest ID keep the ordinary fast path; do not add spool I/O or receipt lookups to that path.

### 2. Signatures

```swift
enum StorageService.UpsertOutcome {
    case inserted(ClipboardStoredItem)
    case updated(ClipboardStoredItem)
    case alreadyApplied(ClipboardStoredItem?)
}

struct SQLiteClipboardRepository.DeleteCandidate {
    let id: UUID
    let type: ClipboardItemType
    let contentHash: String
    let lastUsedAt: Date
    let sizeBytes: Int
    let storageRef: String?
}

struct SQLiteClipboardRepository.DeleteCommitResult {
    let plannedCount: Int
    let deletedItemIDs: [UUID]
    let storageRefs: [String]
}

struct StorageService.CleanupResult {
    let plannedItemCount: Int
    let deletedItemIDs: [UUID]
    let skippedItemCount: Int
    let fileDeletionCandidateCount: Int
    let fileDeletionAttemptCount: Int
    let fileCleanupFailureCount: Int
}

func commitDeletePlan(_ plan: DeletePlan) throws -> DeleteCommitResult
case ClipboardEvent.itemsRemoved([UUID])
```

- Schema v8 adds content-free `ingest_receipts(ingest_id PRIMARY KEY, item_id, committed_at)` without a cascading foreign key.
- The ingest ID is the durable envelope UUID. Repository receipt lookup, item insert/dedup mutation, and receipt insert belong to one `BEGIN IMMEDIATE` transaction.

### 3. Contracts

- Write the owned payload and pending envelope under the Application Support spool before queueing ingest work. Validate decoded filenames and acknowledgement URLs against that root; traversal, symlinks, and foreign paths fail closed.
- Retain a durable spool source through candidate publication and database commit. Derived transforms use separately owned, bounded work files.
- An existing receipt returns `alreadyApplied` without a second insert, use-count increment, or success publication. Keep the receipt after item deletion so an old envelope cannot resurrect the item.
- Acknowledgement atomically transitions pending envelope -> terminal marker before receipt removal. Restart finishes terminal-marker cleanup idempotently.
- A `DeletePlan` is an advisory snapshot. `commitDeletePlan` must reload candidates and revalidate unpinned state plus type, content hash, recency, size, and storage ref in one write transaction before deletion.
- Return only exact committed item IDs and refs. File cleanup must be DB-first, containment-validated, shared-ref-safe, bounded, and failure-tolerant.
- Invoke the committed cleanup callback immediately after the DB commit. Search invalidation and one bulk `.itemsRemoved(ids)` event must survive caller cancellation after commit; history removes those IDs without resetting pagination and refreshes the authoritative total.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|-----------|-------------------|
| Payload written, envelope creation fails | Reclaim only the proven-owned orphan; never touch a foreign path |
| Process stops with a pending envelope | Source and envelope remain restart-replayable |
| SQLite upsert rolls back | Source/envelope remain; no item event; candidate is safely reclaimable |
| Commit succeeds before acknowledgement | Receipt makes replay `alreadyApplied`; usage and events remain exactly-once |
| Terminal rename fails | Pending envelope and receipt remain for retry |
| Terminal rename succeeds before cleanup | Marker is never replayed; receipt/artifact cleanup resumes idempotently |
| Committed item is later deleted | Receipt still prevents resurrection |
| Envelope/payload path traverses or resolves through a symlink | Reject without reading/deleting outside the owned spool |
| Planned row becomes pinned | Skip row and file; exclude from committed IDs/refs |
| Planned row changes payload identity or cleanup snapshot | Skip current row/current ref |
| Shared storage ref still has a live owner | Do not unlink it |
| Caller is cancelled after DB cleanup commit | Deliver exact search/UI convergence from independent handoff |
| External unlink fails | Keep row deleted, count the failure, allow orphan reconciliation |

### 5. Good / Base / Bad Cases

- Good: a 10 MiB external image has a durable pending envelope, commits once with its receipt, then an acknowledgement retry returns `alreadyApplied` and only finishes terminal cleanup.
- Good: cleanup plans 10,000 rows; one row is pinned and another replaces its payload before commit. Both survive, while the returned IDs/refs contain only rows deleted from their still-matching snapshots.
- Base: inline text without an ingest ID uses the existing direct transaction and product event behavior; ordinary user delete remains DB-first.
- Bad: move the only spool payload into managed storage before SQLite commits, or delete planned IDs unconditionally after actor reentrancy. Either loses retryable data or overwrites a newer pin/payload decision.

### 6. Tests Required

- Ingest fault/restart tests: envelope-write failure, candidate-publication failure, transaction rollback, duplicate receipt replay, existing-hash replay, item-deleted-after-receipt, terminal-marker recovery, bounded orphan cleanup, and legacy cache migration.
- Containment tests: traversal, foreign acknowledgement URL, symlink destination/source, malformed payload name, and terminal marker ownership.
- Migration test: copy a real schema-v7 snapshot, open through current code, assert `user_version = 8`, `ingest_receipts` exists and is empty, row count is unchanged, and `PRAGMA integrity_check = ok`.
- Cleanup races: post-plan pin, payload replacement, recency/size/ref mismatch, shared ref, file-removal failure, multi-stage partial success, cancellation after commit, bounded bulk queue, stale publication tokens, pagination preservation, and authoritative total refresh.
- Performance: representative 10k inline/external cleanup, `make test-snapshot-perf-release`, and frontend/unified profiling when projection/event code changes.
- Required gates: `make build`, `make test-unit`, `make test-strict`, and `make test-tsan`.

### 7. Wrong vs Correct

#### Wrong

```swift
let source = try moveSpoolPayloadIntoManagedStorage()
try await repository.insertItem(itemUsing: source) // rollback loses the only replay source

let ids = try await repository.planCleanup()
try await repository.deleteItems(ids: ids) // plan may be stale after actor suspension
```

#### Correct

```swift
let candidate = try copyDurableSourceToUniqueManagedStorage()
let outcome = try await repository.upsert(itemUsing: candidate, ingestID: envelope.id)
// item mutation + receipt commit atomically; acknowledge only after commit

let plan = try await repository.planCleanup()
let committed = try await repository.commitDeletePlan(plan)
// clean files and projections from committed.deletedItemIDs/storageRefs only
```

---

## Migrations

Schema changes belong in SQLiteMigrations. Current schema version is tracked by currentUserVersion and PRAGMA user_version (Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:4-39). Migrations must be idempotent and safe for existing user databases.

Required patterns:

- Bump currentUserVersion when schema changes require migration.
- Add columns with addColumnIfNeeded rather than assuming a fresh database (Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:347-362).
- Keep FTS and trigram FTS setup in migrations/search infrastructure, not scattered across repository callers (Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:250-334).
- Preserve metadata counters and triggers when changing item count, size, pin, or external-size semantics (Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:80-215).

---

## Search Indexes

Search behavior is backed by SQLite FTS and repository/search coordination. SearchEngineImpl owns SearchRequest execution and reacts to item updates from the application service (Scopy/Application/ClipboardService.swift:237-249, Scopy/Application/ClipboardService.swift:252-280).

When changing search:

- Keep SearchRequest, SearchMode, SearchSortMode, and SearchCoverage semantics aligned across domain models, search engine, history view model, and tests.
- Update FTS trigger/migration logic when indexed fields change.
- Run search consistency and performance tests; for release-grade backend performance, use make test-snapshot-perf-release.

---

## Deletion And Cleanup

External file deletion is DB-first. Cleanup planning is advisory; `commitDeletePlan` revalidates the candidate snapshot and captures exact refs in the deleting transaction. StorageService validates containment and surviving ownership before unlink. Preserve this ordering.

Cleanup logic is performance-sensitive and has feature-flagged fast paths. If changing cleanup count, age, size, external size, or image-only behavior, run unit tests plus snapshot performance tests.

---

## Settings Persistence

SettingsStore is the settings source of truth. It is an actor backed by UserDefaults, caches loaded settings, broadcasts an AsyncStream, and clamps decoded values (Scopy/Infrastructure/Settings/SettingsStore.swift:4-18, Scopy/Infrastructure/Settings/SettingsStore.swift:20-56, Scopy/Infrastructure/Settings/SettingsStore.swift:64-120).

Do not add new direct UserDefaults reads/writes for settings in unrelated files. Add fields to SettingsDTO, SettingsDTO+Patch, SettingsPatch, SettingsStore.encode, SettingsStore.decode, settings UI, and tests together.
