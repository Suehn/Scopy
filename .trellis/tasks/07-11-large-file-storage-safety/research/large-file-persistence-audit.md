# Large-file persistence audit

## Scope and conclusion

This audit treats `../prd.md` as the authoritative contract. The defect is confirmed in the current worktree: Scopy's filesystem, domain, DTO, service, and SQLite schema boundaries already carry byte counts as 64-bit values on the supported macOS baseline, but the shared SQLite Swift-`Int` adapter narrows those values through 32-bit C APIs.

The highest-confidence production failure is a legitimate Finder file, or a selection of Finder files, whose logical total is at least `2_147_483_648` bytes. The lazily computed `file_size_bytes` reaches `Int32(value)` and terminates the process with a Swift fatal precondition. Existing valid 64-bit SQLite values are also decoded through `sqlite3_column_int`, which returns a truncated signed 32-bit value; for `size_bytes`, that can make cleanup select substantially more rows than required.

An aggregate `SUM(size_bytes)` above 2 GiB is not by itself broken when every row is below the 32-bit boundary. Aggregate counters already use SQLite 64-bit arithmetic and `columnInt64`. The defect is the shared per-value adapter and the per-row cleanup read.

## Reproduction evidence

### Swift bind-side failure

A local runtime probe using a dynamically parsed value reproduced the exact conversion used by `bindInt`:

```text
Int32(Int("2147483648")!)
Fatal error: Not enough bits to represent the passed value
process exit code: 133
```

This is a process-terminating precondition, not a thrown `Error`, so the surrounding repository/service `do/catch` cannot recover.

### SQLite read-side truncation

An in-memory SQLite probe compared the two C column APIs:

| Persisted SQLite INTEGER | `sqlite3_column_int` | `sqlite3_column_int64` |
|---:|---:|---:|
| `2_147_483_648` | `-2_147_483_648` | `2_147_483_648` |
| `4_294_967_296` | `0` | `4_294_967_296` |
| `6_442_450_944` | `-2_147_483_648` | `6_442_450_944` |

### User-level reproduction

1. Create a sparse regular file with logical length 5 GiB using `FileHandle.truncate(atOffset:)` or an equivalent filesystem utility.
2. Keep file-history capture enabled and copy that file in Finder.
3. Scopy initially persists the file URL/path with `file_size_bytes = NULL`.
4. Publication of the new item schedules lazy filesystem metadata measurement.
5. The exact 5 GiB `Int` reaches `SQLiteStatement.bindInt`, whose `Int32(value)` conversion terminates the app.

Because the database row remains nullable after the failed metadata update, loading that row again can schedule the same computation and repeat the crash.

### Cleanup over-selection reproduction

For a disk-backed test database, insert or inject an unpinned row with `size_bytes = 2_147_483_648`, followed by several small rows, while allowing the existing trigger to maintain `scopy_meta.total_size_bytes`. `getTotalSize()` correctly sees a value above the budget, but `planCleanupByTotalSize` reads the large row through `columnInt`, obtains `-2_147_483_648`, and moves its running total away from the target. It then keeps adding subsequent row IDs, up to its 10,000-row query cap, instead of stopping after the large row.

## Cross-layer trace

### Filesystem measurement

- File URL clipboard capture deliberately stores path/URL representation size rather than reading the target file contents: `Scopy/Services/ClipboardMonitor.swift:1097-1109`.
- `ClipboardContent.sizeBytes` and optional `fileSizeBytes` are Swift `Int`: `Scopy/Services/ClipboardMonitor.swift:135-164`.
- Actual target-file sizes are read from `URLResourceValues.fileSize` and accumulated in a Swift `Int`: `Scopy/Utilities/FilePreviewSupport.swift:137-148`.
- The current `total += size` is safe at 2 GiB on 64-bit macOS, but it is unchecked at `Int.max`; the PRD therefore correctly requires checked aggregation that returns `nil` on overflow.

### Domain, DTO, and service

