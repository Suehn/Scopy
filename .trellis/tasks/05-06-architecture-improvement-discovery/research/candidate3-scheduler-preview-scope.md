# Research: Candidate 3 scheduler preview scope

- Query: Should the lifecycle scheduler first slice be scoped only to visible row thumbnails (HistoryItemThumbnailView and HistoryItemFileThumbnailView), or should it also cover preview fallback thumbnails in HistoryItemImagePreviewView and HistoryItemFilePreviewView with a no-scroll-settle policy mode?
- Scope: internal
- Date: 2026-05-07

## Findings

Recommended answer: scope the lifecycle scheduler first slice only to visible row thumbnails: `HistoryItemThumbnailView` and `HistoryItemFileThumbnailView`. Do not include preview fallback thumbnails in `HistoryItemImagePreviewView` or `HistoryItemFilePreviewView` in this first scheduler slice.

The row-thumbnail path has a tight duplicated contract: path reset, synchronous cache-hit check, load priority based on `HistoryListInteractionCoordinator.isScrolling`, `ThumbnailCache.loadImage`, delayed cache-miss commit until scroll settles, cancellation checks, and final `@State` image commit. Image rows and file rows duplicate this almost line-for-line. That is the right first Module seam.

Preview fallback thumbnails share `ThumbnailCache` and `.task(id: thumbnailPath)`, but they do not share the row scroll-settle policy today. Image preview prioritizes immediate popover display with `.userInitiated` load and commits as soon as the image is available. File preview also interleaves file existence checks, video natural-size loading, QuickLook/video preview choices, markdown preview routing, and fallback file-icon sizing. Adding a no-scroll-settle policy mode now would widen the Interface before the row scheduler contract is proven, and it would mix row list recycling behavior with popover preview behavior.

Architecture vocabulary reading:

- Module: create a row thumbnail lifecycle scheduler Module first. It should own the shared row scheduling contract, not the entire preview fallback pipeline.
- Interface: first Interface should be narrow: thumbnail path, cache lookup/load hooks, current scroll state, sleep/settle hook, cancellation/commit eligibility, and load priority. It should not require preview model, file path, file kind, QuickLook/video state, markdown controller, or preview sizing inputs.
- Implementation: preserve `ThumbnailCache` as the asset-loading Implementation. The new scheduler should extract duplicated view lifecycle policy from the two row thumbnail views while the SwiftUI views still own `@State loadedThumbnail` and `.task(id: thumbnailPath)`.
- Depth: row-only extraction hides a fragile repeated timing rule behind one testable Module. Including preview fallback immediately adds a mode flag but does not yet prove deeper behavior because preview semantics are different rather than duplicated exactly.
- Seam: the first seam is between visible row SwiftUI lifecycle and thumbnail cache loading. Preview fallback belongs to a second seam between popover preview lifecycle, `HoverPreviewModel`, file/QuickLook/video availability, and thumbnail fallback.
- Adapter: row thumbnail views should become thin Adapters from SwiftUI `.task` and `@State` into the scheduler. Preview views can later adapt to the same scheduler only if a preview policy can be expressed without changing popover behavior.
- Leverage: row-only tests can cover cache hit, priority, scroll-settle, cancellation, and path-change behavior directly. Preview inclusion would require broader UI/preview tests and makes the first scheduler harder to validate.
- Locality: row-only keeps list recycling and scroll policy local to history row thumbnails. Preview fallback remains local to preview views where its sizing, QuickLook, video, and markdown branches already live.

Exact implementation scope for this slice:

1. Add an internal row thumbnail lifecycle scheduler near the history thumbnail views, for example `Scopy/Views/History/HistoryThumbnailLifecycleScheduler.swift`.
2. Route only `HistoryItemThumbnailView.loadThumbnailIfNeeded(path:)` and `HistoryItemFileThumbnailView.loadThumbnailIfNeeded(path:)` through the scheduler.
3. Keep `loadedThumbnail`, `lastLoadedPath`, placeholders, overlays, accessibility identifiers, and `.task(id: thumbnailPath)` in the two SwiftUI row thumbnail views.
4. Keep cache hits immediate and skip scroll-settle waiting for cache hits.
5. Keep cache misses using `.utility` while `interactionCoordinator.isScrolling` is true and `.userInitiated` otherwise.
6. Keep the current 20 x 80 ms scroll-settle behavior, cancellation checks, and path-change/stale-result guards.
7. Do not modify `HistoryItemImagePreviewView` or `HistoryItemFilePreviewView` in this slice except if a compiler/API extraction requires a harmless shared type import.
8. Do not move `ThumbnailCache`, `NSImage` ownership, `IconService`, `HoverPreviewModel`, `MarkdownPreviewWebViewController`, QuickLook, video sizing, or file-existence checks into this scheduler.

