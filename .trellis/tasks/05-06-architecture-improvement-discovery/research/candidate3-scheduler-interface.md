# Research: Candidate 3 scheduler interface

- Query: Should the row thumbnail lifecycle scheduler be implemented as a pure value-returning policy that the views apply to @State, or as an async helper method that owns cache lookup/load/wait and returns a commit result for the current path?
- Scope: internal
- Date: 2026-05-07

## Findings

Recommended answer: implement the row thumbnail lifecycle scheduler as an internal @MainActor async helper that owns cache lookup, cache-miss load, priority selection, scroll-settle waiting, cancellation checks, and then returns a typed commit result for the path it loaded. The SwiftUI views should still own @State and perform the final state application guard.

Do not make the first slice a pure value-returning policy where the views execute the plan step-by-step. That shape would leave the fragile async ordering in the two views and would make the new Module mostly a decision table. The duplicate Implementation today is the sequence itself: reset stale row state, check cache, choose priority from scroll state, call ThumbnailCache, avoid committing cancelled work, defer cache-miss commit while scrolling, and then assign an image. The useful seam is to move that sequence behind one tested async helper without moving SwiftUI state ownership or ThumbnailCache decoding ownership.

Architecture vocabulary reading:

- Module: add a row thumbnail lifecycle scheduler Module near the row thumbnail views, not in Presentation and not in ScopyUISupport yet. The Module is row-list lifecycle policy plus async orchestration for visible row thumbnails only.
- Interface: expose a narrow async method such as loadCommitResult(for:) plus a small cachedImage(for:) facade for render-time cache checks. The Interface returns path-tagged data, not direct @State mutation.
- Implementation: keep ThumbnailCache as the asset loading/cache/decode Implementation. The scheduler Implementation coordinates when ThumbnailCache is queried or loaded and when a loaded result is eligible to be committed.
- Depth: an async helper is deeper than a pure policy because it hides the repeated timing and cancellation sequence, not just the priority decision.
- Seam: the seam sits between SwiftUI .task(id:) / @State and ThumbnailCache / HistoryListInteractionCoordinator. It should not cross into preview popover lifecycle, IconService, QuickLook, markdown preview, or file existence tasks in this slice.
- Adapter: HistoryItemThumbnailView and HistoryItemFileThumbnailView become thin Adapters: they render, start .task(id:), clear stale @State for a path change, call the scheduler, and apply the returned commit result only if it still matches the current path.
- Leverage: focused tests can verify cache-hit/no-load/no-sleep, cache-miss priority, bounded scroll-settle waiting, cancellation, and path-tagging without UI automation. Existing ThumbnailPipelineTests still cover decode/cache behavior.
- Locality: the scheduler centralizes row thumbnail lifecycle rules while keeping visual state and visual differences local to the two views.

Exact proposed Interface shape and naming:

```swift
// Scopy/Views/History/HistoryRowThumbnailLifecycleScheduler.swift
@MainActor
struct HistoryRowThumbnailLifecycleScheduler {
    enum CommitSource {
        case cacheHit
        case loaded
    }

    struct CommitResult {
        let path: String
        let image: NSImage
        let source: CommitSource
    }

    struct Dependencies {
        var cachedImage: (String) -> NSImage?
        var loadImage: (String, TaskPriority) async -> NSImage?
        var isScrolling: () -> Bool
        var sleep: (UInt64) async -> Void
        var isCancelled: () -> Bool
    }

    init(interactionCoordinator: HistoryListInteractionCoordinator)
    init(dependencies: Dependencies)

    func cachedImage(for path: String) -> NSImage?
    func loadCommitResult(for path: String) async -> CommitResult?
}
```

Default dependencies should adapt to current production services:

```swift
Dependencies(
    cachedImage: { ThumbnailCache.shared.cachedImage(path: $0) },
    loadImage: { path, priority in
        await ThumbnailCache.shared.loadImage(path: path, priority: priority)
    },
    isScrolling: { interactionCoordinator.isScrolling },
    sleep: { nanoseconds in try? await Task.sleep(nanoseconds: nanoseconds) },
    isCancelled: { Task.isCancelled }
)
```

The scheduler should keep the current row semantics:

1. If cachedImage(path) exists, return CommitResult(path:image:source:.cacheHit) immediately.
2. Otherwise use .utility when isScrolling() is true and .userInitiated otherwise.
3. Await loadImage(path, priority).
4. Return nil if cancelled or no image.
5. For loaded cache misses, wait while isScrolling() for the existing bounded 20 x 80 ms settle loop.
6. Return nil if cancelled after waiting.
7. Return CommitResult(path:image:source:.loaded).

What remains in the SwiftUI views:

- @State loadedThumbnail and lastLoadedPath remain in HistoryItemThumbnailView and HistoryItemFileThumbnailView.
- Body rendering, image sizing, video overlay, placeholder icon, padding, and accessibilityIdentifier values remain in the views.
- .task(id: thumbnailPath) remains the trigger and SwiftUI cancellation boundary.
- On task start, the view still clears stale loadedThumbnail and updates lastLoadedPath when the path changed.
- The body may use scheduler.cachedImage(for:) ?? loaded to preserve immediate cached display while keeping direct ThumbnailCache access out of both views.
- After await scheduler.loadCommitResult(for: path), the view commits only when lastLoadedPath == result.path and the task is not cancelled.
- Preview fallback views remain out of scope, because they use .userInitiated immediate preview semantics and have file/QuickLook/video/markdown branches.
- IconService, ThumbnailCache internals, NSImage cache ownership, and decode metrics stay where they are.

Required focused tests:

- Add ScopyTests/HistoryRowThumbnailLifecycleSchedulerTests.swift.
- Cache hit: returns .cacheHit immediately, does not call loadImage, does not call sleep, and preserves the requested path in CommitResult.
- Cache miss while not scrolling: calls loadImage with .userInitiated and returns .loaded without scroll-settle sleep.
- Cache miss while scrolling: calls loadImage with .utility, runs the injected sleep loop until scrolling stops, then returns .loaded.
- Bounded wait: when scrolling never stops, the scheduler sleeps at most 20 times and still returns the loaded result if not cancelled, matching current behavior.
- Cancellation before load, after load, and during scroll-settle wait: returns nil and produces no commit result.
- Load miss: nil image from loadImage returns nil.
- Path tagging: CommitResult.path always equals the requested path so views can reject stale prior-path results after a path change.
- Existing ThumbnailPipelineTests should remain focused on ThumbnailCache load/cache/remove behavior, and HistoryListInteractionCoordinatorTests should remain focused on scroll lifecycle/cooldown behavior.

Perf/regression gates:

- Minimum for this scheduler extraction: make build, make test-unit, and make test-strict because MainActor async task/cancellation logic is touched.
- Focused unit subset: new HistoryRowThumbnailLifecycleSchedulerTests, ThumbnailPipelineTests, HistoryListInteractionCoordinatorTests, HistoryItemRowDescriptorTests, and ScrollPerformanceTests.
- Because row/list/thumbnail hot paths are touched, run make perf-frontend-profile at minimum.
- For commit-level confidence, run make perf-frontend-profile-standard and compare active_frame_p95_ms, main_runloop_active_p95_ms, swiftui.row_body_ms.p95, row.display_model_ms.p95, image.thumbnail_queue_wait_ms.p95, image.thumbnail_inflight_wait_ms.p95, image.thumbnail_imageio_decode_ms.p95, image.thumbnail_main_commit_ms.p95, and image.thumbnail_load_total_ms.p95.
- Do not claim a performance win unless before/after profile output shows preservation or improvement. This slice is primarily maintainability and testability.

Evidence that would change the answer:

- Implementation shows the async helper cannot be tested cleanly under Swift 5.9 strict concurrency without making dependencies unsafe or widening the Interface substantially.
- A pure policy plus a small executor eliminates more duplication while still testing the actual cache/load/wait/cancel sequence end-to-end.
- A check pass finds that keeping cached render checks in the views causes enough direct ThumbnailCache duplication that the scheduler should also own a displayImage(for:loadedPath:loadedImage:) facade.
- Fresh perf evidence shows the repeated scheduler sequence is irrelevant and actual ThumbnailCache decode/main-commit work or preview fallback lifecycle dominates the row/list regression.
- Product acceptance allows moving @State image ownership or visible thumbnail timing into a view model/coordinator, which would make a broader loader/coordinator design worth re-grilling.

