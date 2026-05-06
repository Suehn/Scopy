# Research: Candidate 3 hot path cache read

- Query: In Candidate 3 RowThumbnailLifecycleScheduler, row thumbnail body currently constructs HistoryRowThumbnailLifecycleScheduler(interactionCoordinator:) only to call cachedImage(for:) synchronously. Given standard frontend profile is noisy and not directly git-before/after, should we keep that instance construction, change body to call a static scheduler-owned production cache read, or revert to direct ThumbnailCache.shared.cachedImage in views?
- Scope: internal
- Date: 2026-05-07

## Findings

Recommended answer: change the row thumbnail bodies to call a static scheduler-owned production cache read. Do not keep per-body scheduler instance construction for synchronous cache reads, and do not revert the views back to direct ThumbnailCache.shared.cachedImage calls.

The current implementation creates a HistoryRowThumbnailLifecycleScheduler instance from the SwiftUI body only to read the cache. In HistoryItemThumbnailView.body, lines 14-20 unwrap the thumbnail path, compute the state fallback, construct HistoryRowThumbnailLifecycleScheduler(interactionCoordinator:), and immediately call scheduler.cachedImage(for:). HistoryItemFileThumbnailView.body repeats the same pattern at lines 15-20. The scheduler initializer creates production dependency closures for cachedImage, loadImage, isScrolling, sleep, and isCancelled at Scopy/Views/History/HistoryRowThumbnailLifecycleScheduler.swift:30-40, but the body cache-hit path uses only cachedImage at lines 48-50.

That means each body recomputation pays avoidable struct/dependency/closure setup for a cache read that does not depend on HistoryListInteractionCoordinator. The cost may be small and may not appear cleanly in the noisy standard frontend profile, but it is still the wrong shape for a row hot path. The frontend component spec explicitly treats history row thumbnail work as performance-sensitive and says row thumbnail lifecycle should route shared cache-hit/load-priority/scroll-settle/cancellation sequencing through HistoryRowThumbnailLifecycleScheduler, while body recomputation should not trigger expensive thumbnail behavior (.trellis/spec/frontend/component-guidelines.md:19, .trellis/spec/frontend/component-guidelines.md:21, .trellis/spec/frontend/component-guidelines.md:50).

The best implementation shape is to keep ThumbnailCache access scheduler-owned but make the production render-time cache read static, for example:

~~~swift
@MainActor
struct HistoryRowThumbnailLifecycleScheduler {
    static func productionCachedImage(for path: String) -> NSImage? {
        ThumbnailCache.shared.cachedImage(path: path)
    }

    func cachedImage(for path: String) -> NSImage? {
        dependencies.cachedImage(path)
    }

    func loadCommitResult(for path: String) async -> CommitResult? {
        ...
    }
}
~~~

Then the two row bodies can use HistoryRowThumbnailLifecycleScheduler.productionCachedImage(for: thumbnailPath) ?? loaded. The async load path should still construct an instance because loadCommitResult(for:) needs injected dependencies, the current scroll state from HistoryListInteractionCoordinator, sleep, and cancellation behavior.

I would avoid naming this static method in a way that suggests test-injected behavior. productionCachedImage(for:) or cachedProductionImage(for:) is clearer than overloading cachedImage(for:) with both static production and instance-injected forms. The existing instance cachedImage(for:) can remain as the dependency-backed facade for tests or future non-production adapters, although current tests mostly validate loadCommitResult(for:).

Do not revert to direct ThumbnailCache.shared.cachedImage in the views. That is marginally simpler at the call site, but it weakens the architecture decision already captured in the PRD and frontend specs: row thumbnail lifecycle stays behind HistoryRowThumbnailLifecycleScheduler, while the views remain SwiftUI adapters that own @State, placeholders, overlays, and final commit guards. ThumbnailCache already owns cache/decode/store metrics at ScopyUISupport/ThumbnailCache.swift:90-155; the scheduler owns row lifecycle orchestration and should remain the row-level cache facade.

This static cache read is not required to make the functional no-regression case for the scheduler extraction. Functional confidence comes from the scheduler tests for cache-hit no-load/no-sleep behavior, cache-miss priority, scroll-settle waiting, bounded wait, cancellation, nil load, and path tagging at ScopyTests/HistoryRowThumbnailLifecycleSchedulerTests.swift:8-212, plus existing ThumbnailPipelineTests for ThumbnailCache behavior. However, it is recommended before finalizing the slice because it removes an avoidable hot-path allocation/closure pattern introduced by the refactor. Treat it as no-regression risk reduction and architecture cleanup, not as a measured performance win.

