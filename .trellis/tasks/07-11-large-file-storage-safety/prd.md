# 64-bit Storage Byte Accounting

## Goal

Eliminate deterministic crashes and truncation when Scopy encounters a legitimate file or persisted byte count above the signed 32-bit range. Preserve the current user-visible model and SQLite schema while making the existing Swift `Int` contract lossless on the project's 64-bit macOS baseline.

## What I Already Know

- `project.yml` fixes the supported baseline at Swift 5.9, macOS 14.0, and Xcode 16.0; modern macOS processes use a 64-bit `Int`.
- SQLite `INTEGER` storage is already signed 64-bit. No schema migration is required to store a 5 GiB logical size.
- `SQLiteStatement.bindInt(_:)` currently calls `Int32(value)` and `sqlite3_bind_int`; `columnInt(_:)` and `columnIntOptional(_:)` likewise read with `sqlite3_column_int`.
- Current repository insert, payload update, batch reconciliation, and file-size metadata update paths all use those helpers for `size_bytes` or `file_size_bytes`.
- Repository/search row hydration also uses the 32-bit column helper. A pre-existing 4 GiB SQLite value therefore reads as zero, while `Int32.max + 1` reads as a negative number.
- Cleanup total thresholds use correct 64-bit SQL aggregates, but the per-row cleanup planner currently decodes `size_bytes` through `columnInt`. A large row can therefore fail to satisfy the target and cause subsequent rows to be over-selected for deletion.
- A local runtime probe with `Int32(Int(Int32.max) + 1)` exits by fatal error (`Not enough bits to represent the passed value`), so this is a confirmed crash rather than a theoretical truncation concern.
- `FilePreviewSupport.totalFileSizeBytes` reads metadata only, but its unchecked `total += size` can also trap if an aggregate exceeds `Int.max`.
- Foundation documents `FileHandle.truncate(atOffset:)` as `func truncate(atOffset offset: UInt64) throws`, which permits a sparse-file regression fixture without allocating the logical file size in memory.
- The current `.codex/config.toml` change is user-owned and must remain untouched.

## Requirements

1. A SQLite helper named for Swift `Int` must bind and read the full Swift `Int` domain supported by this 64-bit macOS target; it must not silently narrow through a 32-bit C API.
2. Existing `size_bytes` and `file_size_bytes` paths must round-trip values above `Int32.max` through insert, fetch, payload replacement/CAS, batch reconciliation, metadata update, and database reopen.
3. Existing bool, use-count, limit, and offset callers of `bindInt`/`columnInt` must retain their current behavior.
4. A sparse 5 GiB file must be measured from filesystem metadata and persisted/reloaded without reading or allocating its contents.
5. Multi-file logical-size aggregation must never overflow or crash. If the exact sum cannot be represented by the public `Int?` contract, return `nil` rather than publish a fabricated or wrapped value.
6. Keep `ClipboardItemDTO`, stored-item, service protocol, presentation, and Settings byte-count types unchanged. On the supported platform, `Int` is already the correct native 64-bit boundary.
7. Keep the SQLite schema and `PRAGMA user_version` unchanged; this is a binding/decoding correction, not a migration.
8. Preserve all clipboard capture, file preview, sorting, cleanup, search, Settings, and UI behavior for ordinary sizes.
9. Cleanup planning must use the exact positive size of a large row and stop once its byte target is satisfied; it must never over-delete because a row decoded as negative or zero.
10. Search/recent hydration and display-facing DTOs must retain the exact positive large values.
11. Add focused tests that would fail or crash on the old implementation, and run storage/repository, full unit, build, and real snapshot performance gates.
12. Record the defect, compatibility boundary, verification evidence, and rollback surface in task and release documentation before committing.

## Acceptance Criteria

