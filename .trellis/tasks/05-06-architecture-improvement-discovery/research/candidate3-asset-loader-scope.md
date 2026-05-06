# Research: Candidate 3 asset loader scope

- Query: For the next Candidate 3 slice after HistoryItemRowDescriptor, should we implement an actual row asset-loader seam for icons/thumbnails now, or first add/extract a testable thumbnail/icon lifecycle scheduler seam that preserves current loading in the SwiftUI row views?
- Scope: internal
- Date: 2026-05-07

## Findings

Recommended answer: first add/extract a testable thumbnail/icon lifecycle scheduler seam that preserves current loading in the SwiftUI row views. Do not implement an actual row asset-loader seam that owns NSImage loading, ThumbnailCache, IconService, or row preview image state in this slice.

The current descriptor slice already made the row-facing presentation Interface explicit: title, metadata, thumbnail layout flags, file preview fields, export capability, and appIconBundleID live in HistoryItemRowDescriptor. The remaining duplicated behavior is not primarily "how to decode/load an asset"; ThumbnailCache already owns cache lookup, bounded decode concurrency, in-flight dedupe, ImageIO decode, NSImage creation, and thumbnail metrics. The next duplication is the lifecycle policy around loading: path reset, cache-hit short-circuit, priority selection while scrolling, delayed commit until scroll settles, and cancellation/path-change guards. That policy appears in row thumbnail views and partly diverges in preview views.

Recommended architecture reading:

- Module: introduce a small thumbnail/icon lifecycle scheduler Module, not a broad row asset loader. The Module should make scheduling decisions and expose a testable plan/policy around cache hit, priority, scroll-settle wait, and commit eligibility.
- Interface: keep the Interface narrow and value/test friendly, for example ThumbnailLifecycleScheduler or RowThumbnailLifecyclePolicy with dependencies for current scroll state, cache lookup/load function, and sleep/clock hook in tests. It can return or drive a LoadResult/CommitDecision, but the SwiftUI view still stores @State NSImage.
- Implementation: retain ThumbnailCache and IconService as the asset-loading Implementations. The new Implementation extracts duplicated lifecycle logic currently embedded in HistoryItemThumbnailView and HistoryItemFileThumbnailView.
- Depth: extracting lifecycle policy is deeper than adding another pass-through loader because it hides the fragile timing/cancellation rules that currently must be duplicated exactly.
- Seam: the useful seam is between SwiftUI view lifecycle and asset services. A real asset-loader seam that owns images, services, and row state would cross too many boundaries at once.
- Adapter: SwiftUI thumbnail views should act as Adapters: .task(id:) starts work, @State holds loadedThumbnail/lastLoadedPath, and the scheduler/policy decides when/how to call ThumbnailCache and when commit is allowed.
- Leverage: tests can cover cache hit, cache miss priority, scroll-settle deferral, cancellation before commit, and path change without UI automation. The same seam later lets image and file thumbnail views share one lifecycle.
- Locality: this keeps current visible rendering and row state local to SwiftUI while moving the repeated scheduling contract to one place.

Files found:

- .trellis/tasks/05-06-architecture-improvement-discovery/prd.md:115 - Candidate 3 is row asset and preview pipeline work.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-row-asset-scope.md:9 - The first Candidate 3 slice was descriptor-only, not async thumbnail loading.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-icon-scope.md:9 - The descriptor should expose app icon request data and keep IconService lookup out of the descriptor.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-descriptor-placement.md:9 - The descriptor belongs in Scopy/Presentation and should not become a UI-support asset loader.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-descriptor-metric-naming.md:9 - row.display_model_ms continuity should remain intact.
- .trellis/spec/frontend/component-guidelines.md:17 - HistoryListView intentionally uses List with ScrollViewReader for recycling.
- .trellis/spec/frontend/component-guidelines.md:19 - History row preview/thumbnail/hover behavior should stay behind caches/controllers/profile hooks.
- .trellis/spec/frontend/component-guidelines.md:48 - Views should not trigger expensive thumbnail generation from body recomputation.
- .trellis/spec/frontend/hook-guidelines.md:19 - Long-running async work should be owned by a view model, service, or coordinator, not repeated body expressions.
- .trellis/spec/frontend/hook-guidelines.md:23 - Tasks need cancellation and stale-result guards.
- .trellis/spec/frontend/state-management.md:25 - History state and row-facing mutations must preserve existing async/list semantics.
- .trellis/spec/frontend/quality-guidelines.md:29 - Scroll/render/thumbnail/preview changes require frontend perf gates.
- .trellis/spec/guides/code-reuse-thinking-guide.md:65 - Repeated nontrivial logic should be abstracted when it appears multiple times.
- Scopy/Presentation/HistoryItemRowDescriptor.swift:7 - HistoryItemRowDescriptor is already a row presentation descriptor Module.
- Scopy/Presentation/HistoryItemRowDescriptor.swift:33 - appIconBundleID is request identity, not loaded NSImage.
- Scopy/Presentation/HistoryItemRowDescriptor.swift:40 - descriptor construction preserves row.display_model_ms.
- Scopy/Views/History/HistoryItemView.swift:530 - appIcon still resolves through IconService.shared from the row.
- Scopy/Views/History/HistoryItemView.swift:587 - image rows instantiate HistoryItemThumbnailView and pass the shared interaction coordinator.
- Scopy/Views/History/HistoryItemView.swift:600 - file rows instantiate HistoryItemFileThumbnailView with the same coordinator.
- Scopy/Views/History/HistoryItemView.swift:782 - HistoryItemView owns onAppear registration and UI-test tap-preview setup.
- Scopy/Views/History/HistoryItemView.swift:905 - HistoryItemView owns onDisappear cleanup for observers, hover tasks, preview state, export tasks, and note editor state.
- Scopy/Views/History/HistoryItemThumbnailView.swift:11 - image thumbnail view stores loadedThumbnail and lastLoadedPath in @State.
- Scopy/Views/History/HistoryItemThumbnailView.swift:30 - image thumbnail loading starts from SwiftUI .task(id: thumbnailPath).
- Scopy/Views/History/HistoryItemThumbnailView.swift:47 - image thumbnail lifecycle is @MainActor and resets state when path changes.
- Scopy/Views/History/HistoryItemThumbnailView.swift:54 - image thumbnail cache hit commits immediately.
- Scopy/Views/History/HistoryItemThumbnailView.swift:59 - image thumbnail priority depends on interactionCoordinator.isScrolling.
- Scopy/Views/History/HistoryItemThumbnailView.swift:63 - image thumbnail waits for scrolling to settle before committing.
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:12 - file thumbnail view has the same loadedThumbnail/lastLoadedPath state.
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:32 - file thumbnail loading also starts from SwiftUI .task(id: thumbnailPath).
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:77 - file thumbnail lifecycle duplicates the image thumbnail path reset/cache/load flow.
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:89 - file thumbnail priority also depends on interactionCoordinator.isScrolling.
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:93 - file thumbnail also waits for scrolling to settle before committing.
- Scopy/Views/History/HistoryItemImagePreviewView.swift:57 - image preview has a separate .task path for fallback thumbnail loading.
- Scopy/Views/History/HistoryItemFilePreviewView.swift:54 - file preview owns file existence/video-size task lifecycle.
- Scopy/Views/History/HistoryItemFilePreviewView.swift:84 - file preview separately loads thumbnail fallback.
- ScopyUISupport/ThumbnailCache.swift:9 - ThumbnailDecodeCoordinator already bounds decode concurrency and dedupes in-flight loads.
- ScopyUISupport/ThumbnailCache.swift:119 - ThumbnailCache.loadImage already performs cache miss decode, NSImage creation, cache store, and thumbnail metrics.
- ScopyUISupport/IconService.swift:26 - IconService is the existing MainActor icon lookup/cache Module.
- ScopyTests/HistoryItemRowDescriptorTests.swift:9 - descriptor has focused tests for injected dependencies, layout flags, appIconBundleID, file preview, and export fields.
- ScopyTests/ThumbnailPipelineTests.swift:35 - ThumbnailCache tests cover load/cache/remove, not row lifecycle scheduling.
- ScopyTests/HistoryListInteractionCoordinatorTests.swift:7 - scroll lifecycle/cooldown is tested independently.
- ScopyTests/HistoryItemPreviewCoordinatorTests.swift:69 - preview task cancellation helpers are tested, but thumbnail scheduler cancellation is not.
- ScopyTests/ScrollPerformanceTests.swift:208 - long-frame attribution includes row and thumbnail metric overlap.
- ScopyUITests/HistoryListUITests.swift:300 - frontend profile scenarios run through SCOPY_SCROLL_PROFILE and real/mock data sources.
- scripts/perf-frontend-profile.sh:507 - frontend profile compares row.display_model_ms p95.
- scripts/perf-frontend-profile.sh:518 - frontend profile compares thumbnail decode/queue/ImageIO/main-commit/load-total metrics.
- doc/perf/release-profiles/v0.7.4-profile.md:47 - thumbnail total latency should be read as scheduling/deferral signal, not direct proof of synchronous decode bottleneck.
- doc/perf/release-profiles/v0.7.4-profile.md:59 - remaining frame instability should be investigated as main-thread/system RunLoop or SwiftUI layout/diff/render work.
- doc/perf/release-profiles/v0.7.5-profile.md:44 - current row body/display/file preview p95 values are sub-millisecond in the standard profile.
- doc/perf/release-profiles/v0.7.5-profile.md:50 - future frontend work should keep reading main-thread and long-frame attribution, not only row buckets.