The existing perf evidence should keep the claim modest. The PRD says the frontend perf smoke after the scheduler slice was a regression guard only and produced mixed/noisy metric deltas, with thumbnail total/decode worse in two scenarios and better in text-bias (.trellis/tasks/05-06-architecture-improvement-discovery/prd.md:617-626). The v0.7.5 release profile also says row construction/display-model work is already sub-millisecond and profile-level frame/drop counters remain noisy, so future frontend work should read main-thread and long-frame attribution rather than treating row-level buckets as the whole bottleneck (doc/perf/release-profiles/v0.7.5-profile.md:40-50). Prior memory notes point to the same workflow: use perf-frontend-profile/standard as guardrails and keep row-bucket claims evidence-based.

Files found:

- .trellis/tasks/05-06-architecture-improvement-discovery/prd.md:534 - Candidate 3 moved to RowThumbnailLifecycleScheduler after the row descriptor slice.
- .trellis/tasks/05-06-architecture-improvement-discovery/prd.md:572 - The chosen scheduler Interface owns cache lookup, cache-miss load, priority, scroll-settle, cancellation, and path-tagged commit results.
- .trellis/tasks/05-06-architecture-improvement-discovery/prd.md:617 - Focused scheduler tests passed in the implementation summary.
- .trellis/tasks/05-06-architecture-improvement-discovery/prd.md:622 - make perf-frontend-profile passed as a smoke/regression guard.
- .trellis/tasks/05-06-architecture-improvement-discovery/prd.md:626 - PRD explicitly warns not to claim a performance win because profile deltas were mixed/noisy.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-scheduler-interface.md:9 - Prior research chose an async helper that owns cache lookup/load/wait/cancellation and returns commit results.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-scheduler-interface.md:16 - Prior research proposed cachedImage(for:) as a small render-time cache facade.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-scheduler-interface.md:87 - Prior research allowed body to use scheduler.cachedImage(for:) ?? loaded to keep direct ThumbnailCache access out of views.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-scheduler-preview-scope.md:9 - Prior research scoped the first scheduler only to visible row thumbnails.
- .trellis/spec/frontend/directory-structure.md:32 - Row thumbnail lifecycle helpers that coordinate SwiftUI row tasks, scroll state, and ThumbnailCache belong near history thumbnail views.
- .trellis/spec/frontend/hook-guidelines.md:30 - Visible row thumbnail loading uses .task(id: thumbnailPath), view-owned @State, scheduler cache-hit/load-priority/scroll-settle/cancellation, and preview fallback remains separate.
- .trellis/spec/frontend/component-guidelines.md:19 - History row preview/thumbnail/hover work is performance-sensitive and should stay behind caches/controllers/profile hooks.
- .trellis/spec/frontend/component-guidelines.md:21 - Row presentation and thumbnail lifecycle are separate Modules; visible row thumbnail sequencing routes through HistoryRowThumbnailLifecycleScheduler.
- .trellis/spec/frontend/component-guidelines.md:50 - Views should not trigger thumbnail generation directly from body recomputation.
- .trellis/spec/frontend/component-guidelines.md:51 - Row thumbnail lifecycle helpers should not become broad asset loaders.
- .trellis/spec/frontend/quality-guidelines.md:29 - Scroll/render/thumbnail/preview changes require make perf-frontend-profile and stronger standard profiling for better evidence.
- .trellis/spec/frontend/quality-guidelines.md:44 - UI performance claims need profiler output, not subjective smoothness.
- Scopy/Views/History/HistoryRowThumbnailLifecycleScheduler.swift:5 - Scheduler is the internal @MainActor row thumbnail lifecycle Module.
- Scopy/Views/History/HistoryRowThumbnailLifecycleScheduler.swift:17 - Dependencies contain cachedImage, loadImage, isScrolling, sleep, and isCancelled closures.
- Scopy/Views/History/HistoryRowThumbnailLifecycleScheduler.swift:30 - Production init builds dependency closures from HistoryListInteractionCoordinator and ThumbnailCache.
- Scopy/Views/History/HistoryRowThumbnailLifecycleScheduler.swift:48 - Instance cachedImage(for:) only forwards dependencies.cachedImage(path).
- Scopy/Views/History/HistoryRowThumbnailLifecycleScheduler.swift:52 - loadCommitResult(for:) owns cache-hit, load, priority, wait, cancellation, and commit-result sequencing.
- Scopy/Views/History/HistoryItemThumbnailView.swift:13 - Image row thumbnail body is the hot render path under review.
- Scopy/Views/History/HistoryItemThumbnailView.swift:16 - Image row body constructs the scheduler for a synchronous cache read.
- Scopy/Views/History/HistoryItemThumbnailView.swift:19 - Image row body calls scheduler.cachedImage(for:) and falls back to loaded @State.
- Scopy/Views/History/HistoryItemThumbnailView.swift:56 - Image row async task still needs an instance scheduler for loadCommitResult(for:).
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:14 - File row thumbnail body is the second hot render path under review.
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:17 - File row body constructs the scheduler for a synchronous cache read.
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:20 - File row body calls scheduler.cachedImage(for:) and falls back to loaded @State.
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:86 - File row async task still needs an instance scheduler for loadCommitResult(for:).
- ScopyUISupport/ThumbnailCache.swift:90 - ThumbnailCache is the existing @MainActor in-memory thumbnail cache Module.
- ScopyUISupport/ThumbnailCache.swift:103 - ThumbnailCache.shared.cachedImage(path:) is the production cache read.
- ScopyUISupport/ThumbnailCache.swift:119 - ThumbnailCache.loadImage(path:priority:) owns cache miss loading and priority-aware decode coordination.
- ScopyTests/HistoryRowThumbnailLifecycleSchedulerTests.swift:8 - Scheduler tests cover cache-hit no-load/no-sleep behavior.
- ScopyTests/HistoryRowThumbnailLifecycleSchedulerTests.swift:32 - Scheduler tests cover non-scrolling cache-miss priority.
- ScopyTests/HistoryRowThumbnailLifecycleSchedulerTests.swift:56 - Scheduler tests cover scrolling cache-miss priority and wait behavior.
- ScopyTests/HistoryRowThumbnailLifecycleSchedulerTests.swift:83 - Scheduler tests cover bounded scroll-settle waiting.
- ScopyTests/HistoryRowThumbnailLifecycleSchedulerTests.swift:102 - Scheduler tests cover cancellation before load.
- ScopyTests/HistoryRowThumbnailLifecycleSchedulerTests.swift:123 - Scheduler tests cover cancellation after load.
- ScopyTests/HistoryRowThumbnailLifecycleSchedulerTests.swift:144 - Scheduler tests cover cancellation during wait.
- ScopyTests/HistoryRowThumbnailLifecycleSchedulerTests.swift:165 - Scheduler tests cover nil loads.
- ScopyTests/HistoryRowThumbnailLifecycleSchedulerTests.swift:180 - Scheduler tests cover path tagging.
- doc/perf/release-profiles/v0.7.5-profile.md:40 - Standard frontend profile summary path and current frontend guardrail context.
- doc/perf/release-profiles/v0.7.5-profile.md:44 - Row body/display model p95 values are sub-millisecond in the current release profile.
- doc/perf/release-profiles/v0.7.5-profile.md:50 - Profile-level frame/drop counters are noisy and row-level buckets are not the whole bottleneck.
- scripts/perf-frontend-profile.sh:185 - Frontend profile consumes row, SwiftUI, text, and thumbnail metric buckets.
- scripts/perf-frontend-profile.sh:518 - Frontend summary compares thumbnail decode/queue/imageio/main-commit/load-total p95 metrics.
- project.yml:55 - App target sources include the Scopy directory, so the scheduler file under Scopy/Views/History is in the app target by source path.

