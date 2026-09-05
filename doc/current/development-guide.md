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
2. `AppState.start()` chooses the service implementation, starts it, subscribes to event streams, and triggers initial loads.
3. `ClipboardService.start()` brings up `ClipboardMonitor`, `StorageService`, and `SearchEngineImpl`.

Implication: app shell code should stay orchestration-only; backend initialization belongs behind `ClipboardServiceProtocol`.

### 2. Clipboard Ingest

1. `ClipboardMonitor` observes pasteboard changes and normalizes clipboard payloads. Externally backed captures are first written as owned payload + pending envelope artifacts under the Application Support ingest spool; legacy cache envelopes are migrated or drained without overwriting a replayable destination.
2. `ClipboardService.handleNewContent(_:)` decides how to ingest, deduplicate, and schedule cleanup. The envelope UUID is the ingest idempotency key.
3. `StorageService` retains durable spool sources, validates every path against the owned root, and publishes any managed candidate to a unique destination without consuming the source.
4. `SQLiteClipboardRepository` resolves the receipt, item insert/dedup mutation, and content-free `ingest_receipts` write in one `BEGIN IMMEDIATE` transaction. Outcomes are `inserted`, `updated`, or `alreadyApplied`; only the first two publish product events.
5. Acknowledgement moves the pending envelope to a non-replay terminal marker before receipt removal and bounded artifact cleanup. Failure before that transition leaves enough evidence for restart replay.

Implication: clipboard semantics, dedup, cleanup triggering, and safe file handling are backend responsibilities, not view responsibilities. This protocol guarantees D1 process-restart consistency, not power-loss durability.

### 3. History Loading And Search

1. `HistoryViewModel.load()` uses `fetchPinned()` plus `fetchRecentUnpinned(limit:offset:)` so pinned rows do not consume the initial recent-page quota.
2. `HistoryViewModel.loadMore()` uses `fetchRecentUnpinned(limit:offset:)` with the current unpinned count as offset; the initial recent page is 50 and load-more pages are 500.
3. `HistoryViewModel.search()` builds a `SearchRequest` and calls `search(query:)`.
4. `SearchEngineImpl` executes mode-specific behavior for `exact`, `fuzzy`, `fuzzyPlus`, and `regex`.
5. Exact search planning and execution must share `SearchPlanner.normalizedExactQuery(_:)` so whitespace trimming affects both coverage decisions and matching consistently.
6. UI updates are event-driven; the list should not depend on ad hoc full reloads for ordinary mutations.
7. Search results expose `SearchCoverage` so UI can distinguish complete results, staged fuzzy refinement, and intentional recent-only limits.
8. Search result pages and engine results carry `SearchCoverage` directly. Its `isPrefilter` predicate describes staged coverage for match-context generation; there is no legacy result initializer.

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
4. `ClipboardService` invalidates stale publications/search state and emits one `.itemsRemoved([UUID])` event from the exact committed IDs. The handoff survives cancellation of the debounce/caller task after commit.
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

