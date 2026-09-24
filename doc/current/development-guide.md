---
doc_type: guide
status: active
owner: maintainers
last_reviewed: 2026-09-05
canonical: true
related_versions:
  - v0.70.0
  - v0.65.2
  - v0.65.0
---

# Development Guide

This document is the canonical implementation guide for the current Scopy codebase. It explains how the repo is structured, how the main runtime paths work, and how to safely change the project without drifting from release, performance, and documentation contracts.

## Reference State

- Version metadata: [../meta/release-current.yml](../meta/release-current.yml)
- Active requirements: [product-spec.md](./product-spec.md)
- Release workflow: [release-runbook.md](./release-runbook.md)

## Architecture Overview

Scopy is intentionally split into four layers:

| Layer | Responsibility | Main paths |
| --- | --- | --- |
| App / UI shell | App lifecycle, panel/window coordination, menu bar, view composition, settings shell | `Scopy/AppDelegate.swift`, `Scopy/Views`, `Scopy/Observables`, `Scopy/Presentation` |
| Backend library | Clipboard ingest, persistence, search, settings, protocols, domain models | `Scopy/Application`, `Scopy/Domain`, `Scopy/Infrastructure`, `Scopy/Services` |
| UI support library | Reusable non-app-shell UI support code | `ScopyUISupport` |
| Tooling | Benchmarks and release/doc scripts | `Tools/ScopyBench`, `scripts`, `Makefile` |

The app target imports backend/UI support through SwiftPM products rather than compiling every backend source directly into the UI shell.

## Repository Layout

| Path | Purpose |
| --- | --- |
| `project.yml` | XcodeGen project definition and build-script wiring |
| `Package.swift` | SwiftPM products: `ScopyKit`, `ScopyUISupport`, `ScopyBench` |
| `Scopy/Application` | App-facing backend facade, notably `ClipboardService` |
| `Scopy/Domain` | DTOs, protocols, and domain-level types |
| `Scopy/Infrastructure` | Search engine, persistence helpers, settings/configuration infrastructure |
| `Scopy/Services` | Storage, clipboard monitoring, and concrete service primitives |
| `Scopy/Runtime` | ScopyKit-only runtime configuration (`PerfFeatureFlags`); excluded from the app and test targets so it is compiled once |
| `Scopy/Observables` | State/view-model layer that adapts backend protocols to SwiftUI |
| `Scopy/Views` | Main panel, header, history items, settings pages, UI testing harnesses |
| `Scopy/Resources` | Markdown preview assets, bundled tools, third-party runtime resources |
| `ScopyTests` / `ScopyUITests` | Unit and UI test suites |
| `doc/current` | Active docs |
| `doc/releases` | Release index, changelog window, immutable release history |

## Runtime Flows

### 1. Application Startup

1. `AppDelegate.applicationDidFinishLaunching` boots the menu bar app, windows/panel, and root state wiring.
2. `AppState` selects the service implementation in its initializer (`ClipboardServiceFactory`; the mock only for `--uitesting`, or `USE_MOCK_SERVICE=1` in Debug). `AppState.start()` starts it, subscribes to `eventStream`, applies settings, and triggers the initial loads. `ClipboardService.start()` takes the storage-root writer lock before touching any shared directory; a second instance fails to start with a visible message.
3. `ClipboardService.start()` brings up `ClipboardMonitor`, `StorageService`, and `SearchEngineImpl`.

Implication: app shell code should stay orchestration-only; backend initialization belongs behind `ClipboardServiceProtocol`.

### 2. Clipboard Ingest

1. `ClipboardMonitor` observes pasteboard changes and normalizes clipboard payloads. Externally backed captures are first written as owned payload + pending envelope artifacts under the Application Support ingest spool; legacy cache envelopes are migrated or drained without overwriting a replayable destination.
2. `ClipboardService.handleNewContent(_:)` decides how to ingest, deduplicate, and schedule cleanup. The envelope UUID is the ingest idempotency key.
3. `StorageService` (an actor; its file-system work never runs on the main thread) retains durable spool sources, validates every path against the owned root, and places any managed candidate at a unique destination without consuming the source.
4. `SQLiteClipboardRepository` resolves the receipt, item insert/dedup mutation, and content-free `ingest_receipts` write in one `BEGIN IMMEDIATE` transaction. Outcomes are `inserted`, `updated`, or `alreadyApplied`; only the first two publish product events.
5. Acknowledgement moves the pending envelope to a non-replay terminal marker before receipt removal and bounded artifact cleanup. Failure before that transition leaves enough evidence for restart replay.

Implication: clipboard semantics, dedup, cleanup triggering, and safe file handling are backend responsibilities, not view responsibilities. This protocol guarantees D1 process-restart consistency, not power-loss durability.

### 3. History Loading And Search

