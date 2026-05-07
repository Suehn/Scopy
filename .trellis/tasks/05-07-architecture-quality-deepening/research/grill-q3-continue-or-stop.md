# Research: grill Q3 continue or stop

- Query: Should the architecture-quality task continue by implementing HistoryHoverPreviewPipeline now, implement a smaller hover-specific evidence/profile slice first, or stop as complete with the hover pipeline deferred?
- Scope: internal
- Date: 2026-05-07

## Findings

### Recommended Q3 Answer

Continue the task, but do not implement the full `HistoryHoverPreviewPipeline` Module yet. The recommended next step is a smaller hover-specific evidence/profile slice that proves the current profile Seam can exercise hover preview behavior and produce stable before/after evidence.

This task should not stop as complete if the user's current intent is to continue architecture-quality improvement. The two implemented slices are complete, but the PRD goal says remaining improvement candidates must be implemented, rejected with evidence, or explicitly marked out of scope (.trellis/tasks/05-07-architecture-quality-deepening/prd.md:5). The completion audit already says `HistoryHoverPreviewPipeline` is not rejected and should be next only after hover-specific profiling or focused preview behavior evidence is strong enough (.trellis/tasks/05-07-architecture-quality-deepening/prd.md:114).

The direct pipeline refactor has strong architecture value, but current evidence is insufficient for a safe implementation. The smaller evidence/profile slice gives the parent agent a better Seam before touching the fragile preview Implementation.

### Files Found

- `.trellis/tasks/05-07-architecture-quality-deepening/prd.md` - Current task source of truth; it records implemented slices, passed gates, and residual candidate status (.trellis/tasks/05-07-architecture-quality-deepening/prd.md:84).
- `.trellis/tasks/05-07-architecture-quality-deepening/info.md` - Technical design and verification notes for the Verification Evidence Manifest Module and Storage DeletePlan executor (.trellis/tasks/05-07-architecture-quality-deepening/info.md:1, .trellis/tasks/05-07-architecture-quality-deepening/info.md:76).
- `.trellis/tasks/05-07-architecture-quality-deepening/research/frontend-hot-paths.md` - Existing frontend candidate research; it ranks `HistoryHoverPreviewPipeline` first but requires UI/profile gates (.trellis/tasks/05-07-architecture-quality-deepening/research/frontend-hot-paths.md:52, .trellis/tasks/05-07-architecture-quality-deepening/research/frontend-hot-paths.md:66).
- `Scopy/Views/History/HistoryItemView.swift` - Current large row Module that owns hover dispatch, image/file/text preview tasks, markdown metric normalization, popover dismissal, and task cleanup (Scopy/Views/History/HistoryItemView.swift:58, Scopy/Views/History/HistoryItemView.swift:932, Scopy/Views/History/HistoryItemView.swift:1037, Scopy/Views/History/HistoryItemView.swift:1119, Scopy/Views/History/HistoryItemView.swift:1483).
- `Scopy/Views/HistoryListView.swift` - List Module that owns the shared Markdown WebView, one-active-popover state, row construction, and popover presentation timing (Scopy/Views/HistoryListView.swift:33, Scopy/Views/HistoryListView.swift:37, Scopy/Views/HistoryListView.swift:222, Scopy/Views/HistoryListView.swift:283).
- `Scopy/Views/History/HistoryItemPreviewCoordinator.swift` - Existing preview coordinator; its Interface mainly covers tokens and task cancellation, not preview loading behavior (Scopy/Views/History/HistoryItemPreviewCoordinator.swift:5, Scopy/Views/History/HistoryItemPreviewCoordinator.swift:13, Scopy/Views/History/HistoryItemPreviewCoordinator.swift:22, Scopy/Views/History/HistoryItemPreviewCoordinator.swift:91).
- `Scopy/Views/History/HoverPreviewLoader.swift` - Focused image decode/downsample Adapter with existing hover decode metric emission (Scopy/Views/History/HoverPreviewLoader.swift:5, Scopy/Views/History/HoverPreviewLoader.swift:31).
- `Scopy/Views/History/HoverPreviewImageCache.swift` - Main-actor hover image cache with TTL and size bounds (Scopy/Views/History/HoverPreviewImageCache.swift:5, Scopy/Views/History/HoverPreviewImageCache.swift:22, Scopy/Views/History/HoverPreviewImageCache.swift:58).
- `Scopy/Views/History/MarkdownPreviewCache.swift` - Markdown HTML/metrics/file-preview cache; it stores data but does not own the stable-size policy (Scopy/Views/History/MarkdownPreviewCache.swift:6, Scopy/Views/History/MarkdownPreviewCache.swift:17, Scopy/Views/History/MarkdownPreviewCache.swift:48, Scopy/Views/History/MarkdownPreviewCache.swift:65).
- `ScopyUITests/HistoryListUITests.swift` - Existing UI test file; hover dismissal is covered with mock data and tap-to-open, while profile scenarios are scroll-focused (ScopyUITests/HistoryListUITests.swift:232, ScopyUITests/HistoryListUITests.swift:300).
- `scripts/perf-frontend-profile.sh` - Current frontend profile harness; it runs three scroll scenarios and summarizes hover metric buckets if samples exist (scripts/perf-frontend-profile.sh:21, scripts/perf-frontend-profile.sh:198).
- `ScopyUISupport/ScrollPerformanceProfile.swift` - Profile Module that records named metric buckets and long-frame attribution under `SCOPY_SCROLL_PROFILE` (ScopyUISupport/ScrollPerformanceProfile.swift:7, ScopyUISupport/ScrollPerformanceProfile.swift:218, ScopyUISupport/ScrollPerformanceProfile.swift:238).