- The persisted internal model uses `Int` for both byte fields: `Scopy/Infrastructure/Persistence/ClipboardStoredItem.swift:5-19`.
- The presentation-facing DTO preserves the same contract: `Scopy/Domain/Models/ClipboardItemDTO.swift:5-16` and `:20-47`.
- `StorageService.StoredItem` is an alias of `ClipboardStoredItem`, so there is no intermediate narrowing: `Scopy/Services/StorageService.swift:126`.
- A file row with missing metadata schedules lazy size computation: `Scopy/Application/ClipboardService.swift:2359-2360`.
- The bounded worker computes via filesystem metadata: `Scopy/Application/ClipboardService.swift:2423-2439`.
- The result remains `Int` through application and storage coordination: `Scopy/Application/ClipboardService.swift:2442-2452` and `Scopy/Services/StorageService.swift:553-560`.

### Repository writes

The following persistent byte-count writes all use the shared narrowing helper:

- Initial `size_bytes` and optional `file_size_bytes`: `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:148-188`, specifically `:178-182`.
- Payload replacement: `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:225-245`, specifically `:240`.
- Payload compare-and-swap: `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:255-280`, specifically `:276`.
- External-image size reconciliation, including the optimistic expected size: `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:610-633`, specifically `:623-626`.
- Lazy file metadata update: `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:1133-1167`, specifically `:1153-1156`.

The shared implementation is the defect:

- `bindInt(_:)` calls `Int32(value)` and `sqlite3_bind_int`: `Scopy/Infrastructure/Persistence/SQLiteConnection.swift:138-142`.
- An out-of-range conversion terminates before SQLite can return an error.

For externally managed image bytes, filesystem stat also produces a full-width `Int` before passing it to the same batch update: `Scopy/Services/StorageService.swift:979-1018`, specifically `:994-1008`.

### Repository and search reads

The shared read helper is also 32-bit:

- Required integers: `Scopy/Infrastructure/Persistence/SQLiteConnection.swift:192-194`.
- Nullable integers: `Scopy/Infrastructure/Persistence/SQLiteConnection.swift:196-201`.

Affected row decoding includes:

- Repository full row: `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:1216-1252`, specifically `:1230-1235`.
- Repository summary row: `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:1255-1290`, specifically `:1269-1273`.
- Search index/database rebuild: `Scopy/Infrastructure/Search/SearchEngineImpl.swift:1453-1501`, specifically `:1480-1484`.
- Search result hydration: `Scopy/Infrastructure/Search/SearchEngineImpl.swift:5023-5058`, specifically `:5037-5041`.
- External-storage reconciliation records: `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:403-419`, specifically `:415`.

### Presentation and ordering

- File metadata directly formats `fileSizeBytes` when non-null: `Scopy/Presentation/ClipboardItemDisplayText.swift:542-565`.
- The formatter treats a negative truncated value as bytes because it is below 1,024: `Scopy/Presentation/ClipboardItemDisplayText.swift:611-620`.
- Ordinary history ordering is pinned state, recency, then ID, not byte size: `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:423-440`.
- Search ordering is pinned state plus recency/relevance, also not byte size: `Scopy/Infrastructure/Search/SearchEngineImpl.swift:3312-3333`.

Thus the defect does not directly reorder rows. It corrupts displayed metadata and persisted/search representations, and it affects reconciliation and cleanup decisions.

### Statistics and cleanup

- `scopy_meta.total_size_bytes` and fallback `SUM(size_bytes)` are already read through `columnInt64`: `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:576-587`.
- `external_size_bytes` and its fallback aggregate are likewise 64-bit: `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:590-607`.
- The total-size cleanup planner correctly compares the 64-bit aggregate, but reads each row with `columnInt` and accumulates the truncated result: `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:904-953`, specifically `:939-949`.
- The external-storage planner already uses `Int64` for row sizes and accumulation: `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:991-1032`, specifically `:1012-1028`.
- Composite external-byte summation also reads SQL `SUM` through `columnInt64`: `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:956-981`.
- Filesystem directory, database/WAL, and thumbnail totals are Swift `Int` throughout and do not narrow at 2 GiB: `Scopy/Services/StorageService.swift:1058-1077`, `:1087-1100`, and `:1118-1142`.