Code patterns:

- Descriptor pattern: HistoryItemRowDescriptor is a @MainActor value-like descriptor with injectable Dependencies and no NSImage state, Task handles, or scroll coordinator references (Scopy/Presentation/HistoryItemRowDescriptor.swift:7, Scopy/Presentation/HistoryItemRowDescriptor.swift:8, Scopy/Presentation/HistoryItemRowDescriptor.swift:22).
- Image and file thumbnails duplicate lifecycle logic almost line-for-line: cache check, path reset, priority from scrolling, ThumbnailCache.loadImage, wait for scroll settle, Task cancellation, then state commit (Scopy/Views/History/HistoryItemThumbnailView.swift:47, Scopy/Views/History/HistoryItemThumbnailView.swift:59, Scopy/Views/History/HistoryItemThumbnailView.swift:63, Scopy/Views/History/HistoryItemFileThumbnailView.swift:77, Scopy/Views/History/HistoryItemFileThumbnailView.swift:89, Scopy/Views/History/HistoryItemFileThumbnailView.swift:93).
- Preview thumbnail fallback is similar but not identical: preview views use .task and ThumbnailCache, but they do not currently use scroll-settle deferral and also include file existence/video/QuickLook behavior (Scopy/Views/History/HistoryItemImagePreviewView.swift:57, Scopy/Views/History/HistoryItemImagePreviewView.swift:87, Scopy/Views/History/HistoryItemFilePreviewView.swift:54, Scopy/Views/History/HistoryItemFilePreviewView.swift:222).
- The actual asset service seam already exists for thumbnails: ThumbnailCache is MainActor, delegates decode to ThumbnailDecodeCoordinator, and records queue/decode/commit/total metrics (ScopyUISupport/ThumbnailCache.swift:91, ScopyUISupport/ThumbnailCache.swift:119, ScopyUISupport/ThumbnailCache.swift:124).
- The actual icon service seam already exists for app icons: IconService caches NSImage and app names, with NSWorkspace fallback on cache miss (ScopyUISupport/IconService.swift:22, ScopyUISupport/IconService.swift:26, ScopyUISupport/IconService.swift:44).

Behavior that must remain in HistoryItemView/SwiftUI for this slice:

1. HistoryItemView continues to construct and own HistoryItemRowDescriptor in init.
2. HistoryItemView keeps app icon rendering and fallback Image(systemName:) behavior; it may call a scheduling/prefetch helper later, but this slice should not move icon NSImage state out of row rendering.
3. HistoryItemThumbnailView and HistoryItemFileThumbnailView keep @State loadedThumbnail and lastLoadedPath.
4. SwiftUI .task(id: thumbnailPath) remains the trigger and cancellation boundary for visible row thumbnail work.
5. The views still read ThumbnailCache.shared.cachedImage(path:) synchronously before showing placeholder/loading.
6. Path changes still clear stale loadedThumbnail before any new commit.
7. Cache hits still commit immediately without scroll-settle waiting.
8. Cache misses still use .utility priority while the interaction coordinator reports scrolling and .userInitiated otherwise.
9. Cache-miss commits still wait for the current scroll-settle behavior before assigning loadedThumbnail.
10. Cancellation checks remain before commit.
11. HistoryItemView keeps onAppear observer registration and onDisappear cleanup for preview/hover/export/note state.
12. Preview popover image/file views keep their existing preview/fallback thumbnail/file-existence lifecycle for this slice unless the next slice explicitly widens scope.

Minimal implementation slice if doing lifecycle scheduler first:

1. Add an internal scheduler/policy type near the thumbnail views, likely Scopy/Views/History/HistoryThumbnailLifecycleScheduler.swift. Keep it internal and testable; do not put NSImage ownership into HistoryItemRowDescriptor.
2. Model the row-thumbnail scheduling contract with injectable closures for cachedImage(path), loadImage(path, priority), isScrolling, and sleep. Use NSImage in the row-facing result only because ThumbnailCache already returns NSImage; do not add a new cache or loader.
3. Move the shared path reset/cache-hit/priority/load/scroll-settle/commit-eligibility logic out of HistoryItemThumbnailView and HistoryItemFileThumbnailView into the scheduler.
4. Have both row thumbnail views call the same scheduler from their existing .task(id: thumbnailPath), then assign @State loadedThumbnail only if the scheduler reports a commit for the current path and the task is not cancelled.
5. Keep HistoryItemImagePreviewView and HistoryItemFilePreviewView out of the first scheduler slice unless the extracted Interface naturally supports their no-scroll-settle fallback mode without behavior changes.
6. Keep IconService lookup in HistoryItemView for this slice. At most, document a future AppIconLifecycleScheduler/prefetch seam; do not mix it into the thumbnail scheduler unless profiling shows app icon misses dominate.