1. `HistoryViewModel.load()` uses `fetchPinned()` plus `fetchRecentUnpinned(limit:offset:)` so pinned rows do not consume the initial recent-page quota.
2. `HistoryViewModel.loadMore()` uses `fetchRecentUnpinned(limit:offset:)` with the current unpinned count as offset; the initial recent page is 50 items and load-more pages are 100 (`HistoryViewModel.initialPageSize` / `loadMorePageSize`).
3. `HistoryViewModel.search()` builds a `SearchRequest` and calls `search(query:)`.
4. `SearchEngineImpl` executes mode-specific behavior for `exact`, `fuzzy`, `fuzzyPlus`, and `regex`.
5. Exact search execution (`SearchEngineImpl.searchExact`) and match-evidence generation (`SearchMatchContextBuilder`) must share `SearchQueryNormalization.normalizedExactQuery(_:)`, so trimming affects the recent-only cutoff, matching, and evidence identically. Query routing is the `switch request.mode` in the engine; there is no separate planner.
6. UI updates are event-driven; the list should not depend on ad hoc full reloads for ordinary mutations.
7. Search results expose `SearchCoverage` so UI can distinguish complete results, staged fuzzy refinement, and intentional recent-only limits.
8. Search result pages and engine results carry `SearchCoverage` directly. Match-evidence generation adds FTS phrase evidence only for `stagedRefine` coverage; recent-only and incomplete coverage keep the plain evidence path.

Implication: changes to search semantics belong in the request model, search engine, and user-visible docs together.

### 4. Preview And Export

1. `HistoryItemView` routes hover interactions into `HistoryHoverPreviewPipeline` request values for image, text, Markdown file, and file preview flows.
2. `HistoryHoverPreviewPipeline` owns preview planning, cache-hit/cache-miss event emission, suppression checks, and bounded detached preview work before the row applies UI state.
3. `HoverPreviewLoader` owns image/file preview decode and downsampling helpers so the row view does not carry raw ImageIO logic.
4. `MarkdownHTMLRenderer -> MarkdownHTMLDocumentBuilder` produces the shared standalone HTML used by preview and `Scopy/Services/Export/MarkdownExportService`. Read [the canonical renderer contract](./markdown-chatgpt-wacz-style-contract.md) for syntax, rich/public-copy adapters, typography, layout, navigation, asset integrity, and readiness requirements. This guide does not define a second copy of those rules.
5. pngquant integration uses the maintainer fork documented in `Scopy/Resources/ThirdParty/pngquant/PROVENANCE.md`; update binary and provenance together. `PngquantService` runs in file mode. Exports draw into the memory-mapped PAM `ExportBitmapCanvas` with its fixed header, and ImageIO encodes only when palette reduction is disabled or declines the quality floor. Validated rich-v2 documents retain true-color output. Use page-side layout readiness after scroll/resize/scale changes, not sleeps.
6. `MarkdownPreviewWebViewController` owns the reusable WebView; representables use owner leases and per-navigation render IDs. Hidden premeasurement must not share this controller. Preview scale is local UI state, not an implicit Settings save.

Search marker: `SCOPY_EXPORT_PDF_GLOBAL_SCALE_MISMATCH`

- Forced PDF export has an extra failure mode that preview and snapshot export do not have: pre-PDF global-scale budgeting uses the WKWebView viewport width, while PDF rasterization ultimately uses the real PDF page boxes.
- If the PDF page box is narrower than the viewport, the final raster height becomes larger than the earlier estimate. Long content can then fail only on the PDF path with symptoms such as clipped long exports or `PDF rasterization too large`.
- When touching Markdown export, keep the PDF preflight/re-scale guard next to this marker and keep `ExportMarkdownPNGUITests.testAutoExportGlobalScalePDFDoesNotLeaveBlankRight()` green.
- Global export scale must preserve the already-laid-out content width. Do not compensate by widening `#content` by `1 / scale`; that changes paragraph line breaks and table column measurement instead of scaling the preview-equivalent layout.

Implication: preview/export work must remain background-safe and should not mutate unrelated persisted content.

#### Hover Transfer Contract

- `HistoryItemPreviewCoordinator` owns preview kind/token state, active popover screen geometry, fixed popover-exit cleanup, and the hover-intent controller. `HistoryItemView` starts and cancels transfer lifecycle but does not own geometry math.
- `HoverPreviewIntentPolicy` is the pure geometry/time state machine. Keep it independent of AppKit, SwiftUI, wall-clock reads, and async scheduling so every placement direction and edge case stays deterministic.
- `HoverPreviewIntentController` owns one cancellable `@MainActor` task, samples `NSEvent.mouseLocation` at approximately `16.67ms` only during row-to-popover transfer, and stops no later than `500ms`. It must not become observable.
- `PopoverWindowObserver` is the narrow AppKit bridge. It reports `NSWindow.frame` in screen coordinates on attach, move, resize, and screen change; emits `nil` on close; deduplicates unchanged frames; and removes every notification observer during teardown.
- Safe-triangle geometry is rebuilt only when the target frame changes. The steady-state sample path must not allocate collections or recompute angular tangents.
- `HistoryListInteractionCoordinator` owns the active transfer item ID. Other rows may show visual hover, but must defer selection, dismissal, and preview work until the transfer ends; `HistoryListView` also guards cross-row dismissal/presentation to tolerate AppKit exit/enter ordering at screen edges.
- The coordinator must reject stale geometry and close callbacks by preview kind and token. Row re-entry, target arrival, replacement, scroll, system close, explicit dismissal, invalidation, and teardown must release transfer ownership and cancel both fixed-delay and intent tasks exactly once.
- Row-to-popover uses directional intent. Popover-to-row keeps the fixed `120ms` grace and does not reuse the triangle policy.

