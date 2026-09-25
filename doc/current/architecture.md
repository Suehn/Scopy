---
doc_type: spec
status: active
owner: maintainers
last_reviewed: 2026-09-05
canonical: true
related_versions:
  - v0.70.0
  - v0.65.0
---

# Architecture

This document describes the current system shape and operational invariants. For repository workflow, runtime change entrypoints, and validation guidance, use [development-guide.md](./development-guide.md). The historical optimization supplement is preserved in [architecture-v0-supplement-legacy.md](../archive/specs/architecture-v0-supplement-legacy.md).

## Current System Shape

- `Scopy` app target owns app lifecycle, panel/window orchestration, observables, presentation logic, and views.
- `RealClipboardService` bridges the main-actor UI protocol to the `ClipboardBackend` actor; forwarding here enforces isolation rather than introducing another backend.
- `ScopyKit` owns the backend domain/application/infrastructure/services layer and is imported by the app and tests.
- `ScopyUISupport` holds the scroll profiler, `ThumbnailCache`, `IconService`, and `WeakScriptMessageHandler`; only the app target and tests import it.
- `ScopyBench` provides benchmark tooling for backend/perf verification.
- `Tools/MarkdownRenderer` is the Node (remark/rehype/KaTeX) renderer; its bundle and asset manifest are checked into `Scopy/Resources/MarkdownPreview` and loaded by `WKWebView`.
- Sparkle provides update checks and installation.

## Runtime Data Flow

### Clipboard Path

- `ClipboardMonitor` (lifecycle, polling, baseline, orchestration) drives the capture types under `Scopy/Services/Capture`: `PasteboardReadSession` reads one change on the main actor, `CapturePolicy` decides the content type, `CapturedTextExtraction` normalizes text off the main actor, `IngestSpool` owns the durable envelopes, `IngestEnvelopeProcessor` runs the serial bounded queue, and `PasteboardWriter` is the only writer to the pasteboard. It records Scopy's own pasteboard writes as the baseline so they are never recaptured, evaluates each change count once (a failed spool write retries from the data already read), and hands every capture, small or large, to one bounded serial ingest queue (capacity 32) so history order equals copy order; crash replay is ordered by envelope creation time.
- `ClipboardMonitor` writes durable external captures to an Application Support-owned ingest spool before handing work to the service. Pending envelopes remain replayable across process restart; terminal markers make acknowledgement restart-safe.
- `ClipboardBackend` takes the storage-root writer lock (`.scopy-writer.lock`, `flock`) before touching any shared directory; a second instance on the same data directory fails to start with a visible message (run a Debug build against `SCOPY_SERVICE_DB_PATH`). It coordinates ingest, deduplication, cleanup scheduling, and event emission. It publishes search/UI changes only from committed storage outcomes and hands committed cleanup events to an independent cancellation lifetime.
- `StorageService` is an actor whose file-system work never runs on the main thread; cleanup takes a `CleanupPolicy` value per run. It persists structured items, external payloads, and thumbnail-related artifacts, reads payloads of any size the writer accepted, and sweeps unreferenced thumbnails during full cleanup. For a durable ingest ID it retains the source, places the payload at a unique managed path, and commits the item mutation plus the `ingest_receipts` row (introduced in schema user_version 8; current 9) in one `BEGIN IMMEDIATE` transaction.
- Cleanup planning is advisory. `SQLiteClipboardRepository.commitDeletePlan` revalidates the candidate snapshot and deletes matching rows in one write transaction, then returns the exact committed IDs and storage refs used by bounded file cleanup, search invalidation, and one bulk history event.

### Search Path