No more design-question is needed before implementation. The next step should be a trellis-implement pass for the row-only async helper interface above, followed by trellis-check.

Files found:

- .trellis/tasks/05-06-architecture-improvement-discovery/prd.md:115 - Candidate 3 is the row asset and preview pipeline Module candidate.
- .trellis/tasks/05-06-architecture-improvement-discovery/implement.jsonl:1 - Implementation context starts from the frontend spec index.
- .trellis/tasks/05-06-architecture-improvement-discovery/implement.jsonl:4 - Implementation context includes hook/task ownership guidance for async row work.
- .trellis/tasks/05-06-architecture-improvement-discovery/implement.jsonl:7 - Implementation context includes frontend quality gates for row/list/thumbnail changes.
- .trellis/tasks/05-06-architecture-improvement-discovery/check.jsonl:3 - Check context verifies row behavior, cache boundaries, and accessibility identifiers.
- .trellis/tasks/05-06-architecture-improvement-discovery/check.jsonl:4 - Check context verifies async task ownership, cancellation, and scroll-settle behavior.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-row-asset-scope.md:9 - Prior research kept async thumbnail loading out of the first row descriptor slice.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-asset-loader-scope.md:9 - Prior research recommended a lifecycle scheduler before a broad asset-loader seam.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-asset-loader-scope.md:15 - Prior research named the lifecycle scheduler Module seam.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-scheduler-preview-scope.md:9 - Prior research scoped the first scheduler to visible row thumbnails only.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-scheduler-preview-scope.md:17 - Prior research says the row scheduler should own shared row scheduling, not preview fallback lifecycle.
- .trellis/spec/frontend/directory-structure.md:15 - History row, preview, markdown, hover, thumbnail, and list helper files belong under Scopy/Views/History.
- .trellis/spec/frontend/component-guidelines.md:17 - HistoryListView intentionally uses List recycling for large histories.
- .trellis/spec/frontend/component-guidelines.md:19 - History row preview/thumbnail/hover work is performance-sensitive and should stay behind caches/controllers/profile hooks.
- .trellis/spec/frontend/component-guidelines.md:48 - Views should not trigger thumbnail generation directly from body recomputation.
- .trellis/spec/frontend/hook-guidelines.md:21 - Long-running async work belongs in view models, services, or coordinators rather than repeated body expressions.
- .trellis/spec/frontend/hook-guidelines.md:23 - Tasks need cancellation and stale-result guards.
- .trellis/spec/frontend/state-management.md:11 - @ObservationIgnored is reserved for dependencies, tasks, handlers, and caches.
- .trellis/spec/frontend/type-safety.md:25 - UI mutation must remain on the main actor and service/task/cache state should not be observable UI state.
- .trellis/spec/frontend/quality-guidelines.md:29 - Scroll/render/thumbnail/preview performance changes require frontend profiling.
- .trellis/spec/guides/code-reuse-thinking-guide.md:37 - Copying nontrivial logic should trigger extraction to a shared place.
- Scopy/Views/History/HistoryItemThumbnailView.swift:11 - Image row thumbnail view owns loadedThumbnail and lastLoadedPath @State.
- Scopy/Views/History/HistoryItemThumbnailView.swift:30 - Image row thumbnail loading starts from .task(id: thumbnailPath).
- Scopy/Views/History/HistoryItemThumbnailView.swift:47 - Image row thumbnail loader is @MainActor.
- Scopy/Views/History/HistoryItemThumbnailView.swift:54 - Image row cache hits commit immediately.
- Scopy/Views/History/HistoryItemThumbnailView.swift:59 - Image row load priority depends on interactionCoordinator.isScrolling.
- Scopy/Views/History/HistoryItemThumbnailView.swift:63 - Image row cache-miss commits wait for scrolling to settle.
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:12 - File row thumbnail view owns parallel loadedThumbnail and lastLoadedPath @State.
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:32 - File row thumbnail loading starts from .task(id: thumbnailPath).
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:77 - File row thumbnail loader duplicates the image row path reset/cache/load flow.
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:89 - File row load priority also depends on interactionCoordinator.isScrolling.
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:93 - File row cache-miss commits also wait for scrolling to settle.
- Scopy/Views/History/HistoryListInteractionCoordinator.swift:14 - The interaction coordinator owns current scrolling state.
- ScopyUISupport/ThumbnailCache.swift:91 - ThumbnailCache is the existing @MainActor thumbnail cache Module.
- ScopyUISupport/ThumbnailCache.swift:119 - ThumbnailCache owns loadImage and cache-miss decode-to-NSImage behavior.
- ScopyUISupport/ThumbnailCache.swift:124 - ThumbnailCache records thumbnail decode/load timing metrics.
- ScopyTests/ThumbnailPipelineTests.swift:35 - Existing thumbnail tests cover ThumbnailCache remove/evict behavior, not row lifecycle scheduling.
- ScopyTests/HistoryListInteractionCoordinatorTests.swift:7 - Existing tests cover scroll lifecycle and cooldown.
- scripts/perf-frontend-profile.sh:186 - Frontend profile consumes row.display_model_ms.
- scripts/perf-frontend-profile.sh:194 - Frontend profile consumes thumbnail queue/decode/commit/load metrics.
- scripts/perf-frontend-profile.sh:502 - Frontend profile compares active_frame and main_runloop p95 values.
- scripts/perf-frontend-profile.sh:519 - Frontend profile compares thumbnail metric p95 values.
- doc/perf/release-profiles/v0.7.4-profile.md:47 - Prior profile notes thumbnail total latency is a scheduling/deferral signal.
- doc/perf/release-profiles/v0.7.5-profile.md:44 - Current row body/display/file-preview p95 values are already sub-millisecond in the standard profile.

