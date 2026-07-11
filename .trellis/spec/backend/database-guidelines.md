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

External file deletion is DB-first. Existing delete paths capture/delete DB rows before deleting files and validate storageRef before touching disk (Scopy/Services/StorageService.swift:422-449, Scopy/Services/StorageService.swift:455-486). Preserve this ordering.

Cleanup logic is performance-sensitive and has feature-flagged fast paths. If changing cleanup count, age, size, external size, or image-only behavior, run unit tests plus snapshot performance tests.

---

## Settings Persistence

SettingsStore is the settings source of truth. It is an actor backed by UserDefaults, caches loaded settings, broadcasts an AsyncStream, and clamps decoded values (Scopy/Infrastructure/Settings/SettingsStore.swift:4-18, Scopy/Infrastructure/Settings/SettingsStore.swift:20-56, Scopy/Infrastructure/Settings/SettingsStore.swift:64-120).

Do not add new direct UserDefaults reads/writes for settings in unrelated files. Add fields to SettingsDTO, SettingsDTO+Patch, SettingsPatch, SettingsStore.encode, SettingsStore.decode, settings UI, and tests together.