### 4.5 List Interaction Coordination

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
13. Selection never flows through the List body. `HistoryViewModel.selectedID.didSet` fans out to `HistoryRowSelectionFanout`; each ForEach child is a `HistorySelectionAwareRow` that registers by item id while visible, keeps the row's selection as its own state, and rebuilds only its `HistoryItemView` (whose `isKeyboardSelected` input and `Equatable` are unchanged). Keyboard follow (`scrollTo`) hangs off the fan-out callback, and `lastSelectionSource` is written before `selectedID`. A List body re-run re-initializes every ForEach child (not only visible rows) and diffs every loaded id, so `HistoryListView.body` must not read `selectedID`, and anything else that changes per interaction should reach rows the same way.
14. Keep `HistoryItemView.init` trivial: a page load initializes every new row at once, so the row descriptor is resolved lazily from `HistoryItemPresentationCache` in `body`, and display-text prewarm uses memoized revisions. Do not move descriptor, text-metric, or digest work back into `init`.
15. Hover previews start no work until the pointer has rested on a row for `HistoryHoverPreviewPipeline.prefetchDelayNanos` (300 ms, or the preview delay if shorter). For text and Markdown the pipeline then detects, resolves the render context and builds the HTML off the main actor, and emits `.prewarmMarkdownHTML` so `MarkdownPreviewWebViewController.prewarm` loads the document into the unowned shared WebView at the popover width; the page's `__scopyProbeLayoutHeight` (DOM-built height, not terminal readiness) seeds the metrics cache so the popover opens at its final size when the delay elapses and replays instead of navigating. The pipeline renders at `MarkdownPreviewLayoutScalePreference.active(settings:)`, the scale the popover shows, and the model records that scale in `markdownHTMLLayoutScale`; a preview-local scale switch is the only reason to re-render. `HistoryHoverPreviewPipeline.logHoverStage` writes the stage timeline (info level).
16. Search keeps the current rows on screen until the versioned replacement arrives, `replaceSearchPage` is a no-op when the refine pass reproduces the prefilter page, and `isLoading` / `performanceSummary` / the workload `onChange` observers are read by leaf views (`LoadMoreTriggerView`, `RecentSectionHeader`, `HistoryListStateObservers`) rather than in `HistoryListView.body`. Anything read in that body re-initializes every ForEach child and diffs every loaded id when it changes.
17. `HistoryListState` updates its derived arrays incrementally for front inserts, in-place item replacement, and page appends; a full `rebuildDerivedState` is for bulk replace and removal only. `HistoryViewModel.rowDidAppear` starts the next page `loadMorePrefetchRows` (40) rows before the end, and `loadMore` applies the page in `loadMoreApplyChunkRows` (20) row chunks one display frame apart so no single List update spans several frames.
18. Clipboard capture reads pasteboard representations on the main thread and processes text off it (`ClipboardMonitor.makeTextRawData`): RTF import, normalization and the Markdown/TeX heuristics run detached; the WebKit HTML importer is main-thread-only and is invoked only when it can change the stored text (`preferredPlainText` rules: empty string, authored Markdown, or TeX characters possible per `mayContainTeXCharacters`). A 1 MB rich copy blocked the main thread for about two seconds before this; the stored text and hash are unchanged by the gating.
19. Search index disk caches use `SearchIndexBinaryCodec` (`*.shortindex.v3.bin`, `*.fullindex.v5.bin`): the header carries the mutation sequence so a stale cache is rejected before checksum and decode, and decoding a 15 MB short index takes about 55 ms instead of 2.9 s. Do not reintroduce property-list encoding for postings or item tables.
20. `HoverPreviewImageCache` accepts entries up to 256 MB (the 64 Mpx decode budget at 4 bytes per pixel) under a 320 MB total; rejecting large previews meant decoding a tall screenshot again on every hover. The decode budget itself is unchanged so very tall images keep their sharpness.
21. Two things measured as no gain and must not be retried without new evidence: replacing per-row `.onHover` with one list-level tracking area plus a per-row marker platform view (the `PointerRegionUpdater` cost comes from `NSHostingView` cell reinsertion, not from `.onHover`, and the marker costs as much as it saves), and merging the row's background/overlay/animation modifiers into one node (the floor-experiment gain came from hover churn that the unified scroll state already removes).

22. A pinned preview is list-layer state, not row state. `PinnedPreviewController` copies the row's already-rendered `HoverPreviewModel` into its own model and hosts it in a `PinnedPreviewPanel`, so nothing on the pinned path depends on the row's interaction session, which is released whenever it goes idle. Rows learn about it through one `isPreviewPinningActive` flag in `HistoryRowContext` and stop starting hover previews; the list also refuses to present popovers, because the pinned window owns the single shared Markdown WebView. The window closes only on an explicit action or through `reconcile(snapshot:)`, which applies the same `HistoryContentRevisionReconciliationSnapshot.invalidates(...)` rule that retains row sessions use. Hand the WebView over by dismissing the popover first and presenting the window on the next run loop turn, the same ordering the popover-to-popover transition uses; the ownership lease plus `loadHTMLIfNeeded` then reuse the current navigation instead of re-rendering.
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

- Trellis tasks, PRDs, JSONL context, developer journals, and Trellis-specific agents or skills are not required.
- For a small, well-bounded change, inspect the relevant code and canonical docs, implement it directly, run scope-appropriate validation, and report the result.
- For a complex, cross-module, or high-risk change, write a short working plan. Add a document under `doc/proposals/` only when the design needs durable review, staged implementation, or future reuse.
- Use sub-agents only when work can be split into genuinely independent investigations or reviews. They are optional, and the primary agent remains responsible for integration and validation.
- Existing task artifacts may be consulted as historical input, but they do not define active workflow state or completion. Current contracts live in `project.yml`, source, tests, and canonical `doc/current/` documents.
- Match validation to risk: documentation-only changes need relevant documentation checks; functional code normally needs build and unit coverage; concurrency, performance, release, UI, and hotkey changes add their scope-specific gates below.

### Baseline Build/Test

