---
doc_type: spec
status: active
owner: maintainers
last_reviewed: 2026-10-28
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
- `ClipboardMonitor` writes durable captures to an Application Support-owned ingest spool before handing work to the service. `CapturedPayload` binds replay identity to its prepared bytes: a source file remains owned by spool acknowledgement, while a transformed work file stays alive through its last user. A file transform publishes its new hash and size only after reading back the completed output. Pending envelopes remain replayable across process restart; terminal markers make acknowledgement restart-safe.
- `ClipboardBackend` takes the storage-root writer lock (`.scopy-writer.lock`, `flock`) before touching any shared directory; a second instance on the same data directory fails to start with a visible message (run a Debug build against `SCOPY_SERVICE_DB_PATH`). It coordinates ingest, deduplication, cleanup scheduling, and one history publisher with its own journal cursor. Shutdown closes admission and joins capture, ingest, cleanup, media work, and accepted storage requests; it then publishes through the final commit position, joins the publisher and search work, closes storage, and releases the lock. Concurrent callers join the same startup or shutdown task.
- `StorageService` is an actor whose file-system work never runs on the main thread; cleanup takes a `CleanupPolicy` value per run. It persists structured items, external payloads, and thumbnail-related artifacts, reads payloads of any size the writer accepted, and sweeps unreferenced thumbnails during full cleanup. For a durable ingest ID it retains the source, places the payload at a unique managed path, and commits the item mutation plus the `ingest_receipts` row (introduced in schema user_version 8; current 9) in one `BEGIN IMMEDIATE` transaction.
- The repository captures changed summary rows or exact deleted IDs, `totalCount`, and `mutationSeq` in the write transaction. After COMMIT, the same actor job appends that fact to `StorageCommitJournal`; later publication never replaces it with an asynchronous reread. No-op and receipt-maintenance operations do not advance the history sequence; an empty Clear still records the command. Cleanup planning is advisory: `commitDeletePlan` revalidates its candidates and returns only committed IDs and refs for bounded file cleanup and history publication.

### Search Path

- UI and state layers issue typed `SearchRequest` values through backend protocols.
- Backend search uses SQLite-backed storage/indexing plus mode-specific search behavior exposed through `SearchMode`.
- `SearchEngineImpl` is the only search actor and routes each request. It reads through `SearchReadStore`, its own read-only connection, and ranks fuzzy queries with `FullIndexRanker` over indexes held by `FullIndexStore` and `ShortIndexStore`. SQLite progress callbacks observe the executing task's cancellation; deadline arbitration runs outside the search actor, so cancelling a request waiting elsewhere cannot interrupt another request's SQL. Closing the engine releases its recent and full-index snapshots before reopening. Index builds run detached on their own read-only connections; a search that needs the full index awaits the build without blocking the actor. `ClipboardItemRow` is the one column list and row decoder both connections use.
- Substring matching over stored rows and indexed text goes through `LoweredTextMatcher`: it decides on UTF-8 bytes, without decoding or lowercasing, exactly where bytes agree with `String` lowercasing and `range(of:)`, and leaves every other case to `String`. `UTF8Text` supplies the shared plain-starter classification, character cursor, and UTF-16 counting used by indexing, ranking, and match evidence. Runs of well-formed text without special scalars are validated and counted 16 bytes at a time. An ASCII hit beside non-ASCII text is decided when that neighbour is a plain starter (CJK, kana, Hangul syllables, most symbols and emoji), which cannot share a character with it. Full-index postings use `UInt32` slots and hold each character and each scalar inside a multi-scalar character, so candidate narrowing stays conservative for both code-unit (short needles) and whole-character matching.
- Both connections refuse a database that `SQLiteSchema.requireCurrentSchema` rejects: `user_version` below `SQLiteMigrations.currentUserVersion` or a missing required table (`clipboard_items`, `clipboard_fts`, `clipboard_fts_trigram`, `scopy_meta`, `ingest_receipts`). Trigram FTS and the `scopy_meta` counters are therefore always present; there are no fallbacks for their absence.
- Search results flow back through observables/view models rather than direct view-to-storage access.
- `StorageCommitJournal` keeps at most 1,024 entries and an estimated 8 MiB of retained facts. Search and presentation read independently with `read(after:through:)`; reads do not drain the log. Coalesced wakeups are hints to read it, not ordered facts. Missing history or a single oversized fact requires a new database snapshot.
- Recent pages, search pages, and index builds carry the `mutationSeq` from their actual SQLite read snapshot. Full and short indexes each track their own position and apply only journal facts through the query's snapshot version; neither keeps a second build-time pending ledger. A gap forces a complete query scan, ranking, and hydration in one read snapshot, rather than waiting for a quiet write period. After 60 s without searches the engine releases its query caches and full index (persisting the index first when the disk cache is stale); memory-pressure warnings trigger the same trim, and critical pressure also drops the short index.