### 4.1 Storage Cleanup Execution

1. `StorageService` builds repository `DeletePlan` values whose `DeleteCandidate` snapshots include item ID, type, content hash, recency, size, and storage ref for cleanup-by-count, cleanup-by-age, cleanup-by-size, image-only cleanup, external-storage cleanup, and composite cleanup.
2. Planning is advisory. `SQLiteClipboardRepository.commitDeletePlan(_:)` starts `BEGIN IMMEDIATE`, reloads each candidate, revalidates the full cleanup snapshot plus unpinned state, deletes only matching rows, and captures exact storage refs from those rows in the same transaction.
3. `StorageService.applyDeletePlan` immediately reports the committed `CleanupResult` before bounded file cleanup. External refs are containment-validated, reserved by canonical path, and batch-checked for surviving owners before unlink; a file failure never rolls the database deletion back.
4. `ClipboardService` applies the exact committed deletion set to the search indexes (tombstones, not a rebuild), invalidates stale publications, and emits one `.itemsRemoved([UUID])` event from the exact committed IDs. The handoff survives cancellation of the debounce/caller task after commit. Every storage commit sends the search engine exactly one notification carrying that commit's `mutation_seq`; a gap in the sequence invalidates the in-memory indexes.
5. `HistoryViewModel` removes those IDs in linear time, preserves pagination state, and refreshes the authoritative total instead of full-reloading the list.

Implication: new cleanup variants must use the commit-time revalidating executor. A pre-transaction plan is never authority to delete a row or file.

### 4.2 Lossless Storage Byte Accounting

1. `SQLiteStatement.bindInt(_:at:)`, `columnInt(_:)`, and `columnIntOptional(_:)` represent Swift `Int`, not C `int`; on the supported 64-bit macOS baseline they must use `sqlite3_bind_int64` and `sqlite3_column_int64`.
2. Keep `Int32` only for SQLite parameter/column indexes and other APIs whose declared contract is 32-bit. Do not narrow payload sizes, file sizes, limits, offsets, booleans, or use counts through `Int32(value)`.
3. Keep explicit `bindInt64`/`columnInt64` for row IDs and SQL aggregates whose durable contract is intentionally `Int64`.
4. SQLite `INTEGER` already stores signed 64-bit values. An adapter correction does not require a migration or `PRAGMA user_version` bump when column semantics are unchanged.
5. File-size aggregation must use checked addition and return `nil` when no exact `Int` result exists. Do not wrap, saturate, or materialize file contents to measure a logical size.
6. Any byte-accounting change must cover ordinary values plus `Int32.max + 1`, a sparse 5 GiB file, disk reopen, CAS/batch update, cleanup stopping, nullable values, and overflow behavior.

Implication: storage, search hydration, cleanup planning, and presentation must observe the same exact positive byte count without changing the public DTO shape.

### 4.3 List Interaction Coordination