- `make build`
- `./deploy.sh release --no-launch` for a repeatable local Release build and `/Applications` install; Xcode products stay in isolated DerivedData while SwiftPM continues to own `.build`
- `make test-unit`
- `make test-tooling` checks project regeneration, per-worktree test build isolation, and the source/performance/quality evidence gates without Xcode or GUI access; CI runs the same entrypoint.
- Explicit test DerivedData paths are scoped by a hash of the checkout path, then by flag variant. Parallel worktrees do not share the strict/performance/sanitizer build database. Plain builds and unit tests retain Xcode's default project-path isolation.
- The XcodeGen cache tracks project/package configuration, source and resource paths, and generator version. Source-content edits remain incremental; adding/removing a resource regenerates the project just like adding/removing Swift source.
- `make test-strict` for concurrency-sensitive work
- `make test-tsan` when the environment supports the hosted test path; the command auto-skips the known-bad `macOS 26.x + Xcode 26.2 (17C52)` hosted runtime combination
- Hosted TSan CI lives in `.github/workflows/tsan.yml` on `macos-15 + Xcode 16.0`; treat that workflow as the supported real-coverage path until the local Apple runtime issue is resolved
- Resource staging scripts in `project.yml` intentionally stay correctness-first for SwiftPM bundles and app resources. Optimize their internal work with idempotent/differential copy behavior; do not skip dynamic staging by enabling dependency analysis unless the input/output contract is fully explicit.

### Performance Validation

- `make test-snapshot-perf-release` for release-path backend perf gates
- `make perf-search-warm-load` for backend full-index warm-load latency and peak RSS
- `scripts/perf-warm-scroll-ab.sh` for causal fixed-workload comparisons. The default `passive-row` axis changes only `SCOPY_PERF_PASSIVE_ROW`; `--axis markdown-menu-cache` keeps both variants passive and changes only `SCOPY_PERF_MARKDOWN_MENU_SIGNAL_CACHE`. Require at least two repeats, exact AB/BA order validation, equal observed work, Release configuration, axis-specific counters, and all-pair improvement gates.
- `make perf-frontend-profile` for daily frontend smoke
- `make perf-frontend-profile-standard` before stronger local confidence
- `make perf-frontend-profile-full` before release-grade validation
- `scripts/perf-frontend-profile.sh --include-hover` when preview work needs direct hover-preview bucket evidence
- `make perf-unified-table` when correlating frontend and backend evidence, including `warm-load-summary.json` when present
- When a profile adds new evidence beyond the release note, add a versioned doc under `doc/perf/release-profiles/` and point `profile_doc` at it
- XCTest performance inputs and in-progress outputs must use the test bundle, DerivedData, or `/tmp`, not runtime `#filePath` or direct repository paths under `~/Documents`. Copy only completed evidence back to `logs/` after the test succeeds.
- Display-link callback intervals describe callback cadence, not presented frames. Never relabel them FPS without compositor-backed evidence.

### Documentation And Release Validation

- `make docs-validate`
- `make release-validate`
- `make test-release-policy`
- `make tag-release` only after the applicable build, unit, strict-concurrency, scope-specific, documentation, and release gates have passed and the release candidate is committed
- `make quality-manifest-self-test` when changing quality evidence tooling

## Common Change Playbooks

### Search Behavior

- Touch `SearchRequest`, `SearchMode`, and search engine code together.
- Keep exact-search query normalization shared between `SearchPlanner.planExact` and `SearchEngineImpl.searchExact`.
- Re-check `SearchCoverage`, refine behavior, and any recent-only hint paths together.
- Re-check header controls, search hints, pagination, and requirements docs.
- Run search-focused performance validation, not only unit tests.

### Clipboard Or Storage Semantics

- Touch `ClipboardMonitor`, `ClipboardService`, and `StorageService` as one flow.
- Re-check copy/replay semantics, external storage validation, cleanup behavior, and any item-model field assumptions.
- Preserve the durable-spool contract: retain source through commit, make receipt + mutation atomic, transition the envelope to terminal before receipt removal, and treat receipt replay as a no-op even when the item was later deleted.
- Route new cleanup variants through `StorageService.applyDeletePlan`; extend `DeleteCandidate` when a new policy predicate affects eligibility so commit-time revalidation remains complete.
- Test post-plan pin and payload replacement, shared storage refs, caller cancellation after commit, bulk queue delivery, and history pagination/total convergence.
- Preserve the lossless Swift-`Int` SQLite adapter. For byte-count changes, test values above `Int32.max`, disk reopen, cleanup stopping, and checked filesystem aggregation.
- For release-grade storage changes run `make build`, `make test-unit`, `make test-strict`, `make test-tsan`, `make test-snapshot-perf-release`, the applicable heavy cleanup tests, and frontend/unified profiling when event or projection code changes.