Code patterns:

- The current body cache-read path does not need interactionCoordinator. Both row thumbnail bodies construct the scheduler solely to reach dependencies.cachedImage, while scroll state and task cancellation are only needed by loadCommitResult(for:).
- The scheduler is still the right architectural owner for row-level cache facade behavior. Direct ThumbnailCache calls in the views would reintroduce the cross-module reach the scheduler was meant to remove.
- A static production cache read keeps the facade without the per-body production dependency closure setup. The async instance remains the testable unit for cache-hit/load-priority/scroll-settle/cancellation behavior.
- The static method should be production-only and simple. Keep dependency injection in the instance initializer so tests can continue to avoid shared ThumbnailCache except for an optional focused facade test.
- This cleanup preserves the current SwiftUI state split: loadedThumbnail and lastLoadedPath remain view @State, .task(id: thumbnailPath) remains the cancellation boundary, and the final commit guard remains in the views.

Performance/correctness tradeoffs:

- Keep current instance construction: highest architectural purity by using only the instance facade, but it adds avoidable work in a body hot path and creates dependencies that the cache-hit body read does not use.
- Static scheduler-owned production cache read: best tradeoff. It preserves the scheduler boundary, avoids direct view-to-ThumbnailCache coupling, and removes unnecessary body-time dependency construction.
- Direct ThumbnailCache.shared.cachedImage in views: lowest call overhead and simplest source line, but it conflicts with the row scheduler seam and makes the views know production cache ownership again.