1. `HistoryListView` owns `HistoryListInteractionCoordinator` and passes it into rows / observers as list-scoped state.
2. `HistoryItemView` keeps its passive descriptor and content revision directly, but creates one optional `HistoryItemInteractionState` only for a real hover/action or owned asynchronous lifetime. Do not restore eager row controllers.
3. The coordinator owns one tokenized active slot and one suppressed-hover candidate. Row lifecycle holds ownership tokens, not broadcast observers or raw UUID registrations.
4. Scroll-end cooldown may restore a stationary pointer only when item, revision, token, pointer location, and visibility still match.
5. The AppKit adapter starts pointer suppression only when `NSScroller.testPart(_:)` identifies an actionable vertical or horizontal scroller part; mouse-up must match the originating token.
6. Stable context-menu predicates belong in `HistoryItemPresentationCache`, keyed by `ClipboardItemContentRevision`. Keep `markdownMenuSignalCache` separate from the exact Markdown export-capability cache: exact `true` or `false` always wins, while the heuristic caches both outcomes, prewarms off-main, deduplicates in-flight work, and rejects stale generation completion.
7. `HistoryRelativeTimeClock` and `HistoryItemPresentationCache` remain list/presentation concerns: pause ticking while scrolling or hidden, keep caches bounded, and invalidate by content revision.
8. Scroll and pointer suppression stay list-local; do not reintroduce process-global hover/scroll coordination state.
9. Rows are built inside ForEach child closures. Read `@Observable` state (settings, popover state, search-match contexts) once per list update in `HistoryListView.body` and pass values into `historyRow(item:context:)`; a read inside the closure installs an observation per row. Use `ClipboardItemContentRevision.resolve(item:)` on hot paths instead of `init(item:)`.
10. `ScrollCursorSetCoalescer` (installed at launch) drops `-[NSCursor set]` calls that re-set the already-current cursor within 100 ms because AppKit and SwiftUI re-set the arrow cursor on every scroll frame; keep it, and do not add per-frame cursor changes to the list.
11. Measure scrolling with `scripts/perf-scroll/` (real wheel input over the real panel on a Release build, `sample` attribution) before claiming a scroll improvement; the callback-interval harness cannot see hitches or attribute time. Measure both `--mode wheel` (mouse-like, no gesture phase) and `--mode wheel --phased` (trackpad-like), and use `--reuse-db` for steady-state numbers: a fresh DB copy regenerates thumbnails and re-runs the List body for every generated thumbnail.
12. "Scrolling" is one unified state in `ListLiveScrollObserverView`: live-scroll notifications (trackpad gestures) and the list clip view's `boundsDidChange` (mouse wheel, momentum tail) both start it, and it ends only when the gesture finished and the clip view has been still for `boundsSettleInterval`. Legacy mouse-wheel events post no live-scroll notifications, so the bounds signal is what keeps hover sessions and preview decodes from starting while rows pass under the pointer. Scrolls the app performs itself (keyboard selection follow) are masked through `ListProgrammaticScrollGate` so they do not retire the hovered row.
13. Per-interaction row state never flows through the List body. Selection, match evidence, and the currently presented popover fan out through `HistoryRowLiveStateFanout`; each ForEach child is a `HistoryLiveRow` that registers by item id while visible, keeps its live state as its own `@State`, and rebuilds only its `HistoryItemView`. The view model exposes the projection through three observation units (`itemsRevision`, `totalCount`, `canLoadMore`) written by `mutateProjection` only when they change. Keyboard follow (`scrollTo`) hangs off the fan-out callback, and `lastSelectionSource` is written before `selectedID`. A List body re-run re-initializes every ForEach child (not only visible rows) and diffs every loaded id, so `HistoryListView.body` must not read `selectedID`, and anything else that changes per interaction should reach rows the same way.
14. Keep `HistoryItemView.init` trivial: a page load initializes every new row at once, so the row descriptor is resolved lazily from `HistoryItemPresentationCache` in `body`, and display-text prewarm uses memoized revisions. Do not move descriptor, text-metric, or digest work back into `init`.
15. Hover previews start no work until the pointer has rested on a row for `HistoryHoverPreviewPipeline.prefetchDelayNanos` (300 ms, or the preview delay if shorter). For text and Markdown the pipeline then detects, resolves the render context and builds the HTML off the main actor, and emits `.prewarmMarkdownHTML` so `MarkdownPreviewWebViewController.prewarm` loads the document into the unowned shared WebView at the popover width; the page's `__scopyProbeLayoutHeight` (DOM-built height, not terminal readiness) seeds the metrics cache so the popover opens at its final size when the delay elapses and replays instead of navigating. The pipeline renders at `MarkdownPreviewLayoutScalePreference.active(settings:)`, the scale the popover shows, and the model records that scale in `markdownHTMLLayoutScale`; a preview-local scale switch is the only reason to re-render. `HistoryHoverPreviewPipeline.logHoverStage` writes the stage timeline (info level).
16. Search keeps the current rows on screen until the versioned replacement arrives; a refine pass that reproduces the prefilter page changes no observation unit. The List stays mounted while results are empty: the empty and loading states are a leaf overlay, an empty staged page is held back until the refine returns, and a failed search, load, or page load keeps the rows on screen and reports the failure in the footer with a retry. `isLoading` and the workload `onChange` observers are read by leaf views (`LoadMoreTriggerView`, `HistoryListStateObservers`) rather than in `HistoryListView.body`. Anything read in that body re-initializes every ForEach child and diffs every loaded id when it changes.
17. `HistoryListState` updates its derived arrays incrementally for front inserts, in-place item replacement, and page appends; a full `rebuildDerivedState` is for bulk replace and removal only. `HistoryViewModel.rowDidAppear` starts the next page `loadMorePrefetchRows` (40) rows before the end, and `loadMore` applies the page in `loadMoreApplyChunkRows` (20) row chunks one display frame apart so no single List update spans several frames.
18. Clipboard capture reads pasteboard representations on the main thread and processes text off it (`ClipboardMonitor.makeTextRawData`): RTF import, normalization and the Markdown/TeX heuristics run detached; the WebKit HTML importer is main-thread-only and is invoked only when it can change the stored text (`preferredPlainText` rules: empty string, authored Markdown, or TeX characters possible per `mayContainTeXCharacters`). A 1 MB rich copy blocked the main thread for about two seconds before this; the stored text and hash are unchanged by the gating.
19. Search index disk caches use `SearchIndexBinaryCodec` (`*.shortindex.v3.bin`, `*.fullindex.v5.bin`): the header carries the mutation sequence so a stale cache is rejected before checksum and decode, and decoding a 15 MB short index takes about 55 ms instead of 2.9 s. Do not reintroduce property-list encoding for postings or item tables.
20. `HoverPreviewImageCache` accepts entries up to 256 MB (the 64 Mpx decode budget at 4 bytes per pixel) under a 320 MB total; rejecting large previews meant decoding a tall screenshot again on every hover. The decode budget itself is unchanged so very tall images keep their sharpness.
21. Two things measured as no gain and must not be retried without new evidence: replacing per-row `.onHover` with one list-level tracking area plus a per-row marker platform view (the `PointerRegionUpdater` cost comes from `NSHostingView` cell reinsertion, not from `.onHover`, and the marker costs as much as it saves), and merging the row's background/overlay/animation modifiers into one node (the floor-experiment gain came from hover churn that the unified scroll state already removes).