- UI and state layers issue typed `SearchRequest` values through backend protocols.
- Backend search uses SQLite-backed storage/indexing plus mode-specific search behavior exposed through `SearchMode`.
- `SearchEngineImpl` is the only search actor and routes each request. It reads through `SearchReadStore`, its own read-only connection (never the repository's write connection, since it interrupts that connection on timeout and cancellation), and ranks fuzzy queries with `FullIndexRanker` over indexes held by `FullIndexStore` and `ShortIndexStore`. Index builds run detached on their own read-only connections; a search that needs the full index awaits the build without blocking the actor. `ClipboardItemRow` is the one column list and row decoder both connections use.
- Both connections refuse a database that `SQLiteSchema.requireCurrentSchema` rejects: `user_version` below `SQLiteMigrations.currentUserVersion` or a missing required table (`clipboard_items`, `clipboard_fts`, `clipboard_fts_trigram`, `scopy_meta`, `ingest_receipts`). Trigram FTS and the `scopy_meta` counters are therefore always present; there are no fallbacks for their absence.
- Search results flow back through observables/view models rather than direct view-to-storage access.
- Every commit that advances `mutation_seq` appends one sequenced change to `StorageCommitJournal`; the engine applies changes in order (including batch tombstones for committed cleanup) and rebuilds only on a sequence gap. After 60 s without searches the engine releases its query caches and full index (persisting the index first when the disk cache is stale); memory-pressure warnings trigger the same trim, and critical pressure also drops the short index.

### UI And Preview Path

- App/UI shell manages the menubar icon, floating panel, settings window, and preview/export flows.
- History action flows resolve shareable file URLs through backend protocols; UI rows decide visibility from DTO-level capability hints and do not directly read storage internals.
- Website source icons use one bounded native origin-image service shared by preview and PNG; only decoded cached PNG bytes cross into WebKit, whose HTTP(S) access stays blocked.
- Markdown preview/export share `MarkdownHTMLRenderer -> MarkdownHTMLDocumentBuilder`. The list reuses one hover WebView; each pinned Markdown window owns a separate transferred WebView. Each WebView has one owner lease and per-navigation render IDs; stale callbacks must not publish state. [markdown-chatgpt-wacz-style-contract.md](./markdown-chatgpt-wacz-style-contract.md) owns renderer semantics, layout, local resources, navigation, readiness, and verification.
- Preview and export flows must treat stored content as source-of-truth input, not a side channel that mutates persisted data.

## Operational Invariants

- Views must not directly touch database or filesystem persistence; state and protocols remain the integration boundary.
- System sharing may materialize temporary files for explicit user actions, but file-reveal actions must remain constrained to real user files.
- Settings retain the explicit Save/Cancel model, while hotkey application still flows through `AppDelegate.applyHotKey` and `.settingsChanged`.
- Cleanup, external file reads/writes, thumbnail work, and other heavy operations should remain backgrounded and bounded.
- External storage access continues to require path validation before file operations.
- A durable ingest source is not moved or deleted before the database commit. Receipt replay is an internal no-op, including after the committed item has since been deleted, and acknowledgement reaches a non-replay terminal marker before receipt removal.
- File deletion is DB-first and consumes only commit-time validated refs. Planned rows that became pinned or changed payload identity are skipped, and shared refs are rechecked under path reservations before unlink.
- SQLite failures carry the extended result code; logs record the code and category publicly and the message privately.
- The storage protocol claims D1 process-crash/restart consistency only; WAL `synchronous=NORMAL` and unsynced rename/write paths are not a D2/D3 power-loss guarantee.
- Documentation/release automation reads [release-current.yml](../meta/release-current.yml) as the machine-readable source of truth.

## Stability Priorities

- Favor structured concurrency and bounded work queues over detached or unbounded background work.
- Keep correctness above opportunistic performance shortcuts: fallback paths should preserve complete results and safe deletion behavior.
- Treat protocol-first layering and explicit test surfaces as part of the architecture, not just implementation style.

## Where To Put Future Design Work

- New capabilities that are not yet committed belong in [doc/proposals](../proposals/README.md).
- Historical deep dives and prior optimization reasoning belong in [doc/archive/specs](../archive/specs/README.md).
