# brainstorm: improve Scopy architecture

## Goal

Improve Scopy performance, stability, and maintainability by identifying deep architecture opportunities first, then choosing one behavior-preserving refactor path before doing broader optimization.

## What I already know

* The user wants maintainability first: keep existing behavior unchanged, split internal modules, then optimize gradually.
* The previous completed step extracted a decision-only search planner seam and committed it.
* Trellis current task was empty before this session, so this task is now the active source of truth for architecture discovery.
* Existing reviews repeatedly point to frontend state mutation, search/index cache boundaries, warm-load cost, and row asset/presentation pipelines as higher-value areas than cosmetic file splitting.
* Backend/frontend Trellis specs are present and should be read before implementation.

## Assumptions (temporary)

* The first implementation slice should be behavior-preserving and testable.
* We should prefer a deep module that improves locality and leverage over shallow file decomposition.
* Performance claims must be backed by existing Scopy perf gates or a targeted measurement.

## Open Questions

* Which candidate architecture seam should be explored first after codebase review?

## Requirements (evolving)

* Preserve current product behavior and user-visible semantics.
* Prefer internal Module depth over public API churn.
* Make the chosen path directly testable with focused unit tests.
* Keep validation aligned with repository gates: build, unit tests, strict concurrency, and perf gates when performance behavior changes.

## Acceptance Criteria (evolving)

* [x] Identify 3-5 architecture improvement candidates with file:line evidence.
* [x] Pick one candidate through a grill-me decision loop.
* [x] Define a behavior-preserving implementation slice for the chosen candidate.
* [x] Implement only after the chosen seam and test strategy are explicit.
* [x] Run the relevant validation gate for the implemented slice.

## Definition of Done

* Tests added or updated where the slice changes executable behavior or contracts.
* make build and make test-unit pass for normal code changes.
* make test-strict passes for actor, async, or event-stream changes.
* Performance gates run when the slice touches search, list rendering, scrolling, thumbnails, or warm-load paths.
* Docs or Trellis specs updated if the work creates a durable project rule.

## Out of Scope

* No broad rewrite before choosing a single candidate.
* No product behavior changes in the first slice unless explicitly approved.
* No release, tag, or Homebrew flow in this task.

## Technical Notes

* Active task: .trellis/tasks/05-06-architecture-improvement-discovery
* Relevant specs: .trellis/spec/backend/index.md, .trellis/spec/frontend/index.md
* Existing review sources: doc/reviews/codebase_review.md, doc/reviews/perf/perf-audit-2026-01-28.md
* Architecture vocabulary: Module, Interface, Implementation, Depth, Seam, Adapter, Leverage, Locality

## Discovery Findings

### Candidate 1: History list state Module

Files:

* Scopy/Observables/HistoryViewModel.swift:40
* Scopy/Observables/HistoryViewModel.swift:203
* Scopy/Observables/HistoryViewModel.swift:363
* Scopy/Observables/HistoryViewModel.swift:430
* Scopy/Observables/HistoryViewModel.swift:510
* Scopy/Observables/HistoryViewModel.swift:817
* ScopyTests/AppStateTests.swift:1114
* ScopyTests/SearchStateMachineTests.swift:193

Problem:

HistoryViewModel currently owns the visible items array, pinned/unpinned derived caches, id index cache, selection navigation, event mutations, search/load/loadMore versioning, and paging counters. The existing lazy id index is useful, but it is still coupled to every array mutation through didSet invalidation. This keeps list correctness, performance, and stale-write rules in one broad @MainActor Implementation.

Solution direction:

Introduce an internal behavior-preserving Module for visible history list state. The first slice should move only ordered item mutation, id lookup, pinned split invalidation, and count/canLoadMore updates behind one local implementation, while keeping HistoryViewModel's public behavior unchanged.

Benefits:

* Locality: list invariants live in one Module instead of being spread across event handlers and search/load callbacks.
* Leverage: existing thumbnail update, paging, and stale search tests can cover the seam directly.
* Performance: id lookup and derived caches can become maintained state instead of repeatedly lazy-rebuilt state.
* Stability: stale result guards stay visible while list mutation becomes easier to test.

Recommendation:

Pick this as the first architecture slice. It is the lowest-risk behavior-preserving refactor with direct tests and a clear path to later performance work.

### Candidate 2: Search index and disk-cache Module

Files:

* Scopy/Infrastructure/Search/SearchPlanner.swift:3
* Scopy/Infrastructure/Search/SearchEngineImpl.swift:1019
* Scopy/Infrastructure/Search/SearchEngineImpl.swift:1351
* Scopy/Infrastructure/Search/SearchEngineImpl.swift:1780
* Scopy/Infrastructure/Search/SearchEngineImpl.swift:1828
* Scopy/Infrastructure/Search/SearchEngineImpl.swift:2177
* Scopy/Infrastructure/Search/SearchEngineImpl.swift:2728

Problem:

SearchPlanner now expresses path, coverage, reason, and capabilities, but SearchEngineImpl still owns index lifecycle, warm-load, disk cache codec, recent cache scan, pending events, persistence, and query execution. This is a deep seam candidate, but its blast radius is larger.

Solution direction:

Later split search index/cache lifecycle into a deeper internal Module with adapters for disk cache load/persist and index mutation. Avoid starting here unless the goal is backend search maintainability first.

### Candidate 3: Row asset and preview pipeline Module

Files:

* Scopy/Views/History/HistoryItemView.swift:39
* Scopy/Views/History/HistoryItemView.swift:63
* Scopy/Views/History/HistoryItemView.swift:580
* Scopy/Presentation/HistoryItemPresentationCache.swift:5
* Scopy/Presentation/HistoryItemPresentationCache.swift:73
* ScopyUISupport/IconService.swift:26
* ScopyUISupport/ThumbnailCache.swift:119

Problem:

Presentation cache, preview budget, icon loading, and thumbnail decode already exist, but the row still reaches into multiple shared services and some cache misses remain MainActor work. This is a good future performance seam, but previous profiling says row-level changes alone may not explain all long-frame time.

Solution direction:

Later introduce a row asset preparation Module that batches icon/thumbnail/presentation data before row render, then validate with frontend perf profile.

### Process Finding: sub-agent TASK_DIR override remains fragile

The main session successfully started .trellis/tasks/05-06-architecture-improvement-discovery, but two explorer agents stopped at local no-current-task state despite receiving TASK_DIR in their prompt. A later frontend explorer proceeded but spawned child agents and did not return findings before timeout. Treat agent output from this discovery pass as incomplete; the candidates above are based on main-session repository inspection.

## Grilling Decisions

### Decision 1: First slice candidate

Question:

Should the first behavior-preserving architecture slice be Candidate 1: History list state Module?

Answer:

Accept Candidate 1.

Rationale:

HistoryViewModel currently has too much Implementation behind a broad implicit Interface: visible ordered items, pinned/unpinned derived caches, id lookup cache, event mutation, paging counters, selection navigation, and search/load lifecycle all live in one @MainActor Module. A dedicated internal history list state Module gives better Locality while preserving the existing public HistoryViewModel Interface.

### Decision 2: First version ownership

Question:

Should this Module own searchVersion/isLoading/searchCoverage, or only visible list and paging counters?

Answer:

Only visible list and paging counters.

Rationale:

The first slice must stay behavior-preserving. Keep async stale-write control, Task cancellation, loading state, and coverage semantics in HistoryViewModel. Move ordered item mutation, id lookup, pinned/unpinned cache maintenance, and loadedCount/totalCount/canLoadMore updates behind the new Module seam first.

### Decision 3: State shape and Swift Observation

Question:

What should the first-version HistoryListState Interface shape be so it deepens the Module without breaking Swift Observation or increasing the public HistoryViewModel Interface?

Answer:

Use a value-type internal Module owned by HistoryViewModel. HistoryViewModel keeps the existing public observable Interface as computed passthroughs over private stored listState.

Rationale:

A reference object hidden behind @ObservationIgnored would hide real UI state from Swift Observation. The frontend spec reserves @ObservationIgnored for dependencies, tasks, handlers, and caches, while views and tests currently observe HistoryViewModel.items, pinnedItems, unpinnedItems, loadedCount, totalCount, and canLoadMore. A value-type stored Module keeps observation tied to HistoryViewModel while moving list Implementation and invariants behind a smaller seam.

Initial Interface:

* Read surface: items, pinnedItems, unpinnedItems, loadedCount, totalCount, canLoadMore.
* Lookup surface: indexOfItem(withID:), item(at:), item(withID:).
* Mutation surface: replaceItems, appendItems, setTotalCount, setPaging, recomputeCanLoadMore, setItemIfChanged, removeItem, insertOrMoveItemToFront.

Out of scope:

Do not move searchVersion, Task cancellation, isLoading, searchCoverage, SearchRequest construction, debounce/refine timing, service calls, prewarmDisplayText, ThumbnailCache eviction, selection semantics, filters, or PerformanceMetrics into this Module in the first slice.

### Decision 4: Derived cache strategy

Question:

Should HistoryListState maintain pinned/unpinned arrays and id index eagerly on every mutation, or keep lazy internal caches in the first slice?

Answer:

Maintain derived state eagerly in the first slice.

Rationale:

The current lazy cache pattern is part of the shallow Implementation: items didSet invalidates pinned/unpinned caches and itemIndexByID, while read paths rebuild lazily. Moving that same invalidation model into HistoryListState would move complexity but not deepen the Module much. Eager maintenance makes mutation methods the only place that updates ordered items, pinned/unpinned derived arrays, id lookup, loadedCount, totalCount, and canLoadMore.

Invariants:

* items remains the source of truth for visible order.
* pinnedItems and unpinnedItems preserve the relative order from items.
* itemIndexByID always matches current items indices.
* thumbnailUpdated and itemContentUpdated update in place without reordering.
* itemPinned and itemUnpinned update pinned derivation without reordering.
* insertOrMoveItemToFront keeps existing move-to-front behavior for matching new/update events.
* loadedCount, totalCount, and canLoadMore preserve current caller-driven semantics.
* searchVersion, Task cancellation, isLoading, and searchCoverage stay in HistoryViewModel.

Test plan:

Add focused HistoryListState tests for replace, append, in-place update, remove, pin/unpin derivation, and id lookup. Keep existing AppState/SearchStateMachine tests as integration coverage for thumbnail no-reorder, pinned filtering, and stale loadMore/search behavior.

### Decision 5: Items setter compatibility

Question:

Should the first implementation fully hide mutable items and only allow mutation methods, or preserve a HistoryViewModel.items computed setter as a compatibility transition that calls listState.replaceItems(newValue)?

Answer:

Preserve a HistoryViewModel.items computed setter as a compatibility transition.

Rationale:

items is currently part of the public HistoryViewModel Interface and tests still mutate it directly through AppState compatibility. Removing the setter would mix Module extraction with an Interface break. The setter should become a narrow transition seam: getter reads listState.items, setter calls listState.replaceItems(newValue). Internally, new code should prefer semantic mutation methods on HistoryListState.

Policy:

* Keep public var items get/set for now.
* Treat external direct mutation as compatibility, not the preferred internal Implementation path.
* Route direct setter assignment through listState.replaceItems so derived state stays consistent.
* Later migration can remove or narrow the setter after tests and callers are moved to semantic methods.

### Decision 6: Paging transaction methods

Question:

Should loadedCount, totalCount, and canLoadMore be updated through transaction methods like replacePage(items,total,hasMore) and appendPage(items,total,hasMore), or through separate granular setters after item mutations?

Answer:

Use transaction methods for page results and focused incremental methods for event paths.

Rationale:

The first version owns paging counters, so item replacement/appending and paging state should not keep drifting as separate assignments in HistoryViewModel. Transaction methods make the list Module deeper: callers express a page-level action, while the Implementation maintains items, derived arrays, id lookup, loadedCount, totalCount, and canLoadMore together.

Initial transaction surface:

* replacePage(items:total:hasMore:)
* appendPage(items:total:hasMore:)
* appendRecentPage(items:) using existing totalCount to recompute canLoadMore
* updateTotalCount(_:)
* recomputeCanLoadMore()

Event support:

* insertOrMoveItemToFront(_:)
* setItemIfChanged(at:to:)
* removeItem(withID:)
* incrementTotalCount()
* decrementTotalCountIfNeeded(wasPresent:isUnfilteredList:)

Correction:

Do not move searchCoverage into HistoryListState despite it appearing in one agent-proposed sketch. Decision 2 still controls this seam: coverage is search lifecycle state and remains in HistoryViewModel for this slice.

## Implementation Summary

Implemented Candidate 1 as the first behavior-preserving architecture slice.

Files:

* Scopy/Observables/HistoryListState.swift
* Scopy/Observables/HistoryViewModel.swift
* ScopyTests/HistoryListStateTests.swift
* ScopyTests/AppStateTests.swift
* ScopyTests/AppStateTestCompatibility.swift
* Scopy.xcodeproj/project.pbxproj

What changed:

* Added an internal @MainActor value-type HistoryListState Module.
* HistoryListState now owns visible ordered items, pinned/unpinned derived arrays, id lookup, loadedCount, totalCount, and canLoadMore.
* HistoryViewModel keeps the public observable surface as computed passthroughs and still owns searchVersion, task cancellation, isLoading, searchCoverage, filters, service calls, and performance metrics.
* Replaced direct HistoryViewModel list/counter writes with transaction methods: replaceItems, replacePage, appendPage, appendRecentPage, updateTotalCount, increment/decrement total, and semantic item mutation helpers.
* Preserved the HistoryViewModel.items setter as a compatibility transition.
* Kept PerfFeatureFlags.historyIndexingEnabled fallback for id lookup behavior; eager derived arrays/index are still rebuilt on mutation.

Review result:

The replacement review agent found no blocking issue. It called out two residual risks: direct delete counter timing and Swift Observation invalidation through private value-type state. Both were converted into focused regression tests.

Validation:

* xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/HistoryListStateTests: passed, 7 tests.
* xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/AppStateTests/testDeleteUpdatesVisibleCountersAndDeletedEventConverges -only-testing:ScopyTests/AppStateTests/testHistoryListStatePassthroughsInvalidateObservation: passed, 2 tests.
* make build: passed.
* make test-unit: passed, 398 tests, 1 skipped.
* make test-strict: passed, 398 tests, 1 skipped.

Next candidate after this slice:

Candidate 2, search index and disk-cache Module, should be the next architecture discovery target if backend maintainability/performance is the priority. Candidate 3, row asset and preview pipeline Module, is the better next target if frontend scrolling/rendering performance is the priority.


