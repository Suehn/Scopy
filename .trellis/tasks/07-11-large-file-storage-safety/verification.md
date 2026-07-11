# Final Verification

## Outcome

The confirmed signed-32-bit persistence failure is closed without changing the user-visible model or SQLite schema. Swift `Int` values now use SQLite's signed 64-bit APIs, and multi-file logical-size aggregation fails safely on overflow. Legitimate byte counts above 2 GiB remain exact through persistence, reopen, mutation, cleanup planning, recent/search-facing hydration, and display.

## Requirement Evidence

| Requirement | Current evidence |
| --- | --- |
| Full Swift `Int` SQLite contract | `SQLiteStatement.bindInt`, `columnInt`, and `columnIntOptional` use `sqlite3_bind_int64` / `sqlite3_column_int64`; `SQLiteIntegerWidthTests` covers zero, one, ordinary values, `Int32.max`, `Int32.max + 1`, 5 GiB, `Int.max`, and `NULL`. |
| Confirmed old failure | A pre-fix runtime probe of `Int32(Int(Int32.max) + 1)` exited 133 with `Not enough bits to represent the passed value`; raw SQLite reads also reproduced negative/zero truncation. The focused statement test would crash or fail on that adapter. |
| Disk persistence and reopen | `StorageServiceTests.testLargeByteCountsPersistAcrossDiskReopenAndMetadataUpdates` inserts, closes, reopens twice, fetches, updates payload and file metadata, fetches recent, and checks totals with exact values above `Int32.max` and 5 GiB. |
| CAS and reconciliation | `testLargePayloadCASAndBatchSizeReconciliationRemainExactAndRejectStaleSnapshots` proves exact large values plus stale compare-and-swap and batch-update rejection. |
| Cleanup deletion safety | `testCleanupPlannerStopsAfterRawInjectedLargeRowSatisfiesTarget` injects a pre-existing 2,147,483,648-byte row through the explicit `Int64` helper and proves the plan selects only that row, not the later unrelated row. |
| Recent/search-facing hydration | Repository recent hydration proves exact large fields after disk reopen. `SearchEngineImpl` reads its size fields through the same corrected `columnInt` / optional adapter, whose full-domain statement regression is independent of repository insertion. |
| Display contract | `ClipboardItemDisplayTextTests.testFileTitleAndMetadataMatchLegacyImplementation` includes an exact 5 GiB input and retains the established `5120.0 MB` presentation. |
| Sparse filesystem boundary | `testSparseFiveGiBFileMetadataAndCheckedAggregation` uses Foundation's throwing `FileHandle.truncate(atOffset: UInt64)` contract, closes the handle, and reads exact logical metadata without allocating file contents. |
| Overflow behavior | `FilePreviewSupport.checkedTotalFileSizeBytes` streams a `Sequence`, uses `addingReportingOverflow`, returns `nil` for empty/unreadable inputs or overflow, and is tested with `[Int.max, 1]`. |
| Ordinary callers unchanged | The statement regression includes ordinary/boolean-shaped values; the full unit, strict, and TSan suites cover limits, offsets, booleans, counts, and current storage/search behavior. |
| Schema and API compatibility | `SQLiteMigrations.currentUserVersion` remains 7; `ClipboardItemDTO`, `ClipboardStoredItem`, service protocols, Settings types, and SQLite table definitions are unchanged. |
| Performance boundary | A fresh realistic snapshot passed the existing Release thresholds. This correctness-only adapter change makes no performance-improvement claim. |

## Quality Gates

- Focused implementation suite: 6 tests, 0 failures.
- Independent Trellis check: no P0/P1/P2 findings; no production `sqlite3_bind_int` / `sqlite3_column_int` call remains.
- `make build`: passed with the repository baseline (`MARKETING_VERSION=0.8.8`, `CURRENT_PROJECT_VERSION=425` at that gate).
- `make test-unit`: 706 executed, 1 skipped, 0 failures.
- `make test-strict`: 706 executed, 1 skipped, 0 failures.
- `make test-tsan`: 686 executed, 1 skipped, 0 failures; no race report.
- `make snapshot-perf-db`: 7,807 rows, schema version 7, 98,922,496 bytes.
- Snapshot SHA-256: `3ec03a0ccd6b486e9f36f26c6597245828cf93fe23f5582908e0cfa260145ddd`.
- Snapshot `PRAGMA integrity_check`: `ok`.
- `make test-snapshot-perf-release`: `cmd p95 0.13399124145507812ms` against 50ms; `cm p95 1.8749237060546875ms` against 20ms; passed.
- `make docs-validate`: `Docs OK: v0.65.0`.
- `make release-validate`: `OK: v0.65.0`.
- `git diff --check`: passed for task-owned changes.

## Commits And Rollback

- `8b78f10` — research, PRD, and bounded Trellis contexts.
- `ecc8a83` — production adapter, checked file-size aggregation, generated project membership, and regressions.
- `c84ac0c` — executable lossless SQLite integer specification.
- `5dbb9fe` — high-leverage task-selection guide requested for future roadmap decisions.
- `133708e` — current requirements, development/runbook, release metadata, changelog, release note, and audit closure status.

The implementation rollback boundary is `ecc8a83`; it has no migration, user-data rewrite, feature flag, DTO change, or cleanup-policy change. Reverting it restores the prior adapter and tests as one coherent unit. No tag, push, release publication, or Homebrew mutation was performed.

The user-owned `.codex/config.toml` and the unrelated untracked `.trellis/tasks/07-11-markdown-preview-architecture/` directory were left untouched and uncommitted.

## Next High-Leverage Item

The separate confirmed P0 remains release trust: `.github/workflows/auto-tag.yml` can create a release tag without depending on complete build, unit, strict-concurrency, documentation, and release validation. It must be handled as a new researched task and commit sequence rather than expanded into this storage rollback unit.
