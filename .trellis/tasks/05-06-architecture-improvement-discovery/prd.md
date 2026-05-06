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