## Phase 2 Candidate Decision: SearchIndexDiskCache

Question:

For Candidate 2, should the next behavior-preserving slice extract disk-cache persistence/codec/fingerprint/path handling, or live index lifecycle state/mutation/rebuild/pending-events?

Answer:

Extract disk-cache persistence first, but narrow the first slice to an internal SearchIndexDiskCache Module. Do not extract live index lifecycle yet.

Rationale:

Disk-cache logic has good Locality and can form a deep Module: path generation, DB fingerprinting, checksum handling, metadata preflight, full/short cache decoding, and persist request writing are all disk-cache Implementation details currently inside SearchEngineImpl. This gives Leverage behind a smaller Interface without changing query semantics.

Live lifecycle is a worse first slice. It combines actor state, build Task generation, pending events, DB change token safety, query cache reset, corpus metrics, and SearchPlanner state. Extracting it now would expose a broad Interface and create a shallow Seam.

Evidence:

* SearchEngineImpl owns full/short index state and tasks at Scopy/Infrastructure/Search/SearchEngineImpl.swift:1024.
* Disk-cache path/fingerprint/load/persist code is clustered around Scopy/Infrastructure/Search/SearchEngineImpl.swift:1654, 1731, 1780, 1827, 2177, and 2210.
* Existing disk-cache hardening tests already cover the behavior surface in ScopyTests/FullIndexDiskCacheHardeningTests.swift and ScopyTests/ShortQueryIndexDiskCacheHardeningTests.swift.

First-slice Interface sketch:

* SearchIndexDiskCache.fullPaths(dbPath:)
* SearchIndexDiskCache.shortPaths(dbPath:)
* SearchIndexDiskCache.loadFullSnapshot(dbPath:metrics:)
* SearchIndexDiskCache.loadShortSnapshot(dbPath:)
* SearchIndexDiskCache.makeFullPersistRequest(index:dbPath:)
* SearchIndexDiskCache.makeShortPersistRequest(index:dbPath:)
* SearchIndexDiskCache.writeFullPersistRequest(_:)
* SearchIndexDiskCache.writeShortPersistRequest(_:)

Implementation rule:

make*PersistRequest should run synchronously on the SearchEngineImpl actor before detached persistence starts, preserving the current fingerprint sampling time. Detached tasks should only write an already-created request.

Must stay in SearchEngineImpl for this slice:

* full/short in-memory index storage
* build tasks and generation counters
* pending events
* cancel/close sequencing
* query cache reset
* corpus metrics
* DB change token safety
* SearchPlanner state mapping
* query-time wait behavior

Validation plan:

* Targeted tests: FullIndexDiskCacheHardeningTests, ShortQueryIndexDiskCacheHardeningTests, FullIndexPendingEventsCleanupTests, SearchPlannerTests.
* Standard gates: make build, make test-unit, make test-strict.
* Because this touches search warm-load/disk-cache paths, run make test-snapshot-perf-release before considering the slice complete.

Process note:

Do not implement this second slice until the current HistoryListState slice is isolated. Mixing Candidate 1 and Candidate 2 in one uncommitted change would make review and rollback harder.

## Candidate 2 Implementation Summary

Implemented the SearchIndexDiskCache first slice as a behavior-preserving backend architecture refactor.

Files:

* Scopy/Infrastructure/Search/SearchIndexDiskCache.swift
* Scopy/Infrastructure/Search/SearchEngineImpl.swift

What changed:

* Added an internal SearchIndexDiskCache Module for full/short search index disk-cache paths, DB/WAL/SHM fingerprinting, checksum validation, metadata preflight, payload decoding, persist request creation, and request writing.
* SearchEngineImpl now routes background warm-load through SearchIndexDiskCache.loadFullSnapshot(dbPath:metrics:) and short-index warm-load through SearchIndexDiskCache.loadShortSnapshot(dbPath:).
* On-demand full-index build now reuses SearchIndexDiskCache.preflightFullIndex(dbPath:) and SearchIndexDiskCache.loadFullSnapshot(from:) instead of retaining a second disk-cache codec path.
* makeFullPersistRequest and makeShortPersistRequest still run synchronously on the SearchEngineImpl actor before detached persistence starts. Detached tasks now only write already-created requests.
* SearchEngineImpl still owns live lifecycle state: full/short in-memory indexes, build tasks, generation counters, pending event replay, close/cancel sequencing, DB change token stale-write protection, query cache reset, corpus metrics, SearchPlanner state mapping, and query-time wait behavior.

Review result:

The final check agent found no blocking code issue. It confirmed the boundary stays limited to disk-cache Implementation, warm-load and on-demand full-index paths share the new disk-cache API, disk cache versions/path formats remain compatible, and debug path helpers now delegate to SearchIndexDiskCache.

Trellis process correction:

The original implement/check JSONL files still contained seed example rows, which caused sub-agents to fallback or stop on local no-current-task state. Those files now contain real spec entries so future implement/check agents can start from curated backend specs.

Validation:

* make build: passed.
* xcodebuild test -project Scopy.xcodeproj -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/FullIndexDiskCacheHardeningTests -only-testing:ScopyTests/ShortQueryIndexDiskCacheHardeningTests -only-testing:ScopyTests/FullIndexPendingEventsCleanupTests -only-testing:ScopyTests/SearchPlannerTests: passed, 23 tests.
* make test-unit: passed, 398 tests, 1 skipped.
* make test-strict: passed, 398 tests, 1 skipped.
* make test-snapshot-perf-release: passed; cmd p95=0.11599063873291016 ms target 50, cm p95=5.63502311706543 ms target 20.

Next candidate after this slice:

Candidate 3, row asset and preview pipeline Module, is the next likely architecture target if the goal remains performance and maintainability. Before implementing it, run another grill-me decision loop and read frontend specs.

## Phase 2 Candidate Decision: RowAssetDescriptor

Question:

For Candidate 3, should the first behavior-preserving slice only produce a row-ready presentation/asset descriptor Module, or should it also move thumbnail async loading plus scroll-settle budget into that Module immediately?

Answer:

Produce only a row-ready presentation/asset descriptor Module in the first slice. Do not move thumbnail async loading, decoded NSImage state, SwiftUI task identity, cancellation, or scroll-settle budget in this slice.

Rationale:

The row descriptor can be a deeper Module because its Interface stays narrow: ClipboardItemDTO plus SettingsDTO in, row-ready title, metadata, thumbnail settings, file preview summary, PNG export capability, thumbnail visibility, and lightweight asset request data out. Its Implementation can hide current calls to HistoryItemPresentationCache, ClipboardItemDisplayText, FilePreviewSupport, settings-derived thumbnail height, and item-type branching.

Thumbnail async loading is a separate lifecycle/scheduling seam. Moving it now would mix descriptor derivation with State, task identity, cancellation, priority selection from HistoryListInteractionCoordinator.isScrolling, delayed commit after scroll settle, and ThumbnailCache decode/cache behavior. That would widen the first Interface and make the Module shallow.

First-slice rules:

* Introduce an internal row descriptor type under Scopy/Presentation.
* Move the private HistoryItemDisplayModel derivation out of HistoryItemView into that Module.
* Keep the descriptor free of NSImage, Task, State, StateObject, and scroll coordinator references.
* Keep HistoryItemThumbnailView, HistoryItemFileThumbnailView, HistoryItemImagePreviewView, and HistoryItemFilePreviewView owning their existing async thumbnail/file-preview tasks.
* Preserve current row.display_model_ms instrumentation or move it with the descriptor without changing the metric name.

Evidence:

* HistoryItemView currently builds a private HistoryItemDisplayModel and directly reaches into presentation caches for row-ready data.
* Image and file thumbnail views duplicate async load and scroll-settle behavior, but existing tests do not yet cover cancellation or scroll-settle scheduling well enough to move that lifecycle safely in the first slice.
* Frontend specs require row/list/thumbnail/preview performance-sensitive work to stay behind caches/controllers and to use perf gates before claiming performance changes.

Next grill question:

Should the row descriptor Module include app icon lookup/caching in the first slice, or should it expose only an app icon request field such as appBundleID and leave IconService lookup in HistoryItemView until a separate icon/asset loader seam is designed?

### Decision: app icon scope

Question:

Should the row descriptor Module include app icon lookup/caching in the first slice, or should it expose only an app icon request field such as appBundleID and leave IconService lookup in HistoryItemView until a separate icon/asset loader seam is designed?

Answer:

Expose only app icon request data in the descriptor, preferably appIconBundleID. Do not include IconService lookup, NSImage state, NSWorkspace access, or icon cache behavior in the first slice.

Rationale:

The descriptor should remain value-like and testable from ClipboardItemDTO, SettingsDTO, and presentation cache data. IconService is already a separate ScopyUISupport Module with MainActor cache and NSWorkspace load-on-miss behavior. Moving it into the descriptor would mix presentation derivation with AppKit resource lookup and would not cover HeaderView, which also uses IconService.

First-slice rule:

HistoryItemView may replace direct item.appBundleID access with descriptor.appIconBundleID, but it should continue calling IconService.shared.icon(bundleID:) and rendering the existing ScopyIcons.app fallback.

### Decision: descriptor placement

Question:

Should the first RowAssetDescriptor implementation be placed in Scopy/Presentation as HistoryItemRowDescriptor with injectable cache dependencies for tests, or should it stay as an internal nested/private type near HistoryItemView until its Interface stabilizes?

Answer:

Place the first implementation in Scopy/Presentation as an internal app-target type named HistoryItemRowDescriptor, with narrow injectable presentation dependencies for focused tests. Do not keep it private inside HistoryItemView, and do not publish it through ScopyKit or ScopyUISupport.

Rationale:

The descriptor is already more than view-local rendering: it adapts ClipboardItemDTO, SettingsDTO, HistoryItemPresentationCache, and ClipboardItemDisplayText into a row-ready contract. Scopy/Presentation is the project-local home for UI-facing formatting and presentation caches, while ScopyKit excludes Presentation and ScopyUISupport should stay focused on reusable support services such as IconService and ThumbnailCache.

Implementation shape:

* Add Scopy/Presentation/HistoryItemRowDescriptor.swift.
* Move the current HistoryItemDisplayModel fields and initializer logic from HistoryItemView into that internal type.
* Add a tiny dependency container for display text derivation and presentation derivation, defaulting to ClipboardItemDisplayText.shared and HistoryItemPresentationCache.shared.
* Keep HistoryItemView responsible for rendering, row interaction, hover/popovers, row controller state, preview coordinator state, icon lookup, and thumbnail view composition.
* Add ScopyTests/HistoryItemRowDescriptorTests.swift with focused descriptor parity and dependency tests.

### Decision: metric continuity

Question:

Should the descriptor production path keep the existing row.display_model_ms metric name around HistoryItemRowDescriptor construction, or rename it to a new metric such as row.descriptor_ms and update perf analysis scripts/docs in the same slice?

Answer:

Keep row.display_model_ms for the first behavior-preserving extraction.

Rationale:

This slice is an internal ownership refactor, not a measurement taxonomy change. Keeping the metric name preserves continuity with existing perf scripts, unified perf tables, and profile history while still measuring the same row descriptor construction work. A later metric rename can happen only if the descriptor Interface stabilizes and the profiling story needs a clearer name.

## Candidate 3 Implementation Summary

Implemented the first RowAssetDescriptor slice as a behavior-preserving frontend architecture refactor.

Files:

* Scopy/Presentation/HistoryItemRowDescriptor.swift
* Scopy/Views/History/HistoryItemView.swift
* ScopyTests/HistoryItemRowDescriptorTests.swift
* Scopy.xcodeproj/project.pbxproj

What changed:

* Added an internal @MainActor HistoryItemRowDescriptor in Scopy/Presentation.
* Moved the former private HistoryItemDisplayModel derivation out of HistoryItemView into the descriptor.
* Descriptor inputs are ClipboardItemDTO, SettingsDTO, and a tiny injectable dependency container for display text, file preview summary, and PNG export capability.
* Descriptor outputs include titleText, metadataText, thumbnailHeight, showThumbnails, file preview fields, thumbnail flags, PNG export capability, needsThumbnailHeight, and appIconBundleID.
* HistoryItemView still owns rendering, row interaction, popovers, row controller state, preview coordinator state, IconService.shared.icon(bundleID:), and thumbnail/file-preview view composition.
* Kept thumbnail async loading, scroll-settle behavior, decoded image state, preview tasks, and popover lifecycle out of the descriptor.
* Preserved the row.display_model_ms metric name around descriptor construction.

Validation:

* xcodebuild test -project Scopy.xcodeproj -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/HistoryItemRowDescriptorTests: passed, 5 tests.
* make build: passed.
* make test-unit: passed, 403 tests, 1 skipped.
* make test-strict: passed, 403 tests, 1 skipped.
* make perf-frontend-profile: passed, 3 UI scroll profile tests; summary at logs/perf-frontend-profile-2026-05-07_01-10-56/frontend-scroll-profile-summary.md.

Follow-up:

* Frontend perf smoke was run as a regression guard, but this slice does not claim a performance improvement because it did not move async thumbnail, scroll-settle, preview scheduling, or render lifecycle behavior.
* A future Candidate 3 slice can design an actual asset-loader seam for icons/thumbnails only after adding lifecycle/cancellation/scroll-settle coverage.

## Phase 2 Candidate Decision: RowThumbnailLifecycleScheduler

Question:

For the next Candidate 3 slice after HistoryItemRowDescriptor, should we implement an actual row asset-loader seam for icons/thumbnails now, or first add/extract a testable thumbnail/icon lifecycle scheduler seam that preserves current loading in the SwiftUI row views?

Answer:

Extract a testable row thumbnail lifecycle scheduler first. Do not implement a broad row asset-loader seam that owns NSImage loading, ThumbnailCache, IconService, or row preview image state in this slice.

Rationale:

ThumbnailCache already owns cache lookup, bounded decode concurrency, in-flight dedupe, ImageIO decode, NSImage creation, cache store, and thumbnail metrics. The duplicated Implementation now lives in the row lifecycle policy: path reset, cache-hit short-circuit, priority selection while scrolling, cache-miss load, delayed commit until scroll settles, cancellation guards, and final state commit.

The useful Module seam is between SwiftUI row lifecycle and ThumbnailCache, not between the row and a new asset-loading service. Keeping the Interface focused on lifecycle scheduling gives Locality for the fragile timing/cancellation rule and Leverage through focused tests.

### Decision: scheduler preview scope

Question:

Should the lifecycle scheduler first slice be scoped only to visible row thumbnails (HistoryItemThumbnailView and HistoryItemFileThumbnailView), or should it also cover preview fallback thumbnails in HistoryItemImagePreviewView and HistoryItemFilePreviewView with a no-scroll-settle policy mode?

Answer:

Scope the first scheduler slice only to visible row thumbnails: HistoryItemThumbnailView and HistoryItemFileThumbnailView. Do not include preview fallback thumbnails in HistoryItemImagePreviewView or HistoryItemFilePreviewView in this slice.

Rationale:

The two row thumbnail views duplicate the same row-list contract almost line for line. Preview fallback thumbnails are related but semantically different: they always use userInitiated priority today, do not wait for scroll settling, and are mixed with popover preview timing, file availability, QuickLook, video sizing, markdown routing, and file icon fallback. Adding a preview mode now would widen the Interface before the row scheduler contract is proven.

### Decision: scheduler Interface

Question:

Should the row thumbnail lifecycle scheduler be implemented as a pure value-returning policy that the views apply to @State, or as an async helper method that owns cache lookup/load/wait and returns a commit result for the current path?

Answer:

Implement an internal @MainActor async helper named HistoryRowThumbnailLifecycleScheduler. It should own cache lookup, cache-miss load, priority selection, scroll-settle waiting, cancellation checks, and return a typed path-tagged commit result. SwiftUI row thumbnail views still own @State loadedThumbnail and lastLoadedPath and perform the final state application guard.

Proposed Interface:

* HistoryRowThumbnailLifecycleScheduler.cachedImage(for:)
* HistoryRowThumbnailLifecycleScheduler.loadCommitResult(for:)
* HistoryRowThumbnailLifecycleScheduler.CommitResult(path:image:source:)
* HistoryRowThumbnailLifecycleScheduler.Dependencies for cachedImage, loadImage, isScrolling, sleep, and isCancelled.

Rules:

* Keep .task(id: thumbnailPath) as the SwiftUI trigger and cancellation boundary.
* Keep loadedThumbnail, lastLoadedPath, placeholders, video overlay, sizing, padding, and accessibility identifiers in the existing row thumbnail views.
* Keep cache hits immediate and skip scroll-settle waiting for cache hits.
* Keep cache misses using .utility while interactionCoordinator.isScrolling is true and .userInitiated otherwise.
* Keep the bounded 20 x 80 ms scroll-settle behavior before committing cache-miss results.
* Keep preview fallback views, IconService, ThumbnailCache internals, NSImage cache ownership, QuickLook, video sizing, markdown routing, and file-existence checks out of scope.

Test plan:

* Add ScopyTests/HistoryRowThumbnailLifecycleSchedulerTests.swift.
* Cover cache hit without load/sleep, cache miss priority while not scrolling, cache miss priority while scrolling, bounded wait, cancellation before load/after load/during scroll-settle, nil load result, and path-tagged commit result.
* Keep ThumbnailPipelineTests as ThumbnailCache coverage.
* Run focused scheduler tests plus ThumbnailPipelineTests, HistoryListInteractionCoordinatorTests, HistoryItemRowDescriptorTests, and ScrollPerformanceTests.

Validation plan:

* make build
* make test-unit
* make test-strict
* make perf-frontend-profile at minimum because row/list/thumbnail hot paths are touched.
* Do not claim a performance win unless fresh profile output shows preservation or improvement.

## Implementation Summary: RowThumbnailLifecycleScheduler

Implemented:

* Added internal @MainActor HistoryRowThumbnailLifecycleScheduler under Scopy/Views/History.
* Centralized row thumbnail cache lookup, cache-miss priority selection, ThumbnailCache loading, cancellation checks, and bounded 20 x 80 ms scroll-settle waiting.
* Kept HistoryItemThumbnailView and HistoryItemFileThumbnailView as SwiftUI adapters that own @State loadedThumbnail/lastLoadedPath, render placeholders/overlays/accessibility identifiers, and apply path-tagged commit results only when still current.
* Left preview fallback thumbnails, IconService, ThumbnailCache internals, QuickLook, markdown routing, file-existence checks, and performance claims out of scope.
* Added HistoryRowThumbnailLifecycleSchedulerTests for cache-hit no-load/no-sleep behavior, cache-miss priority, scroll-settle waiting, bounded wait, cancellation before load/after load/during wait, nil loads, and path tagging.

Validation:

* xcodebuild test -project Scopy.xcodeproj -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/HistoryRowThumbnailLifecycleSchedulerTests: passed, 9 tests.
* xcodebuild test -project Scopy.xcodeproj -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/ThumbnailPipelineTests -only-testing:ScopyTests/HistoryListInteractionCoordinatorTests -only-testing:ScopyTests/HistoryItemRowDescriptorTests -only-testing:ScopyTests/ScrollPerformanceTests: passed, 18 tests.
* make build: passed.
* make test-unit: passed, 412 tests, 1 skipped.
* make test-strict: passed, 412 tests, 1 skipped.
* make perf-frontend-profile: passed, 3 UI scroll profile tests; summary at logs/perf-frontend-profile-2026-05-07_02-05-45/frontend-scroll-profile-summary.md.