Tests required:

- Add focused unit tests for the scheduler, ideally with injected cache/load/isScrolling/sleep hooks.
- Test cache hit commits immediately, avoids `loadImage`, and does not sleep.
- Test cache miss while not scrolling uses `.userInitiated` and permits commit after load.
- Test cache miss while scrolling uses `.utility`, waits through the settle hook, and commits only after scrolling ends or the bounded loop exits.
- Test cancellation before/after load prevents commit.
- Test path change clears stale state and prevents stale prior-path results from being committed.
- Keep existing `ThumbnailPipelineTests` as cache/decode coverage; do not replace them with scheduler tests.
- Run existing `HistoryListInteractionCoordinatorTests` because scroll state/cooldown remains the policy input.
- Run `HistoryItemPreviewCoordinatorTests` as a regression guard for preview task ownership if any preview file is touched.
- Run `ScrollPerformanceTests` because thumbnail metrics and long-frame attribution are part of the performance safety net.

Perf/regression gates:

- Minimum for row scheduler extraction: `make build`, `make test-unit`, and `make test-strict`.
- Focused tests to include: new scheduler tests, `ThumbnailPipelineTests`, `HistoryListInteractionCoordinatorTests`, `HistoryItemRowDescriptorTests`, and `ScrollPerformanceTests`.
- Because row/list/thumbnail hot paths are touched, run `make perf-frontend-profile` at minimum.
- For commit-level confidence, run `make perf-frontend-profile-standard` and compare `active_frame_p95_ms`, `main_runloop_active_p95_ms`, `swiftui.row_body_ms.p95`, `row.display_model_ms.p95`, `image.thumbnail_queue_wait_ms.p95`, `image.thumbnail_inflight_wait_ms.p95`, `image.thumbnail_imageio_decode_ms.p95`, `image.thumbnail_main_commit_ms.p95`, and `image.thumbnail_load_total_ms.p95`.
- Do not claim a performance win unless before/after profile output shows preservation or improvement. This slice is primarily maintainability/testability unless fresh profiles prove a measured gain.
- If preview fallback behavior is widened in a later slice, add targeted UI coverage for preview display and dismissal, including `History.Preview.Image` and `History.Preview.File`, and run relevant `HistoryListUITests`.

Evidence that would change the answer:

- A check pass proves row-only scheduler extraction creates a third divergent lifecycle that is harder to reason about than adding a no-scroll-settle preview mode immediately.
- A tiny policy Interface naturally covers row and preview without importing preview model/file/video/QuickLook/markdown concepts and without changing visible preview timing.
- Fresh profiles show preview fallback thumbnail loading materially contributes to long frames or preview latency in the same scenarios as row thumbnails.
- Product acceptance allows a visible preview timing change or a broader preview lifecycle refactor in this slice.
- Existing tests or a failed implementation show row-only tests cannot validate the scheduler without exercising preview fallback paths.

Next one-question grill prompt:

Should the row thumbnail lifecycle scheduler be implemented as a pure value-returning policy that the views apply to `@State`, or as an async helper method that owns cache lookup/load/wait and returns a commit result for the current path?

Files found:

- .trellis/tasks/05-06-architecture-improvement-discovery/prd.md:115 - Candidate 3 is the row asset and preview pipeline Module candidate.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-row-asset-scope.md:9 - Prior research limited the first Candidate 3 slice to a row-ready descriptor and deferred async thumbnail loading.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-icon-scope.md:9 - Prior research kept app icon loading outside the descriptor first slice.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-descriptor-placement.md:9 - Prior research placed the descriptor in `Scopy/Presentation` and kept async asset loading separate.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-descriptor-metric-naming.md:9 - Prior research preserved `row.display_model_ms` continuity for descriptor construction.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-asset-loader-scope.md:9 - Prior research recommended a lifecycle scheduler before a broad asset-loader seam.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-asset-loader-scope.md:80 - Prior research identified duplicated row thumbnail lifecycle logic.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-asset-loader-scope.md:81 - Prior research noted preview fallback is similar but not identical.
- .trellis/tasks/05-06-architecture-improvement-discovery/implement.jsonl:1 - Implement context starts from frontend specs for native row/list work.
- .trellis/tasks/05-06-architecture-improvement-discovery/check.jsonl:1 - Check context starts from frontend specs for native row/list verification.
- .trellis/spec/frontend/component-guidelines.md:17 - HistoryListView intentionally uses `List` with recycling for large histories.
- .trellis/spec/frontend/component-guidelines.md:19 - History row preview/thumbnail/hover work is performance-sensitive and should stay behind caches/controllers/profile hooks.
- .trellis/spec/frontend/component-guidelines.md:48 - Views should not trigger expensive thumbnail generation from body recomputation.
- .trellis/spec/frontend/hook-guidelines.md:21 - Long-running async work should be owned by a view model, service, or coordinator rather than repeated body expressions.
- .trellis/spec/frontend/hook-guidelines.md:23 - Tasks need cancellation and stale-result guards.
- .trellis/spec/frontend/state-management.md:25 - History state and list semantics must preserve existing async/list behavior.
- .trellis/spec/frontend/quality-guidelines.md:29 - Scroll/render/thumbnail/preview changes require frontend profiling.
- .trellis/spec/frontend/quality-guidelines.md:44 - UI performance claims need profiler output rather than subjective smoothness.
- .trellis/spec/guides/code-reuse-thinking-guide.md:65 - Nontrivial repeated logic should be abstracted when it appears multiple times.
- Scopy/Presentation/HistoryItemRowDescriptor.swift:7 - The current descriptor is a value-like `@MainActor` row presentation type.
- Scopy/Presentation/HistoryItemRowDescriptor.swift:33 - The descriptor exposes app icon request identity, not loaded image state.
- Scopy/Views/History/HistoryItemThumbnailView.swift:30 - Image row thumbnail loading is triggered by `.task(id: thumbnailPath)`.
- Scopy/Views/History/HistoryItemThumbnailView.swift:47 - Image row thumbnail lifecycle is `@MainActor`.
- Scopy/Views/History/HistoryItemThumbnailView.swift:54 - Image row thumbnail cache hits commit immediately.
- Scopy/Views/History/HistoryItemThumbnailView.swift:59 - Image row thumbnail priority depends on current scrolling state.
- Scopy/Views/History/HistoryItemThumbnailView.swift:63 - Image row thumbnail cache-miss commit waits for scrolling to settle.
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:32 - File row thumbnail loading is also triggered by `.task(id: thumbnailPath)`.
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:77 - File row thumbnail lifecycle duplicates the image row path reset/cache/load flow.
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:89 - File row thumbnail priority also depends on current scrolling state.
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:93 - File row thumbnail cache-miss commit also waits for scrolling to settle.
- Scopy/Views/History/HistoryItemImagePreviewView.swift:57 - Image preview fallback starts a thumbnail task from the preview content.
- Scopy/Views/History/HistoryItemImagePreviewView.swift:87 - Image preview fallback has its own `@MainActor` thumbnail loader.
- Scopy/Views/History/HistoryItemImagePreviewView.swift:99 - Image preview fallback always uses `.userInitiated` priority.
- Scopy/Views/History/HistoryItemFilePreviewView.swift:54 - File preview owns a separate file-exists/video-natural-size task.
- Scopy/Views/History/HistoryItemFilePreviewView.swift:84 - File preview fallback starts a thumbnail task from preview content.
- Scopy/Views/History/HistoryItemFilePreviewView.swift:222 - File preview fallback has its own `@MainActor` thumbnail loader.
- Scopy/Views/History/HistoryItemFilePreviewView.swift:234 - File preview fallback always uses `.userInitiated` priority.
- ScopyUISupport/ThumbnailCache.swift:91 - ThumbnailCache is the existing `@MainActor` thumbnail cache Module.
- ScopyUISupport/ThumbnailCache.swift:119 - ThumbnailCache owns image load/cache miss decode and NSImage creation.
- ScopyUISupport/ThumbnailCache.swift:124 - ThumbnailCache records queue/decode/commit/total thumbnail metrics.
- Scopy/Views/History/HistoryListInteractionCoordinator.swift:14 - The interaction coordinator owns current scrolling state.
- Scopy/Views/History/HistoryListInteractionCoordinator.swift:19 - The interaction coordinator also owns hover-preview suppression state.
- ScopyTests/ThumbnailPipelineTests.swift:35 - Existing thumbnail tests cover cache load/remove behavior, not lifecycle scheduling.
- ScopyTests/HistoryListInteractionCoordinatorTests.swift:7 - Existing tests cover scroll lifecycle and cooldown.
- ScopyTests/HistoryItemPreviewCoordinatorTests.swift:69 - Existing preview coordinator tests cover cancellation helpers for preview-owned tasks.
- ScopyTests/ScrollPerformanceTests.swift:208 - Existing performance tests cover long-frame attribution from row/thumbnail metric windows.
- ScopyUITests/HistoryListUITests.swift:257 - Existing UI tests can observe text/image preview display.
- ScopyUITests/HistoryListUITests.swift:290 - Existing UI tests verify preview dismissal on scroll.
- scripts/perf-frontend-profile.sh:186 - The frontend profile script consumes `row.display_model_ms`.
- scripts/perf-frontend-profile.sh:193 - The frontend profile script consumes thumbnail decode metrics.
- scripts/perf-frontend-profile.sh:518 - The frontend profile summary compares thumbnail p95 metrics.
- scripts/perf-unified-table.sh:218 - Unified perf tables expose thumbnail decode p95.
- doc/perf/release-profiles/v0.7.4-profile.md:47 - Prior release profile warns that thumbnail total latency is a scheduling/deferral signal.
- doc/perf/release-profiles/v0.7.5-profile.md:44 - Current release profile says row body/display/file-preview p95 values are sub-millisecond in standard profile.