### Settings Or Hotkey Changes

- Touch `SettingsDTO`, settings pages, `SettingsView`, and runtime hotkey flow together.
- Preserve Save/Cancel and `settingsChanged` behavior.
- Verify `/tmp/scopy_hotkey.log` behavior when the hotkey path changes.

### Preview Or Export Changes

- Touch preview UI, rendering pipeline, and `MarkdownExportService` together.
- Keep hover preview planning in `HistoryHoverPreviewPipeline`; row views should apply typed events rather than own decode/cache/metric policy.
- For hover-preview work, run a focused test plus `scripts/perf-frontend-profile.sh --include-hover` so Markdown and image hover buckets are present.
- For hover-transfer changes, cover pure geometry/session behavior, controller cancellation and generation replacement, list-level transfer ownership, stale popover-token geometry, and XCUI trajectories both through and outside the real corridor.
- Run strict-concurrency coverage because the controller lifecycle is task-based. Treat the include-hover frontend profile as a broad rendering regression smoke; do not claim it measures safe-triangle travel unless its automation explicitly crosses row-to-popover geometry.
- For Markdown renderer fixes, update `Tools/MarkdownRenderer/test/chatgpt-wacz-20260828.test.js`, `Tools/MarkdownRenderer/test/render.test.js`, and `ScopyTests/ChatGPTMarkdownRendererTests.swift`; add isolated export UI coverage when the PNG output contract changes.
- Re-check pngquant settings interactions, preview latency, and output pasteboard behavior.

### File Action Or Context Menu Changes

- Keep file-system action resolution behind `ClipboardServiceProtocol.fileURLs(itemID:)`; views should not read persistence or storage paths directly.
- Treat AirDrop and Open Containing Folder as different contracts: AirDrop may use temporary PNGs for image rows, while Open Containing Folder must only reveal real source files.
- Update unit coverage for service URL resolution and UI coverage for menu visibility/action identifiers in the same change.

### Release Or Documentation Changes

- Update metadata, release note, release index, changelog, and any active current docs that changed semantically.
- Keep ordinary workflows top-level read-only. A release/documentation push validates only; only the explicit maintainer `make tag-release` / `make push-release` path may create a tag.
- Run `make test-release-policy` whenever `.github/workflows/`, release scripts, or release Make targets change.
- For release/versioning fixes, test both `scripts/version.sh --tag` and the release packaging path so the app bundle version, DMG name, and release metadata resolve from the same tag.
- Avoid putting new truth into compatibility directories or legacy archives.

## Important Invariants

- `project.yml` is the baseline source for Swift/Xcode/deployment targets.
- Active docs live under `doc/current`, `doc/releases`, and `doc/meta`.
- Historical directories under `doc/implementation`, `doc/profiles`, and `doc/specs` are non-normative evidence only, not compatibility entrypoints. Remove obsolete active links and paths instead of adding redirects, aliases, or compatibility stubs.
- Heavy work should stay off the main thread; correctness beats opportunistic speedups.
- Views should not directly become persistence clients.
- Every source file belongs to exactly one module. `Package.swift` and `project.yml` exclude the same directories from opposite sides; a file compiled into both `ScopyKit` and the app target produces two copies of its static state.
- Release publication consumes a deliberate existing tag; ordinary CI must never create or push one.
- Select roadmap work by evidenced severity, affected surface, recurrence/likelihood, and confidence relative to implementation/rollback cost. Prefer crashes, data-integrity failures, unsafe release paths, and measured systemic bottlenecks over cosmetic cleanup or speculative micro-optimization.

## Logging And Privacy

- Use the subsystem-specific `ScopyLog` categories (`app`, `monitor`, `storage`, `persistence`, `search`, `ui`, and `hotkey`) instead of ad hoc `print` or `NSLog` calls in production paths.
- Treat clipboard text, query strings, file paths, bundle identifiers, note contents, raw payloads, and unfiltered error descriptions as private by default. Never log clipboard bodies, image bytes, note contents, or file contents.
- Counts, durations, thresholds, and feature-state values may be public only when they cannot reveal user content.
- Avoid per-item logging in clipboard polling, list rendering, search candidates, or other hot loops unless it is sampled or guarded by an explicit diagnostic/profile flag.

## Related Docs

- Active requirements: [product-spec.md](./product-spec.md)
- High-leverage task selection: [high-leverage-change-guide.md](./high-leverage-change-guide.md)
- Release workflow: [release-runbook.md](./release-runbook.md)
- Short maintainer navigation: [maintainer-guide.md](./maintainer-guide.md)
- Current release window: [../releases/README.md](../releases/README.md)