Follow-up:

* The frontend perf smoke is a regression guard only. It produced mixed/noisy metric deltas: row/display buckets stayed broadly stable, while thumbnail total/decode buckets worsened in two scenarios and improved in text-bias. Because thumbnail total latency can include scheduling/deferral, do not claim a performance win from this slice.

## Implementation Note: Static Production Cache Facade

Implemented:

* Added HistoryRowThumbnailLifecycleScheduler.productionCachedImage(for:) as the scheduler-owned production facade for synchronous row cache reads.
* Replaced body-local HistoryRowThumbnailLifecycleScheduler construction in HistoryItemThumbnailView and HistoryItemFileThumbnailView with the static facade, preserving the loaded @State fallback.
* Kept loadThumbnailIfNeeded(path:) on both row thumbnail views using an instance scheduler for loadCommitResult(for:), including interactionCoordinator priority, scroll-settle waiting, cancellation checks, and final path guards.
* Left preview fallback views, ThumbnailCache internals, IconService, QuickLook/video sizing, accessibility identifiers, and metric names out of scope.
* Added focused scheduler coverage that proves productionCachedImage(for:) reads ThumbnailCache.shared.

Validation:

* xcodebuild test -project Scopy.xcodeproj -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/HistoryRowThumbnailLifecycleSchedulerTests -only-testing:ScopyTests/ThumbnailPipelineTests -only-testing:ScopyTests/HistoryListInteractionCoordinatorTests -only-testing:ScopyTests/ScrollPerformanceTests: passed, 23 tests.
* make build: passed.
* make test-unit: passed, 413 tests, 1 skipped.
* make test-strict: passed, 413 tests, 1 skipped.
* xcodebuild test -project Scopy.xcodeproj -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyUITests/HistoryListUITests/testHistoryListExists: passed after clearing residual Scopy processes, 1 UI test.

Validation stability fix:

* make perf-frontend-profile initially failed before producing a summary at logs/perf-frontend-profile-2026-05-07_02-58-16 because the real-snapshot UI tests could not find Window/History.List; the latest diagnostic report showed the app process crashing in XCTest automation support, faulting on com.apple.dt.xctautomationsupport.automation-session inside XCElementSnapshot recursivelyClearDataSource, not in the descriptor or scheduler code.
* Added process isolation to scripts/perf-frontend-profile.sh: quit com.scopy.app, clear residual Scopy executable processes before the script, before/after each baseline/current variant run, and on exit. This prevents stale app instances or poisoned XCTest automation state from invalidating the profile gate.
* Updated .trellis/spec/frontend/quality-guidelines.md with the frontend profile isolation rule and the rule that failed profile runs without a summary are not performance evidence.
* bash -n scripts/perf-frontend-profile.sh: passed.
* bash scripts/perf-frontend-profile.sh --repeats 1 --duration 4 --min-samples 60 --skip-setup: passed, 3 baseline UI profile tests and 3 current UI profile tests; summary at logs/perf-frontend-profile-2026-05-07_03-15-51/frontend-scroll-profile-summary.md.
* make perf-frontend-profile: passed, 3 baseline UI profile tests and 3 current UI profile tests; summary at logs/perf-frontend-profile-2026-05-07_03-18-32/frontend-scroll-profile-summary.md.
* make perf-frontend-profile-standard: passed, 3 baseline UI profile tests and 3 current UI profile tests; summary at logs/perf-frontend-profile-2026-05-07_03-22-16/frontend-scroll-profile-summary.md.
* git diff --check: passed after these changes.

Performance interpretation:

* Standard profile evidence shows no row descriptor regression: row.display_model_ms.p95 was stable across real-snapshot scenarios (-0.19%, -1.06%, +2.65%).
* Standard profile evidence shows thumbnail load total p95 improved across real-snapshot scenarios (-36.92%, -32.32%, -91.55%).
* Standard profile evidence still shows small/noisy UI sampling variation in frame_p95 for text-bias and main_runloop/row.file_preview buckets, so this slice should be described as architecture/stability/testability improvement with stronger thumbnail-path evidence, not as a blanket UI performance win.

Final check:

* gpt-5.5 high trellis-check final_check_trellis_architecture_hardening reported no findings and made no self-fixes.
* The check reran/trusted the relevant gates: git diff --check, task validation for both 05-06-architecture-improvement-discovery and 05-06-codex-taskdir-override-docs, bash -n scripts/perf-frontend-profile.sh, Python py_compile on modified Trellis hooks, and Claude/Cursor explicit TASK_DIR hook smoke.
* The check confirmed Candidate 3 boundaries stayed intact: HistoryItemRowDescriptor remains presentation-only, IconService and preview fallback stay outside the slice, and HistoryRowThumbnailLifecycleScheduler centralizes row thumbnail cache/load/priority/scroll-settle/cancellation without becoming a broad asset loader.