Code patterns:

- The two row thumbnail views are structurally parallel: both store `loadedThumbnail` and `lastLoadedPath`, both synchronously check `ThumbnailCache.shared.cachedImage(path:)`, both load with priority derived from `interactionCoordinator.isScrolling`, both wait for scroll settling after a cache miss, and both commit into `@State`.
- The two preview fallback views are structurally related but semantically different from row thumbnails: they show popover content, always use `.userInitiated`, do not wait for scroll settling, and file preview combines thumbnail fallback with file availability, video sizing, QuickLook, markdown routing, and file icon fallback.
- `ThumbnailCache` is already the asset-loader Module for cache lookup, in-flight decode coordination, NSImage creation, cache store, and thumbnail metrics. The missing seam is lifecycle scheduling around row visibility and scroll state, not image decoding itself.
- Existing tests separate cache/decode behavior, scroll interaction behavior, preview task identity, and performance attribution. New scheduler tests should preserve that separation rather than turning preview UI tests into the only proof of row scheduling behavior.
- Existing perf scripts treat thumbnail queue/decode/main-commit/load-total metrics as stable observability keys; the scheduler slice should preserve those metric names and compare them before claiming improvement.

External references:

- None. This research is based on repository code, Trellis specs, task research files, and existing local Scopy performance artifacts. No new Apple or third-party API is proposed.

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

## Caveats / Not Found

- I did not run new tests or benchmarks in this research pass.
- I did not find existing scheduler-specific tests for row thumbnail path reset, scroll-settle, or stale result behavior; those tests need to be added with the implementation.
- I did not find evidence that preview fallback thumbnail loading currently uses or needs scroll-settle semantics.
- Including preview fallback later is still plausible if the first row scheduler Interface stays small and a no-scroll-settle policy can be added without importing preview-specific responsibilities.
- Existing release profile docs caution that thumbnail total latency can reflect scheduling/deferral rather than direct decode bottleneck, so fresh perf evidence is required before turning this maintainability slice into a performance claim.