### Code Patterns

The deletion test supports the `HistoryHoverPreviewPipeline` candidate. If `HistoryItemView` deleted its preview Implementation today, the complexity would reappear across callers: hover delay, cache keys, storage/data image load, ImageIO/QuickLook/video paths, Markdown detection/render/cache, stable metric normalization, cancellation guard points, and popover requests are all caller-visible facts in practice (Scopy/Views/History/HistoryItemView.swift:1037, Scopy/Views/History/HistoryItemView.swift:1119, Scopy/Views/History/HistoryItemView.swift:1483). A deeper Module could move those facts behind a smaller Interface and improve Locality for future preview bugs.

The current preview coordinator is shallow for this purpose. Its Interface exposes token and task lifecycle helpers, but the real preview loading Implementation remains in the row view (Scopy/Views/History/HistoryItemPreviewCoordinator.swift:22, Scopy/Views/History/HistoryItemPreviewCoordinator.swift:91). That means tests can verify task cancellation bookkeeping, but not the image/file/text/markdown preview path through one Interface (ScopyTests/HistoryItemPreviewCoordinatorTests.swift:7).

The profile Seam is not yet hover-specific. The profile script knows about `hover.markdown_render_ms` and `hover.preview_image_decode_ms` buckets (scripts/perf-frontend-profile.sh:198), and the profile Module can record any named metric while enabled (ScopyUISupport/ScrollPerformanceProfile.swift:218). However, the harness currently executes `testScrollProfileRealSnapshotAccessibility`, `testScrollProfileRealSnapshotMixed`, and `testScrollProfileRealSnapshotTextBias` (scripts/perf-frontend-profile.sh:21), and the shared profile helper only scrolls or waits during the sample window (ScopyUITests/HistoryListUITests.swift:369). It does not intentionally open hover previews during a measured real-snapshot scenario.

The existing hover UI test is a behavior gate, not a performance/evidence gate. It uses mock data, sets `SCOPY_MOCK_IMAGE_PREVIEW_DELAY=0`, enables `SCOPY_UITEST_OPEN_PREVIEW_ON_TAP`, opens a preview by clicking rows, and verifies dismissal on scroll (ScopyUITests/HistoryListUITests.swift:232, ScopyUITests/HistoryListUITests.swift:239, ScopyUITests/HistoryListUITests.swift:290). This is valuable for regression coverage after a pipeline refactor, but it does not provide realistic hover latency or profile bucket evidence.

The smaller next slice should deepen the evidence Module before deepening the product Module. A good minimal Interface would be: run one opt-in hover-preview profile scenario, produce JSON with frame/main-runloop metrics plus non-empty hover buckets or explicit missing-bucket diagnostics, and summarize it through the existing quality manifest Adapter. That gives Leverage because the later `HistoryHoverPreviewPipeline` Implementation can be judged through the same profile/test surface instead of subjective UI inspection.

### Recommended Smallest Next Slice

Implement a hover-specific evidence/profile slice, not the full pipeline:

1. Add or extend an opt-in UI profile scenario that opens representative text, image, and file previews under controlled conditions while `SCOPY_SCROLL_PROFILE=1` is active.
2. Make the scenario prove whether `hover.markdown_render_ms` and `hover.preview_image_decode_ms` samples are present when the relevant content appears; missing samples should be explicit evidence, not silently treated as zero.
3. Prefer real-snapshot mode when available; a mock-only path is acceptable only as a smoke Adapter and must not be used to claim realistic performance.
4. Feed the resulting profile artifacts into the existing Verification Evidence Manifest Module or at least record exact artifact paths in `info.md` before the product refactor starts.
5. After that evidence exists, re-run Q3 or proceed to the pipeline only if the hover profile shows a meaningful, testable risk surface and the behavior gates are stable.

This slice has better Locality than jumping straight to the pipeline: it changes the proof surface first, then lets the pipeline refactor use that surface. It also avoids creating a broad `HistoryHoverPreviewPipeline` Interface before the team knows which hover paths are actually measurable and risky.

### Required Verification

For the hover-specific evidence/profile slice:

- `make build`.
- `make test-unit`.
- `make test-strict`.
- Focused existing behavior gate: `xcodebuild test -project Scopy.xcodeproj -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyUITests/HistoryListUITests/testHoverPreviewDismissesOnScroll`.
- New or updated focused hover profile gate, enabled through the existing profile environment, that emits a JSON artifact and validates non-empty relevant hover buckets or explicit not-found diagnostics.
- `make perf-frontend-profile` as the existing scroll/list regression guard; use `make perf-frontend-profile-standard` before claiming broader frontend confidence.
- Record final results through `scripts/quality/record-gate-result.py` if this task continues using the manifest workflow.

For the later full `HistoryHoverPreviewPipeline` Module:

- Add unit tests across the pipeline Interface for image cache hit/miss, file image/video/QuickLook branch selection, markdown file stale-cache fallback, text markdown detection/cache use, cancellation before commit, and metric emission through injected Adapters.
- Keep the existing hover dismissal UI gate.
- Run build/unit/strict plus the hover-specific profile and at least the smoke frontend profile. Use the standard profile before any performance claim.

### External References

No external web references were needed. The current repo baselines are macOS 14.0 and Swift 5.9 from `project.yml` and `Package.swift` (project.yml:31, Package.swift:1, Package.swift:7). No new Apple API signatures are involved in this research decision.

Prior memory was used only as a pointer to existing frontend profile fields and the caution that app-level row/render buckets have previously explained only a small fraction of total long-frame time. That pointer was verified against current profile code and docs in this pass.

### Related Specs

- Frontend quality requires preview performance changes to run `make perf-frontend-profile`, with `make perf-frontend-profile-standard` for stronger evidence (.trellis/spec/frontend/quality-guidelines.md:29).
- Frontend quality says performance improvements must be backed by profiler output and should watch markdown rendering, WebView lifecycle, QuickLook, thumbnails, and row recomputation (.trellis/spec/frontend/quality-guidelines.md:44).
- Frontend component guidance says expensive preview, markdown, thumbnail, and hover behavior should stay behind caches/controllers/profile hooks (.trellis/spec/frontend/component-guidelines.md:19).
- Hook guidance requires long-running async work to be owned by view models, services, or coordinators, with cancellation and stale-result guards before applying state (.trellis/spec/frontend/hook-guidelines.md:19).
- Product spec requires hover previews for text, images, and files, and requires heavy preview preparation to stay off the main thread while remaining usable on realistic snapshot DBs (doc/current/product-spec.md:57, doc/current/product-spec.md:114).
- Architecture docs require preview/export flows to treat stored content as source-of-truth input and keep heavy work backgrounded and bounded (doc/current/architecture.md:41, doc/current/architecture.md:47).

## Caveats / Not Found

- I did not run tests or profiles for this research pass; this file records a design decision recommendation based on static inspection and existing task evidence.
- I did not edit product code, tests, scripts, specs, or release docs. The only write was this research file under the task directory.
- I did not find an existing real-snapshot hover-specific profile scenario. Current profile infrastructure can summarize hover metrics, but the shipped harness does not intentionally exercise hover preview during profile sampling.
- If the parent chooses to stop the task now, it should explicitly mark `HistoryHoverPreviewPipeline` out of scope or deferred in task docs. Without that decision, stopping conflicts with the PRD's "implemented, rejected with evidence, or explicitly out of scope" completion rule.