Focused tests for lifecycle scheduler first:

- Cache hit: returns/commits cached image immediately, does not call loadImage, and does not wait for scroll settle.
- Cache miss not scrolling: calls loadImage with .userInitiated and permits commit after load.
- Cache miss while scrolling: calls loadImage with .utility, waits using the existing 20 x 80ms settle policy or equivalent injected loop, and permits commit only after scrolling ends or the loop exits.
- Cancellation before/after load: does not permit commit after cancellation.
- Path change: stale loadedThumbnail is cleared and stale result for the previous path is not committed into the new path state.
- Shared behavior parity: image and file thumbnail views both route through the same scheduler and keep their distinct placeholder/overlay/accessibility identifiers.
- Regression: existing ThumbnailPipelineTests should continue to verify ThumbnailCache load/cache/remove behavior; do not replace them with scheduler tests.

Perf/regression gates:

- For scheduler-only row thumbnail extraction: run make build, make test-unit, and make test-strict because async/task scheduling and MainActor state are touched.
- Run focused new scheduler tests plus existing HistoryListInteractionCoordinatorTests, ThumbnailPipelineTests, HistoryItemRowDescriptorTests, and ScrollPerformanceTests.
- Because row/list/thumbnail hot paths are touched, run make perf-frontend-profile at minimum. For commit-level confidence, run make perf-frontend-profile-standard and compare active_frame_p95_ms, main_runloop_active_p95_ms, swiftui.row_body_ms.p95, row.display_model_ms.p95, image.thumbnail_queue_wait_ms.p95, image.thumbnail_imageio_decode_ms.p95, image.thumbnail_main_commit_ms.p95, and image.thumbnail_load_total_ms.p95.
- Do not claim a perf win unless before/after profiles show the scheduler slice improves or at least preserves frame and thumbnail buckets.
- If the slice changes preview popover fallback thumbnail behavior, add targeted HistoryListUITests coverage for preview display/dismissal and run relevant UI tests.
- If a future slice moves actual IconService/ThumbnailCache ownership or prefetches icons/thumbnails outside SwiftUI row tasks, require make perf-frontend-profile-standard and cancellation/path-reuse tests before merging.

Evidence that would change the answer:

- A fresh profile showing app icon cache misses or ThumbnailCache load/decode/main-commit buckets dominate long-frame time across real-snapshot scenarios, with row-level attribution tying the cost to actual asset loading rather than lifecycle scheduling or broader SwiftUI/List/RunLoop work.
- A concrete loader abstraction already exists in the codebase that can own ImageLoadRequest, NSImage state, cancellation, scroll-settle policy, and cache/commit semantics without widening HistoryItemView's Interface.
- Product acceptance that the slice may change visible thumbnail timing, prefetch timing, or icon fallback timing.
- Tests prove the scheduler seam would be mostly pass-through while an asset-loader seam removes more real duplication without changing behavior.
- A check agent finds that preview fallback thumbnails must be included immediately to avoid creating a third divergent lifecycle.

Next one-question grill prompt:

Should the lifecycle scheduler first slice be scoped only to visible row thumbnails (HistoryItemThumbnailView and HistoryItemFileThumbnailView), or should it also cover preview fallback thumbnails in HistoryItemImagePreviewView and HistoryItemFilePreviewView with a no-scroll-settle policy mode?

## Caveats / Not Found

- I did not run a new frontend profile or unit tests; this is a scope decision based on current source, existing research files, Trellis specs, and prior perf artifacts.
- I did not inspect generated Xcode project membership, so implementation should verify the new file is included by the project generation/build path.
- Current ThumbnailPipelineTests do not cover lifecycle scheduling; new scheduler tests would be needed before implementation confidence.
- The row icon path is still a real possible hotspot on cache miss, but current Candidate 3 research and existing IconService shape argue for a separate icon prefetch/scheduler decision after thumbnail lifecycle duplication is handled.
- Existing profile docs say row/render buckets explain only a small share of long frames, so this slice should be framed as maintainability and testability first, not a guaranteed performance win.

## External References

- None. This research is based on repository code, Trellis specs, task research files, existing Scopy perf artifacts, and memory-derived prior Scopy performance workflow notes.

## Related Specs

- .trellis/spec/frontend/index.md
- .trellis/spec/frontend/directory-structure.md
- .trellis/spec/frontend/component-guidelines.md
- .trellis/spec/frontend/hook-guidelines.md
- .trellis/spec/frontend/state-management.md
- .trellis/spec/frontend/type-safety.md
- .trellis/spec/frontend/quality-guidelines.md
- .trellis/spec/guides/code-reuse-thinking-guide.md