Code patterns:

- The two row thumbnail views duplicate the same MainActor lifecycle sequence: path reset, cache hit commit, priority selection from scrolling, cache-miss load, cancellation guard, scroll-settle wait, cancellation guard, and @State commit.
- The body render path already avoids generation from body recomputation by only reading the memory cache and attaching .task when no visible cached/loaded image is available.
- ThumbnailCache is already the deep asset-loading Module: it has an in-flight decode coordinator, bounded concurrency, detached ImageIO decode, MainActor NSImage creation, cache storage, and performance metrics.
- HistoryListInteractionCoordinator is the existing row/list interaction Adapter for scroll state; the scheduler should read isScrolling rather than add a second scroll state source.
- Preview fallback thumbnail paths are related but semantically different because they always use .userInitiated and mix with popover preview, file existence, QuickLook, video size, and markdown routing.

External references:

- None. This research is based on repository code, Trellis specs, task research files, current local memory context for Scopy perf workflow, and existing local Scopy performance artifacts. No new Apple or third-party API is proposed.

Related specs:

- .trellis/spec/frontend/index.md
- .trellis/spec/frontend/directory-structure.md
- .trellis/spec/frontend/component-guidelines.md
- .trellis/spec/frontend/hook-guidelines.md
- .trellis/spec/frontend/state-management.md
- .trellis/spec/frontend/type-safety.md
- .trellis/spec/frontend/quality-guidelines.md
- .trellis/spec/guides/code-reuse-thinking-guide.md
- .trellis/tasks/05-06-architecture-improvement-discovery/implement.jsonl
- .trellis/tasks/05-06-architecture-improvement-discovery/check.jsonl
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-row-asset-scope.md
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-icon-scope.md
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-descriptor-placement.md
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-descriptor-metric-naming.md
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-asset-loader-scope.md
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-scheduler-preview-scope.md

## Caveats / Not Found

- I did not run tests or benchmarks in this research pass.
- I did not inspect generated Xcode project membership; implementation should verify the new scheduler and test files are included by the existing XcodeGen/build path.
- I did not find existing scheduler-specific tests for row thumbnail path reset, scroll-settle waiting, cancellation, or stale commit rejection.
- I did not find evidence that preview fallback thumbnails should join this first scheduler Interface.
- The proposed default dependencies use closure injection; strict-concurrency build results should be treated as the final arbiter for exact annotations.