## Narrowing inventory and classification

### Must change

- `sqlite3_bind_int(statement, index, Int32(value))`: `Scopy/Infrastructure/Persistence/SQLiteConnection.swift:138-142`.
- `sqlite3_column_int` in `columnInt`: `Scopy/Infrastructure/Persistence/SQLiteConnection.swift:192-194`.
- `sqlite3_column_int` in `columnIntOptional`: `Scopy/Infrastructure/Persistence/SQLiteConnection.swift:196-201`.

These helpers are named for Swift `Int`; on the project's 64-bit macOS contract they must use SQLite's 64-bit integer API globally, including byte fields, bools, counts, limits, and offsets.

### Legitimately narrow

- `Int32(index + 1)` values in repository bind loops are SQLite parameter indices, not persisted data: `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:529`, `:974`, and `:1301`. SQLite's C API defines parameter indexes as `int`; practical variable-count limits keep these values far below `Int32.max`.
- `Int32(stmt.columnInt(0))` for `PRAGMA user_version` is a schema-version contract, not a byte count: `Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:38-42`. The current value is 7.
- `UInt16`/`UInt32` conversions in search encode bounded character/bigram keys, not storage sizes.

### Separate defensive concern, out of scope for large logical files

- `bindBlob` converts `data.count` to `Int32`: `Scopy/Infrastructure/Persistence/SQLiteConnection.swift:157-164`.
- Normal payloads at or above 100 KiB are externalized instead of bound inline: `Scopy/Infrastructure/Configuration/ScopyThresholds.swift:18-19` and `Scopy/Services/StorageService.swift:405-434`.
- The PRD explicitly excludes support for BLOBs above SQLite's configured blob limit. A future hardening change may replace the fatal conversion with an explicit size error or use `sqlite3_bind_blob64`, but it should not expand this patch's user-visible scope.

## Schema and migration conclusion

No schema migration is needed or desirable.

- `clipboard_items.size_bytes` and `file_size_bytes` are already SQLite `INTEGER`: `Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:44-63`, specifically `:57` and `:61`.
- Current `PRAGMA user_version` is 7: `Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:3-4`.
- `scopy_meta.total_size_bytes` is an `INTEGER`, backfilled with `SUM(size_bytes)`, and maintained by insert/delete/update triggers: `Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:89-145`.
- `scopy_meta.external_size_bytes` is also an `INTEGER` maintained by 64-bit SQLite arithmetic: `Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:163-230`.

Current `bindInt` does not silently persist a wrapped value: Swift traps before the C call. Therefore a correct existing 64-bit DB value becomes readable immediately after fixing the column adapter. A failed large payload insert may leave an unreferenced external file because the process terminates before the service rollback block runs, but the transaction itself does not commit a truncated integer.

## Recommended repair boundary

1. Change `SQLiteStatement.bindInt(_:)` to bind the Swift `Int` through `sqlite3_bind_int64` (or delegate to the existing `bindInt64` after an exact `Int64` conversion).
2. Change `columnInt(_:)` and `columnIntOptional(_:)` to read through `sqlite3_column_int64` and convert to Swift `Int`. Signed SQLite 64-bit and Swift `Int` have the same range on the supported macOS baseline, so no clamp or fabricated value is needed.
3. Keep `bindInt64`/`columnInt64` for call sites whose durable contract is explicitly `Int64`, such as rowids and SQL aggregates.
4. Keep the parameter-index `Int32` values unchanged.
5. Replace `FilePreviewSupport.totalFileSizeBytes`'s unchecked addition with checked addition. If any addition reports overflow, return `nil`, preserving the public `Int?` contract and the existing unavailable-size behavior.
6. Do not change DTOs, service protocols, cleanup budgets, sorting, UI formatting, schema, or user version.