22. `PinnedPreviewController` owns per-item snapshots and panels. Snapshot the model before dismissing the popover; transfer its WebView only for Markdown, then replace the list's hover controller. Each WebView retains a single owner lease and current render ID; `HistoryItemView` equality includes controller identity so old rows cannot reclaim a pinned WebView. Individual close/reconciliation does not affect other windows. `PreviewControls` overlays compact window actions and Markdown controls without reserving layout space, while `ResizablePreview` owns a popover's explicit size and clears resize liveness on disappearance and token invalidation. Pin success uses `HistoryViewModel.closePanelHandler` to hide the history panel.
23. `FloatingPanel` closes on `resignKey` except when the click that stole key focus landed in the pinned preview window (`FloatingPanelDismissPolicy`). The decision reads `NSApp.currentEvent` synchronously: AppKit installs the new key window only after `resignKey` returns, and deferring a run loop turn would reorder the close against the status-item toggle, which reads `isPresented`.

Implication: SwiftUI row rendering should remain decoupled from global singleton churn during fast scroll and preview suppression.

### 5. Settings And Hotkey Flow

1. `SettingsView` maintains a transactional draft copy of `SettingsDTO`.
2. Saving applies a `SettingsPatch` merge rather than overwriting with stale snapshots.
3. Hotkey recording is special-cased to apply immediately and persist independently.
4. `.settingsChanged` events flow back through `AppState` so runtime state stays in sync.

Implication: if you touch settings behavior, preserve the Save/Cancel model and the immediate hotkey-apply semantics.

## Product Behavior

[product-spec.md](./product-spec.md) owns the current feature surface, search modes, paging limits, item actions, and settings behavior. Use the runtime entrypoints above to implement those requirements; do not maintain a second feature matrix here.

## Build, Test, And Validation Workflow

### Lightweight Development Workflow

[AGENTS.md](../../AGENTS.md) owns shared autonomy, delegation, and validation rules. Use the current task for its outcome, constraints, and acceptance evidence; routine work needs no separate PRD, journal, or plan file.

- For a long task, keep a compact checkpoint in the same conversation: current scope, checkout/commit, completed changes, evidence paths, and the next unresolved step. Re-read live Git and relevant artifacts after resuming. Save a proposal only when others need durable design review; archived task files are context, not active requirements.
- Treat mid-task user corrections as updates to the current objective. Before dependent edits or publication, reconcile the changed scope with work already performed and tools still running; a new instruction does not undo completed actions.
- Reuse completed validation only when the relevant source, dependencies/assets, build flags, and environment match, and identify that evidence. A documentation follow-up does not invalidate unchanged runtime evidence; a renderer dependency change does. Keep blocked, failed, skipped, and unattempted gates distinct.
- Keep stable project rules in `AGENTS.md`, product contracts in their canonical documents, and repeatable procedures in narrowly scoped skills. A new model is a reason to inspect conflicting rules, not to copy its API manual, fix a model/effort setting for every task, or add a new agent framework.
- Improve instructions from an observed failure. Review a small set of representative requests for the intended outcome, accidental scope expansion, unnecessary questions, and redundant checks. A skill's frontmatter validator proves structure only; do not claim agent behavior improved without observing subsequent runs.