### UI And Preview Path

- App/UI shell manages the menubar icon, floating panel, settings window, and preview/export flows.
- `AppState` owns the service and shared view models for their whole lifetime. Concurrent starts or stops join the same task; shutdown settles an in-flight startup before stopping the backend, then ends event consumption and history work. `HistoryRequestLifecycle` separately owns replacement, refresh, pagination, and refinement work; its request versions reject stale results without changing the projection identity used by Undo.
- History action flows resolve shareable file URLs through backend protocols; UI rows decide visibility from DTO-level capability hints and do not directly read storage internals.
- Row subscriptions belong to mounted-row tokens, so an old row's teardown cannot unregister its replacement. The interaction host delegates drawing to `HistoryItemRowLabel`; only `HistoryItemRelativeTimeView` observes the relative-time clock.
- `ThumbnailCache` owns admission, shared decode work, waiters, and cache publication. Invalidation retires a load's publication rights while its active slot remains occupied until ImageIO returns. `IconService` keeps each application's name and icon behind one cached LaunchServices lookup.
- Website source icons use one bounded native origin-image service shared by preview and PNG; only decoded cached PNG bytes cross into WebKit, whose HTTP(S) access stays blocked.
- `PreparedMarkdownDocument` holds one source, frozen render context, identity, and HTML from `MarkdownHTMLDocumentBuilder.document(source:context:)`. Asynchronous preparation reads the sidecar through the `LinkEnrichmentStore` actor; preview bodies read the prepared value. Pinning transfers that value and its live-render state. Export captures it and preserves its frozen enrichment even when a different layout scale requires rebuilding the HTML.
- Previews of the same content share one enrichment task. Each owns its subscription; the last departing consumer requests cancellation. The work retains its network permit until native completion, and a retired task cannot remove a replacement's subscriptions.
- The list reuses one hover WebView; each pinned Markdown window owns a captured `PinnedPreview` and its transferred WebView from admission through close, including the turn before the host mounts. Each WebView has one owner lease and per-navigation render IDs; stale callbacks must not publish state. Export owns one task from document loading through capture and encoding, and keeps its concurrency slot until that task exits even when cancellation reports an error earlier. Bitmap allocation and tile drawing are joined background steps; pngquant returns only after its process exits. A bounded WebKit callback wait does not prove that the native operation stopped. [markdown-chatgpt-wacz-style-contract.md](./markdown-chatgpt-wacz-style-contract.md) owns renderer semantics, layout, local resources, navigation, readiness, and verification.
- Preview and export flows must treat stored content as source-of-truth input, not a side channel that mutates persisted data.

## Operational Invariants