This shared-adapter repair is preferable to byte-column-specific call-site patches: it makes the abstraction truthful and also protects use counts, item counts, limits, and offsets from the same hidden narrowing.

## Test matrix

| Layer | Required fixture/action | Required assertions | Old-code failure covered |
|---|---|---|---|
| SQLite statement | In-memory statement round-trip for `1`, bool-like `0/1`, ordinary limit/offset, `Int32.max`, `Int32.max + 1`, and `5 * 1024 * 1024 * 1024` | Exact equality; nullable integer preserves `NULL` and large non-null value | Fatal bind and truncated read |
| Disk repository insert/reopen | Insert an item whose `sizeBytes` and `fileSizeBytes` exceed `Int32.max`; close and reopen DB | Both fields exact after reopen; user version remains 7 | Insert fatal; read truncation |
| Payload update/CAS | Replace and CAS payload metadata with >32-bit synthetic byte values without allocating matching data | Updated row exact; optimistic comparison still succeeds/fails under the same ownership rules | Narrow bind in update/CAS |
| Batch reconciliation | Exercise `SizeBytesUpdate` with both new and expected sizes above `Int32.max` | Exactly one matching row changes; stale expected snapshot remains rejected | Narrow bind in both SQL predicates |
| Meta totals | Mix ordinary rows and a >32-bit row | `getTotalSize` and, where applicable, `getExternalSize` equal exact SQL sums | Cross-layer counter disagreement |
| Sparse file | Create a 5 GiB sparse file via `FileHandle.truncate(atOffset:)` | `totalFileSizeBytes` returns exactly 5 GiB without loading contents; lazy metadata persists and reloads it | Real Finder-file crash |
| Multi-file overflow seam | Supply synthetic component sizes whose addition exceeds `Int.max` without creating exabyte files | Aggregator returns `nil`; no trap, wrap, or saturation | Unchecked `total += size` |
| Cleanup planner | Oldest unpinned row is >2 GiB, followed by several small rows; target requires deleting only that row | Delete plan stops after the first row and preserves all later rows | Negative/zero truncation and over-deletion |
| Search/recent fetch | Fetch/search an item with >32-bit byte fields through DB-backed paths | Hydrated `ClipboardStoredItem` values remain exact; ordering unchanged | Search/repository decode truncation |
| Presentation | Build file/image DTOs with 5 GiB sizes | Positive, stable metadata; no UI shape or sort change | Negative/zero display |
| Migration compatibility | Open a pre-existing user-version 7 DB containing 64-bit INTEGER values | No migration runs; values and triggers remain exact | Accidental schema churn |

Focused tests should use synthetic integer values and sparse files; they must not allocate multi-gigabyte `Data` or consume multi-gigabyte physical disk space.

## Performance, compatibility, and rollback

- SQLite `INTEGER` is already signed 64-bit. For ordinary values, `sqlite3_bind_int64` stores the same integer type and compact varint representation; no file-format or query-plan change is expected.
- `sqlite3_column_int64` has negligible cost relative to statement stepping and removes conversion ambiguity. This is a correctness change, not a performance improvement claim.
- Bool, use-count, limit, and offset values retain exact existing semantics; focused ordinary-value tests are required because they share the adapter.
- The only intended behavior change is that values previously fatal or truncated are now exact.
- Sparse-file stat and checked-addition tests avoid memory and disk pressure.
- Rollback is local and schema-free: reverting the adapter, checked aggregation, tests, and documentation restores the old binary behavior without a database downgrade. Data written above `Int32.max` by the corrected build remains valid SQLite data, but rolling back to the old binary would again misread or crash on it; release documentation must state this compatibility boundary.
- Required verification from the PRD remains: focused storage/repository tests, `make build`, `make test-unit`, `make test-strict`, a fresh `make test-snapshot-perf-release`, `make docs-validate`, `make release-validate`, and `git diff --check`.