These choices apply the [Astra instruction-following and verification guidance](https://developers.openai.com/api/docs/guides/latest-model#prompting-best-practices) and [Codex best practices](https://learn.chatgpt.com/guides/best-practices), checked on 2026-09-05. They are project workflow choices; model pricing, API features, and product availability remain in current official documentation.

### Baseline Build/Test

- `make build` / `make release` compile Debug / Release without replacing the installed app.
- `./deploy.sh release --no-launch` builds and installs into `/Applications`; use it when installation is intended. The flag skips launch only. Xcode products stay in isolated DerivedData while SwiftPM continues to own `.build`
- `make test-unit`
- `make test-tooling` checks project regeneration and per-worktree test build isolation without Xcode or GUI access; CI runs the same entrypoint.
- Explicit test DerivedData paths are scoped by a hash of the checkout path, then by flag variant. Parallel worktrees do not share the strict/performance/sanitizer build database. Plain builds and unit tests retain Xcode's default project-path isolation.
- The XcodeGen cache tracks project/package configuration, source and resource paths, and generator version. Source-content edits remain incremental; adding/removing a resource regenerates the project just like adding/removing Swift source.
- `make test-strict` for concurrency-sensitive work; the strict build treats every Swift warning as an error, so the branch must be warning-free
- `make test-tsan` when the environment supports the hosted test path; the command auto-skips the known-bad `macOS 26.x + Xcode 26.2 (17C52)` hosted runtime combination
- Hosted TSan CI lives in `.github/workflows/tsan.yml` on `macos-15 + Xcode 16.0`; treat that workflow as the supported real-coverage path until the local Apple runtime issue is resolved
- Preserve final bundled-resource validation in packaging. The package has no resources and the former SwiftPM resource-staging phase was removed; do not restore that phase from historical instructions.

### Performance Validation

- `make test-snapshot-perf-release` is the backend search gate on a `make snapshot-perf-db` copy; record the copy's SHA-256 so both sides of a comparison use the same data.
- `make perf-search-warm-load` reports full-index warm-load latency and peak RSS.
- `make perf-scroll-wheel`, `make perf-search-type`, and `make perf-capture` drive the Release app with real input (`scripts/perf-scroll/`); they need `perf-db`, Accessibility trust for the terminal, and a quiet desktop. They fail closed: a run whose workload did not reach the app exits non-zero.
- `make perf-frontend-profile[-smoke|-standard|-full]` is an XCUITest callback-cadence profile; it cannot see hitches, and on hosts where XCUITest is blocked it is environment-blocked, not evidence.
- XCTest performance inputs and in-progress outputs must use the test bundle, DerivedData, or `/tmp`, not runtime `#filePath` or direct repository paths under `~/Documents`. Copy only completed evidence back to `logs/` after the test succeeds.
- Display-link callback intervals describe callback cadence, not presented frames. Never relabel them FPS without compositor-backed evidence.

#### Performance Evidence Protocol

1. Declare the metric, workload (script and arguments), threshold, and expected direction before measuring.
2. Build A and B as Release from clean commits (worktrees); record both `git rev-parse HEAD` values and the app binary SHA-256s.
3. Use one snapshot copy (SHA-256 recorded) and a warm copy per side; discard one warm-up run per side.
4. Quiet desktop, no other Scopy instance, mains power, pointer parked outside the list; record chip, memory, macOS and Xcode builds.
5. Measure the A/A noise floor first (three interleaved pairs of the same build), then run ABBA (at least three pairs; five when the expected effect is under 5%).
6. Keep the app profiler on for ratios (its counters prove the workload happened); for absolute CPU claims add a run with the profiler off and state its overhead.
7. Every run must prove the workload happened: `active count > 0` for scrolling, the Accessibility readback for typing, a window observation for hover, `UI check: OK` for capture. Discard and report invalid runs.
8. Record per-run raw values, per-side mean and sd, the delta, and whether the ranges overlap. Report max-type metrics as the median of per-run maxima.
9. Conclude only when every B run beats every A run, or |Δmean| exceeds both twice the pooled sd and the A/A resolution. Name the single variable that caused the change; state what was not measured; never extrapolate to "the whole app is N× faster".
10. Conclusions go to `doc/perf/studies/` or the release note; raw data stays in `logs/`; never attach `.trace` files (they embed the recording environment).

#### Local UI Verification Path

XCUITest is blocked by system authentication on the maintainer's machine and hangs `testmanagerd` when attempted; UI changes are verified by driving the real app instead:

1. `make release` (or `make build`) and `make perf-scroll-tools`. Never `./deploy.sh` for verification (it replaces the installed app).
2. Prepare a temporary directory with a warm `perf-db` copy or an empty database seeded through a private pasteboard (`scripts/perf-scroll/build/pbwrite`).
3. Park the pointer (`build/warp 1400 40`), then launch the binary directly with `USE_MOCK_SERVICE=0 SCOPY_SERVICE_DB_PATH=… SCOPY_SERVICE_MONITOR_PASTEBOARD=<private> SCOPY_PROFILE_OPEN_PANEL=1` (add `SCOPY_SCROLL_PROFILE=1 SCOPY_PROFILE_ACCESSIBILITY=1` when row identifiers are needed; that mode is for functional checks only).
4. Wait for the panel with `build/winpos <pid>`; click into the panel before sending keys; drive with `build/click`, `build/typekeys`, `build/wheel`, `build/warp`, or the global hotkey through `build/panelwatch --hotkey 8`.
5. Observe with `build/axsearch` / `build/axrows` (values and geometry), `CGWindowListCopyWindowInfo` (window level and bounds), the private pasteboard change count (`build/enterlatency`), `log stream --predicate 'subsystem == "com.scopy.app"'`, `build/hoverstall` (main-thread stalls), and the profile JSON counters.
6. Write the expected values down, assert them, terminate with SIGTERM, delete the temporary directory, and record the command, app SHA-256, and output in the commit or release note.
7. PNG export is checked without a screenshot: launch with `--uitesting SCOPY_UITEST_AUTO_EXPORT_MARKDOWN=1 SCOPY_UITEST_AUTO_EXPORT_MARKDOWN_PATH=<fixture> SCOPY_EXPORT_DUMP_PATH=<file>` and compare the dump byte-for-byte or pixel-wise with the previous build.

### Documentation And Release Validation

- `make docs-validate`
- `make release-validate`
- `make test-release-policy`
- `make tag-release` only after the applicable build, unit, strict-concurrency, scope-specific, documentation, and release gates have passed and the release candidate is committed

## Common Change Playbooks

The paths below identify flows to trace and contracts to verify. Edit only affected owners; listing adjacent modules does not require changes to every module or test file. Apply performance gates when the changed path or claim makes them relevant.

### Search Behavior

- Trace search requests through `SearchRequest`, `SearchMode`, and the search engine; update their owners when request or mode semantics change.
- Keep exact-search query normalization shared between `SearchPlanner.planExact` and `SearchEngineImpl.searchExact`.
- Re-check `SearchCoverage`, refine behavior, and any recent-only hint paths together.
- Re-check header controls, search hints, pagination, and requirements docs.
- Run search-focused performance validation when query execution, paging, or index work changes.

### Clipboard Or Storage Semantics

- Trace capture through `ClipboardMonitor`, `ClipboardService`, and `StorageService` as one flow.
- Re-check copy/replay semantics, external storage validation, cleanup behavior, and any item-model field assumptions.
- Preserve the durable-spool contract: retain source through commit, make receipt + mutation atomic, transition the envelope to terminal before receipt removal, and treat receipt replay as a no-op even when the item was later deleted.
- Route new cleanup variants through `StorageService.applyDeletePlan`; extend `DeleteCandidate` when a new policy predicate affects eligibility so commit-time revalidation remains complete.
- Test post-plan pin and payload replacement, shared storage refs, caller cancellation after commit, bulk queue delivery, and history pagination/total convergence.
- Preserve the lossless Swift-`Int` SQLite adapter. For byte-count changes, test values above `Int32.max`, disk reopen, cleanup stopping, and checked filesystem aggregation.
- For release-grade storage changes run `make build`, `make test-unit`, `make test-strict`, `make test-tsan`, `make test-snapshot-perf-release`, the applicable heavy cleanup tests, and frontend/unified profiling when event or projection code changes.

### Settings Or Hotkey Changes

- Trace the affected setting through `SettingsDTO`, settings pages, `SettingsView`, and runtime application; include the hotkey path when it changes.
- Preserve Save/Cancel and `settingsChanged` behavior.
- Verify `/tmp/scopy_hotkey.log` behavior when the hotkey path changes.

### Preview Or Export Changes

- Trace the affected behavior through preview UI, the shared rendering pipeline, and `MarkdownExportService`.
- Keep hover preview planning in `HistoryHoverPreviewPipeline`; row views should apply typed events rather than own decode/cache/metric policy.
- For hover-preview work, run a focused test plus `scripts/perf-frontend-profile.sh --include-hover` so Markdown and image hover buckets are present.
- For hover-transfer changes, cover pure geometry/session behavior, controller cancellation and generation replacement, list-level transfer ownership, stale popover-token geometry, and XCUI trajectories both through and outside the real corridor.
- Run strict-concurrency coverage because the controller lifecycle is task-based. Treat the include-hover frontend profile as a broad rendering regression smoke; do not claim it measures safe-triangle travel unless its automation explicitly crosses row-to-popover geometry.
- For Markdown renderer fixes, add a minimal reproduction at the failing boundary and run the renderer gates in `AGENTS.md`. Existing Node tests under `Tools/MarkdownRenderer/test/` and Swift `ChatGPTMarkdownRendererTests` cover different boundaries; update assertions and shared fixtures when their contract changes. Add isolated export UI coverage when the PNG output contract changes.
- Re-check pngquant settings interactions, preview latency, and output pasteboard behavior.

### File Action Or Context Menu Changes

- Keep file-system action resolution behind `ClipboardServiceProtocol.fileURLs(itemID:)`; views should not read persistence or storage paths directly.
- Treat AirDrop and Open Containing Folder as different contracts: AirDrop may use temporary PNGs for image rows, while Open Containing Folder must only reveal real source files.
- Update unit coverage for service URL resolution and UI coverage for menu visibility/action identifiers in the same change.

### Release Or Documentation Changes

- For an ordinary documentation change, update affected canonical docs and run `make docs-validate`. Update release metadata, notes, indexes, and changelog only for an authorized release or a changed release fact.
- Keep ordinary workflows top-level read-only. A release/documentation push validates only; only the explicit maintainer `make tag-release` / `make push-release` path may create a tag.
- Run `make test-release-policy` whenever `.github/workflows/`, release scripts, or release Make targets change.
- For release/versioning fixes, test both `scripts/version.sh --tag` and the release packaging path so the app bundle version, DMG name, and release metadata resolve from the same tag.
- Avoid putting new truth into compatibility directories or legacy archives.

## Important Invariants

- `project.yml` is the baseline source for Swift/Xcode/deployment targets.
- Normative docs live under `doc/current` and `doc/meta`; `doc/releases` is the release record. `doc/perf`, `doc/reviews`, and `doc/proposals` hold evidence and drafts and never override `doc/current`.
- The legacy `doc/implementation`, `doc/profiles`, and `doc/specs` directories and root aliases were removed; do not recreate redirects, symlinks, or compatibility stubs.
- Heavy work should stay off the main thread; correctness beats opportunistic speedups.
- Views should not directly become persistence clients.
- Every ScopyKit source compiles only into ScopyKit. `Package.swift` (ScopyKit excludes) and `project.yml` (app and test-bundle excludes) partition the top-level entries of `Scopy/`; a file compiled into both `ScopyKit` and the app target produces two copies of its static state. App-side sources are also compiled directly into `ScopyTests` and `ScopyTSanTests` by design (no test host).
- Release publication consumes a deliberate existing tag; ordinary CI must never create or push one.
- Select roadmap work by evidenced severity, affected surface, recurrence/likelihood, and confidence relative to implementation/rollback cost. Prefer crashes, data-integrity failures, unsafe release paths, and measured systemic bottlenecks over cosmetic cleanup or speculative micro-optimization.

## Code Conventions

- **Module ownership.** Backend code (`Application`, `Domain`, `Infrastructure`, `Services`, `Utilities`, `Extensions`, `Runtime`) belongs to ScopyKit; app code (`Design`, `Observables`, `Presentation`, `Views`, top-level files) belongs to the Scopy target.
- **Access control.** In ScopyKit, mark `public` only what the app or ScopyBench uses; tests use `@testable import`. The app target never needs `public`.
- **One primary type per file**, named after the file. Split a large file along ownership seams into separate types with explicit inputs and outputs (a store, a pure policy, a SQL gateway, a state machine) when a change touches it; do not split by line count alone, and do not widen `private` state just to spread one type over extensions.
- **No foreign-language source in Swift strings** beyond short parameters: CSS, JS, and HTML live under `Scopy/Resources` and the renderer package where they are tested and covered by the asset manifest.
- **Naming roles.** `…Policy` is a pure decision type (no side effects, clock, or async). `…Snapshot` is an immutable copy. `…Outcome` is an enum of alternative results; `…Result` is a struct of counts. `…Token` is compared by identity to reject stale callbacks. `generation` is a staleness counter; `revision` is content identity.
- **Test seams.** A production symbol that exists only for tests is named `…ForTesting`, compiled only under `#if DEBUG`, and has no production caller; prefer a test-target extension when no private state is needed.
- **Hooks.** Launch arguments and environment variables are read once into `static let` values, never per row or per frame. A hook that no script, test, or document sets is deleted.
- **Comments** are English and explain why (invariants, measured causes, rejected alternatives), not version history or archived documents.
- **Experiments** and A/B switches stay on branches; merged code has one implementation per behaviour.

## Glossary

- **capture / ingest**: capture reads and normalizes one pasteboard change; ingest is the idempotent path that writes it to storage.
- **spool / envelope / terminal marker / receipt**: the Application Support staging directory; one replayable description of an externally backed capture; the acknowledged state that is never replayed; the `ingest_receipts` row proving the envelope was committed.
- **publish**: emit committed state as an event to the UI and search (`ClipboardEventQueue.PublicationToken`). Placing a file at its managed path is *placement*, not publication.
- **projection / publish (UI)**: the rows, evidence, coverage, and selection the view model exposes to the list; a publication is one atomic change to it.
- **content revision** (`ClipboardItemContentRevision`): the identity of an item's content, used to invalidate stale preview, note, and export work. It is not a list change counter.
- **render ID**: the identity of one preview WebView load; stale callbacks are dropped by comparing it.
- **lease**: a revocable exclusive right (mutation gate, external image source, pasteboard write, WebView ownership).
- **coverage**: how complete a result set is relative to full history (`complete`, `stagedRefine`, `incomplete`, `recentOnly`).
- **match evidence** (`SearchMatchContext`): the matched excerpt, source, and count shown on a result row.
- **summary row**: a row projection without the payload blob; distinct from aggregate summaries such as `CleanupResult`.
- **plan / commit (cleanup)**: an advisory candidate snapshot taken outside the transaction, and the revalidated deletion inside it.
- **tombstone**: the placeholder slot of a deleted item in an in-memory search index.
- **pinned item** vs **pinned preview**: an item kept at the top of the list, and a preview detached into its own window; the code keeps both names.

## Logging And Privacy

- Log only through the `ScopyLog` categories (`app`, `monitor`, `storage`, `persistence`, `search`, `ui`, `hotkey`, `export`); do not create ad hoc `Logger` instances or call `print` / `NSLog` in production paths. SQLite failures log the extended result code and category publicly and the message privately.
- Treat clipboard text, query strings, file paths, bundle identifiers, note contents, raw payloads, and unfiltered error descriptions as private by default. Never log clipboard bodies, image bytes, note contents, or file contents.
- Counts, durations, thresholds, and feature-state values may be public only when they cannot reveal user content.
- Avoid per-item logging in clipboard polling, list rendering, search candidates, or other hot loops unless it is sampled or guarded by an explicit diagnostic/profile flag.

## Related Docs

- Active requirements: [product-spec.md](./product-spec.md)
- High-leverage task selection: [high-leverage-change-guide.md](./high-leverage-change-guide.md)
- Release workflow: [release-runbook.md](./release-runbook.md)
- Short maintainer navigation: [maintainer-guide.md](./maintainer-guide.md)
- Current release window: [../releases/README.md](../releases/README.md)