No-regression confidence:

- The static cache read is not a substitute for the existing scheduler tests, build, unit, strict, and frontend perf guard. It is a small source-level risk reduction after the refactor.
- Because the available standard frontend profile is noisy and not a clean git-before/after comparison, do not use this change to claim a measured performance improvement.
- A no-regression claim should say: behavior remains the same because the same ThumbnailCache.shared.cachedImage(path:) is called on the MainActor, only through a static scheduler facade; async load/scroll/cancellation semantics remain in loadCommitResult(for:) and are already covered by focused tests.

Recommended implementation shape:

1. Add a @MainActor static production cache facade on HistoryRowThumbnailLifecycleScheduler, preferably named productionCachedImage(for:) to avoid confusing it with dependency-injected instance behavior.
2. Replace the two body-local scheduler constructions in HistoryItemThumbnailView and HistoryItemFileThumbnailView with HistoryRowThumbnailLifecycleScheduler.productionCachedImage(for: thumbnailPath) ?? loaded.
3. Keep instance cachedImage(for:) only if it remains useful for dependency-injected tests or future adapters; otherwise remove it with a focused compile/test pass.
4. Keep loadThumbnailIfNeeded(path:) constructing an instance scheduler for loadCommitResult(for:) because that path needs interactionCoordinator, sleep, cancellation, and injected dependencies.
5. Do not touch preview fallback views, ThumbnailCache internals, IconService, QuickLook/video sizing, file existence checks, accessibility identifiers, or performance metric names in this cleanup.

Tests and verification needed:

- Add or update a focused scheduler test for the static production cache facade only if the project wants executable proof of the facade. The test can clear ThumbnailCache.shared, store a tiny NSImage for a path, assert HistoryRowThumbnailLifecycleScheduler.productionCachedImage(for:) returns that image, then clear the cache.
- Keep and rerun HistoryRowThumbnailLifecycleSchedulerTests because they are the main proof that the scheduler still preserves cache-hit/load/wait/cancel/path semantics.
- Rerun ThumbnailPipelineTests to preserve ThumbnailCache behavior.
- Rerun HistoryListInteractionCoordinatorTests because load priority and scroll-settle depend on isScrolling.
- Rerun ScrollPerformanceTests and make perf-frontend-profile as a regression guard for row/list/thumbnail hot paths.
- For commit-level confidence, use make build, make test-unit, make test-strict, and make perf-frontend-profile-standard. Compare active_frame_p95_ms, main_runloop_active_p95_ms, swiftui.row_body_ms.p95, row.display_model_ms.p95, image.thumbnail_queue_wait_ms.p95, image.thumbnail_imageio_decode_ms.p95, image.thumbnail_main_commit_ms.p95, and image.thumbnail_load_total_ms.p95.

External references:

- None. This research is based on repository code, Trellis specs, task research files, local perf artifacts, and memory-derived prior Scopy perf workflow notes. No new Apple or third-party API is proposed.

Related specs:

- .trellis/spec/frontend/index.md
- .trellis/spec/frontend/directory-structure.md
- .trellis/spec/frontend/component-guidelines.md
- .trellis/spec/frontend/hook-guidelines.md
- .trellis/spec/frontend/state-management.md
- .trellis/spec/frontend/quality-guidelines.md
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-scheduler-interface.md
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-scheduler-preview-scope.md

## Caveats / Not Found

- I did not run tests or benchmarks in this research pass.
- I did not find fresh evidence that the current body-local scheduler construction is a measured regression by itself.
- I did not inspect SIL/assembly or Instruments allocation traces; the hot-path concern is source-level allocation/closure churn, not a quantified allocation count.
- The static production cache read should not be framed as a performance win unless a clean before/after profile or allocation trace shows measurable improvement.
- If Swift rejects a static and instance method with the same base name in this type, use an explicit static name such as productionCachedImage(for:) and keep the instance dependency-backed cachedImage(for:) unchanged.
