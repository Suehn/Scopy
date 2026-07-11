# Storage Commit Protocol Verification

## Outcome

The two selected P0 failures are closed without replacing Scopy's storage model:

- Durable external ingest retains a restart-replayable source until an atomic SQLite item/receipt commit and terminal acknowledgement. Receipt replay is exactly-once and remains a no-op after item deletion.
- Cleanup planning is advisory; commit-time revalidation preserves a newer pin or payload, and search/history/file cleanup consume only the exact committed deletion set.

The implementation is intentionally bounded to D1 process-crash/restart consistency. WAL `synchronous=NORMAL`, unsynced file publication, a generic mutation outbox, and D2/D3 power-loss guarantees remain out of scope.

## Landed Slices

| Commit | Slice | Result |
| --- | --- | --- |
| `c8e55a2` | Durable ingest | Application Support spool, path containment, schema-v8 receipts, atomic exactly-once upsert, terminal acknowledgement, restart cleanup |
| `4708448` | Conditional cleanup | Candidate snapshots, `BEGIN IMMEDIATE` revalidation, exact IDs/refs, bounded shared-ref-safe unlink, cancellation-safe bulk projection |

The architecture/PRD foundation is commit `e806418`.

## Correctness Gates

- `make build`: passed.
- `make test-unit`: 727 tests executed, 1 skipped, 0 failures.
- `make test-strict`: 727 tests executed, 1 skipped, 0 failures.
- `make test-tsan`: 707 tests executed, 1 skipped, 0 failures, no race reports.
- Independent Slice B check: 9 focused tests plus pagination regressions passed; no remaining blocker.
- Real migration: isolated 7,807-row schema-v7 snapshot -> schema v8, row count unchanged, `ingest_receipts` present/empty, `PRAGMA integrity_check = ok`.

The fault matrix uses deterministic persisted-artifact restart seams instead of terminating the XCTest host with `_exit`/SIGKILL. It covers the same observable D1 boundaries while keeping each result inspectable: pending source retention, receipt replay, terminal recovery, legacy migration, containment, post-plan pin/payload changes, shared refs, and post-commit cancellation.

## Performance And Projection Gates

- `make test-snapshot-perf-release`: `cmd p95 0.126958ms <= 50ms`; `cm p95 1.860976ms <= 20ms`.
- Targeted 10k inline cleanup: five iterations, p95 `213.51ms <= 500ms`.
- Targeted 10k external cleanup: 9,147 committed file candidates/attempts, zero cleanup failures, `1748.44ms <= 1800ms`; narrow pass.
- `make perf-frontend-profile-full`: 3 repeats, 10 seconds/scenario, minimum 260 samples; frame p95 `8.333ms` for baseline/current in all scenarios. Mixed long-frame/direction metrics remain non-causal variance.
- Include-hover smoke: both expected buckets present; image decode p95 `0.468ms -> 0.483ms`, Markdown render p95 `0.715ms -> 0.703ms`.
- Final backend audit: passed, including 900-item cleanup `15.20ms`, snapshot E2E `cmd p95 0.16ms`, `cm p95 10.74ms`.
- Unified table: `logs/perf-unified-2026-07-11_19-10-16.md`; all absolute search values remain far below SLOs, with mixed run-to-run movement recorded without attribution.

## Preserved Boundaries

- Public clipboard DTOs, item IDs, search ranking, cleanup settings, storage thresholds, Settings Save/Cancel semantics, and visible event meaning are unchanged.
- Inline ingest without an ingest ID does not gain spool I/O.
- Receipts are content-free and do not cascade on item deletion.
- File deletion remains DB-first, root-contained, shared-ref-safe, bounded, and failure-tolerant.
- User-owned `.codex/config.toml` and `.trellis/tasks/07-11-markdown-preview-architecture/` were not staged or modified by this task.

## Deferred High-Value Work

- Measure `synchronous=FULL` plus `fsync`/`F_FULLFSYNC` before deciding whether D2/D3 durability is worth its latency and write-amplification cost.
- Add a general mutation outbox only if observed orphan-retry ambiguity justifies its schema/state-machine cost.
- Extract `ClipboardIngestSpool` after the protocol has remained stable; do not mix that structural refactor into the correctness release.