- Views must not directly touch database or filesystem persistence; state and protocols remain the integration boundary.
- System sharing may materialize temporary files for explicit user actions, but file-reveal actions must remain constrained to real user files.
- Settings saves carry a field patch. The settings actor reads, merges, persists and returns the committed DTO without yielding; an open window keeps its draft when shown again. Closing the window ends that draft's view lifetime and input monitors.
- Recorded hotkeys apply immediately and persist independently of Save/Cancel through `AppDelegate.applyHotKey`; callers await registration and persistence directly. `HotKeyRecordingSession` suspends global registration for one recording, rejects an older session's completion, and restores the latest committed shortcut on cancellation. `.settingsChanged` uses the same application path while respecting that suspension. Carbon dispatch rechecks its registration ID before executing a queued press.
- The recent list pages by key, not offset. `fetchHistoryPage(limit:after:)` reads one SQLite snapshot: every pinned row on the first page (`after: nil`), then unpinned rows strictly after the `RecentHistoryCursor` (`last_used_at DESC, id ASC`, seeked on `idx_recent_order`), the total, the next cursor, and its mutation sequence. The list merges page rows and later committed changes by item and covered range while chunks mount. A newer tail page cannot advance the loaded prefix's version or discard its newer updates; the total has its own version. Pin changes carry the committed row even when it was outside the loaded page.
- A history gap triggers a snapshot for the loaded, retained, and pending-Undo identities plus a refresh of the current projection. `HistoryItemsSnapshot` carries the IDs actually requested: only missing IDs in that set establish deletion, so a preview retained after the request began is not invalidated by absence. Gap recovery must not overwrite a newer user query. Ordinary projection observations do not establish authoritative deletion.
- A stale hotkey reopen (`PanelReopenSearchResetPolicy.staleIntervalSeconds`, checked in `AppDelegate.togglePanelAtMousePosition`) calls `HistoryViewModel.resetForStalePanelReopen`. It clears the selection and query and runs the ordinary versioned first-page request (`search()`, which is `load()` when no filter is active), then scrolls to the first section header through the mounted `HistoryListView` handler. The status-item open has no stale check.
- Search and filter-only lists page by offset. A capture, content change or deletion while one is shown re-runs its request: within the first page, or while a search for a new query is pending, as a new search; past it, as one request at offset 0 that covers every loaded row and replaces them in place, so the change never collapses the rows the user paged through back to the first page. That refresh holds the paging slot: `loadMore` waits for it instead of reading an offset the change moved.
- Pending deletion freezes the row's `useCount`. `delete(itemID:expectedUseCount:)` checks that count in the deleting transaction and returns a `HistoryItemsSnapshot` of the decision. A copy committed in the meantime retains the row and restores it normally, even when its history notification was lost to a journal gap; metadata-only changes do not cancel Undo. Derived thumbnail paths are separate from transactional row fields: updates are checked by ID, type, and content hash, and an older nil path for the same payload cannot erase a completed thumbnail.
- Normal Quit drains pending and in-flight deletes before stopping the backend. A failed delete restores its row and cancels a user or updater Quit; logout, restart, and shutdown (a quit Apple event carrying `kAEQuitReason`) still stop the backend and terminate. The event consumer stays alive until backend producers finish stopping. The whole sequence is bounded (5 s in `AppDelegate`): storage is crash-consistent, so a hung shutdown answers Quit, logout, or an update relaunch anyway.
- Cleanup, external file reads/writes, thumbnail work, and other heavy operations should remain backgrounded and bounded.
- External storage access continues to require path validation before file operations.
- A durable ingest source is not moved or deleted before the database commit. Receipt replay is an internal no-op, including after the committed item has since been deleted, and acknowledgement reaches a non-replay terminal marker before receipt removal.
- An unreadable ingest envelope or payload stays at the FIFO head with cancellable backoff and visible blocked status. Confirmed malformed envelopes are quarantined without deleting their payload (under a unique name when an earlier copy already holds the plain quarantine name); read failures are never acknowledgements. Only Scopy writes the spool, so an artifact absent from a reachable spool directory is `missing`, not unreadable: its envelope is quarantined (or dropped if the envelope itself is gone) and later captures continue instead of waiting forever.
- Policy cleanup is DB-first: planned rows that became pinned or changed payload identity are skipped, and returned refs are rechecked for surviving owners under path reservations before unlink. Orphan sweeps skip paths with an active reservation, then check current database ownership once while holding the reservation; placement on another path does not invalidate the sweep. A reservation key resolves the file's directory, never the file: resolving a file removed mid-call yields another spelling of a symlinked root (`/private/var` for `/var`), which would give one file two keys.
- SQLite failures carry the extended result code; logs record the code and category publicly and the message privately.
- The storage protocol claims D1 process-crash/restart consistency only; WAL `synchronous=NORMAL` and unsynced rename/write paths are not a D2/D3 power-loss guarantee.
- Documentation/release automation reads [release-current.yml](../meta/release-current.yml) as the machine-readable source of truth.

## Stability Priorities

- Favor structured concurrency and bounded work queues over detached or unbounded background work.
- Keep correctness above opportunistic performance shortcuts: fallback paths should preserve complete results and safe deletion behavior.
- Verify independent behaviour through production boundaries. Remove superseded tests and test-only interfaces instead of building a parallel model of the implementation.

## Where To Put Future Design Work

- New capabilities that are not yet committed belong in [doc/proposals](../proposals/README.md).
- Historical deep dives and prior optimization reasoning belong in [doc/archive/specs](../archive/specs/README.md).