- [x] `SQLiteStatement.bindInt` uses a 64-bit SQLite binding and `columnInt`/optional read through the 64-bit SQLite column API.
- [x] Focused statement coverage round-trips at least `Int32.max + 1`, `5 * 1024^3`, and ordinary pagination/bool values, including nullable integers.
- [x] A disk-backed repository test inserts, closes, reopens, fetches, updates, and totals an item whose byte fields exceed `Int32.max` with exact equality.
- [x] A cleanup regression proves that one large old row satisfies the target without selecting unrelated later rows.
- [x] A display/search-facing regression keeps a 5 GiB size positive and exact after hydration.
- [x] A sparse 5 GiB file is created with `FileHandle.truncate(atOffset:)`; `FilePreviewSupport.totalFileSizeBytes` returns exactly 5 GiB without materializing 5 GiB of data.
- [x] Multi-file aggregation has an explicit overflow test seam and returns `nil` on overflow rather than trapping or saturating silently.
- [x] No migration or public DTO/protocol shape changes are introduced.
- [x] `make build` and `make test-unit` pass.
- [x] `make test-strict` passes because the storage actor and async metadata path are covered, even though no new concurrency mechanism is added.
- [x] `make test-snapshot-perf-release` passes on a fresh snapshot; no performance improvement is claimed from a correctness-only change.
- [x] `make docs-validate`, `make release-validate`, and `git diff --check` pass.
- [x] Changes are split into coherent, reversible local commits; no push or tag is performed.

## Definition Of Done

- The old 32-bit conversion crash is reproducibly covered and cannot occur on any current Swift `Int` SQLite call site.
- Large logical file sizes remain exact across filesystem metadata, application/storage coordination, SQLite persistence, reload, and presentation-facing DTO construction.
- Ordinary-size behavior and performance gates remain green.
- Research, requirements, test evidence, release notes, and rollback scope are committed with the implementation.

## Expansion Sweep

### Future Evolution

- Preserve a faithful generic Swift `Int` SQLite contract so future counters do not need per-column 64-bit exceptions.
- Keep explicit `bindInt64`/`columnInt64` for rowids and SQL aggregates whose durable contract is specifically `Int64`.

### Related Scenarios

- Payload `size_bytes`, lazily computed file `file_size_bytes`, metadata trigger totals, cleanup size selection, and Settings display must agree.
- Pagination and boolean columns share the same helper and therefore require regression coverage after the global correction.

### Failure And Edge Cases

- `nil` file metadata remains `NULL`; unreadable or missing files remain unavailable rather than zero.
- Aggregate overflow must be explicit and non-crashing.
- SQLite integers outside the supported Swift `Int` range are impossible on the current 64-bit baseline because both are signed 64-bit; no lossy clamp is introduced.

## Decision (ADR-lite, Provisional)

**Context**: Fixing only three repository call sites would leave a misleading `bindInt`/`columnInt` abstraction that can reintroduce the same defect elsewhere. Migrating every public byte field to `Int64` would add broad API churn without increasing capacity on the supported platform.

**Decision**: Correct the shared SQLite Swift-`Int` adapter to use `sqlite3_bind_int64`/`sqlite3_column_int64`, keep explicit `Int64` helpers for durable `Int64` contracts, and add checked filesystem aggregation. Prove the cross-layer path with sparse-file and disk-reopen tests.

**Consequences**: The patch stays schema-free and user-invisible, fixes every current `Int` call site consistently, and remains locally reversible. Tests must guard both large values and ordinary pagination/boolean behavior because the adapter is shared.

## Out Of Scope

- Changing the app's public byte-count types from `Int` to `Int64`.
- Supporting payloads or SQLite BLOBs above SQLite's configured blob limit.
- Changing cleanup budgets, file-size display formatting, search behavior, or UI layout.
- Fixing release auto-tag gating; that is a separate P0 task and commit sequence.
- Tagging, pushing, publishing, or mutating Homebrew state.

## Technical Notes

- Primary adapter: `Scopy/Infrastructure/Persistence/SQLiteConnection.swift`.
- Persistence paths: `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift`.
- File metadata path: `Scopy/Utilities/FilePreviewSupport.swift` through `ClipboardService` and `StorageService`.
- Relevant specs: backend database, error-handling, quality, directory-structure, and shared cross-layer/reuse guides.
- Apple contract: Foundation `FileHandle.truncate(atOffset:) -> Void`, throwing, with a `UInt64` offset.

## Research References

- [`research/large-file-persistence-audit.md`](research/large-file-persistence-audit.md) — end-to-end crash, truncation, cleanup, schema, and test-boundary audit from the current worktree.
- [`verification.md`](verification.md) — requirement-by-requirement evidence, exact gate results, snapshot identity, commits, and rollback boundary.
