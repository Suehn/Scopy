# Research: Candidate 3 row asset scope

- Query: For Candidate 3, should the first behavior-preserving slice only produce a row-ready presentation/asset descriptor Module, or should it also move thumbnail async loading plus scroll-settle budget into that Module immediately?
- Scope: internal
- Date: 2026-05-07

## Findings

Recommended answer: the first slice should produce a row-ready presentation/asset descriptor Module only. It should not move thumbnail async loading or scroll-settle budget into that Module immediately.

The descriptor slice should deepen the existing presentation layer by moving row-ready derivation behind a small internal Interface: title text, metadata text, thumbnail height/show flags, file preview path/kind/markdown flag, PNG export capability, whether row thumbnail height is needed, and optional app icon request data. The Implementation can initially delegate to existing caches and helpers, especially HistoryItemPresentationCache and ClipboardItemDisplayText, while preserving the existing HistoryItemView Interface and visible behavior.

Do not include thumbnail async loading, decoded NSImage state, or scroll-settle waiting in the first descriptor Module. Those are active lifecycle and scheduling concerns, not pure row presentation data. Moving them at the same time would blend two seams: a value-like presentation/asset descriptor Module and an async thumbnail scheduler/loader Module. That would reduce Locality rather than improve it because the first version would need to own SwiftUI .task identity, cancellation, MainActor image commits, scroll priority, and delayed commits while still keeping HistoryItemView state and interaction semantics intact.

Architecture vocabulary reading:

- Module: first create a row descriptor Module with a narrow value Interface; leave thumbnail loading as a separate future Module.
- Interface: descriptor inputs should be ClipboardItemDTO plus SettingsDTO and existing services/caches; outputs should be row-ready fields, not NSImage loading state or Task handles.
- Implementation: existing Implementation already has presentation caches, prewarm tasks, thumbnail decode coordination, and scroll suppression. The first slice should rearrange derivation ownership before moving active scheduling.
- Depth: descriptor first is deeper than file splitting because it hides derivation rules and cache lookup shape behind one row-facing contract. Pulling async loading in immediately makes the contract wide and shallow.
- Seam: row descriptor is a stable seam between HistoryItemView and Presentation/ScopyUISupport. Thumbnail async loading is a second seam between view lifecycle, ThumbnailCache, and HistoryListInteractionCoordinator.
- Adapter: the descriptor can act as an Adapter over HistoryItemPresentationCache, ClipboardItemDisplayText, FilePreviewSupport, SettingsDTO, and item fields. A later thumbnail Adapter can own ImageLoadRequest, priority, settle policy, and cache/commit behavior.
- Leverage: descriptor tests can be focused and cheap; async thumbnail movement needs UI/perf evidence and cancellation coverage.
- Locality: keeping descriptor pure preserves Locality of presentation derivation without disturbing scroll interaction lifecycle. Moving thumbnail loading now would spread scroll policy between the new Module, ThumbnailCache, HistoryItemThumbnailView, HistoryItemFileThumbnailView, and preview views.

Files found:

- .trellis/tasks/05-06-architecture-improvement-discovery/prd.md:115 - Candidate 3 is defined as a row asset and preview pipeline Module candidate.
- .trellis/tasks/05-06-architecture-improvement-discovery/prd.md:127 - The PRD says presentation cache, preview budget, icon loading, and thumbnail decode already exist, but the row still reaches into multiple services.
- .trellis/tasks/05-06-architecture-improvement-discovery/prd.md:131 - The PRD frames Candidate 3 as a later row asset preparation Module that batches icon/thumbnail/presentation data before row render.
- .trellis/spec/frontend/component-guidelines.md:17 - HistoryListView intentionally uses List with ScrollViewReader for recycling.
- .trellis/spec/frontend/component-guidelines.md:19 - History rows are performance-sensitive and expensive preview/thumbnail/hover work should stay behind caches/controllers/profile hooks.
- .trellis/spec/frontend/component-guidelines.md:48 - Views should not trigger file IO, search, markdown rendering, or thumbnail generation directly from body recomputation.
- .trellis/spec/frontend/hook-guidelines.md:19 - Long-running async work should be owned by a view model, service, or coordinator, not by repeated body expressions.
- .trellis/spec/frontend/quality-guidelines.md:29 - Scroll/render/thumbnail/preview performance changes require make perf-frontend-profile, with standard profile for stronger evidence.
- Scopy/Views/History/HistoryItemView.swift:12 - HistoryItemDisplayModel currently derives row-ready title, metadata, preview flags, thumbnail height, and export capability.
- Scopy/Views/History/HistoryItemView.swift:39 - The display model reaches into HistoryItemPresentationCache.
- Scopy/Views/History/HistoryItemView.swift:47 - The display model reaches into ClipboardItemDisplayText.
- Scopy/Views/History/HistoryItemView.swift:63 - PreviewTaskBudget exists as a separate actor limiting preview work.
- Scopy/Views/History/HistoryItemView.swift:580 - appIcon still synchronously calls IconService.shared.icon from the row.
- Scopy/Views/History/HistoryItemView.swift:633 - row content branches on item type and descriptor-like flags.
- Scopy/Views/History/HistoryItemView.swift:707 - row body is already instrumented with swiftui.row_body_ms.
- Scopy/Views/History/HistoryItemView.swift:780 - row layout uses needsThumbnailHeight from the display model.
- Scopy/Views/History/HistoryItemView.swift:1373 - rows register an interaction observer against HistoryListInteractionCoordinator.
- Scopy/Views/History/HistoryItemView.swift:1385 - scroll and pointer events mutate row interaction state and preview lifecycle.
- Scopy/Views/History/HistoryItemThumbnailView.swift:30 - image row thumbnail loading is owned by a SwiftUI .task keyed by thumbnailPath.
- Scopy/Views/History/HistoryItemThumbnailView.swift:59 - thumbnail load priority depends on interactionCoordinator.isScrolling.
- Scopy/Views/History/HistoryItemThumbnailView.swift:68 - image row thumbnail commit waits for scrolling to settle.
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:32 - file row thumbnail loading has a parallel .task path.
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:89 - file thumbnail load priority also depends on scrolling state.
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:98 - file thumbnail commit has a duplicate scroll-settle loop.
- Scopy/Views/History/HistoryItemImagePreviewView.swift:57 - image preview thumbnail loading is view-owned by .task.
- Scopy/Views/History/HistoryItemFilePreviewView.swift:54 - file preview separately checks file existence and video natural size in a .task.
- Scopy/Views/History/HistoryItemFilePreviewView.swift:84 - file preview also owns thumbnail loading for preview content.
- Scopy/Presentation/HistoryItemPresentationCache.swift:5 - presentation cache is explicitly presentation-only and safe to precompute off the main thread.
- Scopy/Presentation/HistoryItemPresentationCache.swift:73 - presentation prewarm runs file preview and markdown capability computation off the main thread.
- Scopy/Presentation/ClipboardItemDisplayText.swift:5 - display-text cache is explicitly presentation-only and keeps UI rendering cheap without bloating DTOs.
- Scopy/Presentation/ClipboardItemDisplayText.swift:89 - display-text prewarm already computes row display strings off the main thread.
- ScopyUISupport/ThumbnailCache.swift:9 - ThumbnailDecodeCoordinator already bounds decode concurrency and dedupes in-flight path loads.
- ScopyUISupport/ThumbnailCache.swift:119 - ThumbnailCache.loadImage checks cache, decodes, commits NSImage, and records thumbnail metrics.
- ScopyUISupport/IconService.swift:26 - icon lookup still calls NSWorkspace on cache miss.
- Scopy/Views/History/HistoryListInteractionCoordinator.swift:19 - hover preview suppression includes active scroll, pointer interaction, and post-scroll cooldown.
- Scopy/Views/HistoryListView.swift:130 - live scroll observation is wired into the list background and forwards scroll state to both the interaction coordinator and HistoryViewModel.
- Scopy/Runtime/PerfFeatureFlags.swift:16 - preview task budget is already feature-flagged and enabled by default.
- ScopyTests/ClipboardItemDisplayTextTests.swift:94 - presentation prewarm has focused unit coverage.
- ScopyTests/ThumbnailPipelineTests.swift:35 - ThumbnailCache coverage currently verifies load/cache/remove behavior, not scroll scheduling.
- ScopyTests/HistoryListInteractionCoordinatorTests.swift:7 - scroll lifecycle and cooldown behavior are unit-tested.
- ScopyUITests/HistoryListUITests.swift:351 - UI performance profile runs with SCOPY_SCROLL_PROFILE and real/mock data sources.
- scripts/perf-frontend-profile.sh:499 - frontend profile summary reports frame, active frame, RunLoop, row, display, file preview, and thumbnail metrics.
- doc/perf/release-profiles/v0.7.4-profile.md:47 - thumbnail total latency should be read as scheduling/deferral signal, not proof that synchronous thumbnail decode is the remaining bottleneck.
- doc/perf/release-profiles/v0.7.4-profile.md:59 - row/render buckets explain only a small share of long-frame time after prior optimizations.
- doc/perf/release-profiles/v0.7.5-profile.md:44 - representative v0.7.5 row body/display/file preview p95 values are sub-millisecond in the standard profile.
- doc/perf/release-profiles/v0.7.5-profile.md:50 - future frontend work should keep reading main-thread and long-frame attribution instead of treating row buckets alone as the bottleneck.

Code patterns:

- HistoryItemView currently builds a private @MainActor HistoryItemDisplayModel during init, which already looks like the seed of a row descriptor Module (Scopy/Views/History/HistoryItemView.swift:12, Scopy/Views/History/HistoryItemView.swift:26, Scopy/Views/History/HistoryItemView.swift:177).
- Existing presentation prewarm patterns snapshot Sendable row data, compute in a detached utility task, and store results back on MainActor (Scopy/Presentation/ClipboardItemDisplayText.swift:89, Scopy/Presentation/ClipboardItemDisplayText.swift:103, Scopy/Presentation/ClipboardItemDisplayText.swift:132, Scopy/Presentation/HistoryItemPresentationCache.swift:73, Scopy/Presentation/HistoryItemPresentationCache.swift:84, Scopy/Presentation/HistoryItemPresentationCache.swift:115).
- Thumbnail views duplicate the same scheduling policy: check local path state, check ThumbnailCache, select lower priority while scrolling, await ThumbnailCache.loadImage, wait for scrolling to settle, then commit NSImage (Scopy/Views/History/HistoryItemThumbnailView.swift:47, Scopy/Views/History/HistoryItemThumbnailView.swift:59, Scopy/Views/History/HistoryItemThumbnailView.swift:63, Scopy/Views/History/HistoryItemFileThumbnailView.swift:77, Scopy/Views/History/HistoryItemFileThumbnailView.swift:89, Scopy/Views/History/HistoryItemFileThumbnailView.swift:93).
- Preview views have separate thumbnail and file/video async paths, so moving row thumbnails alone would not cover the whole preview pipeline (Scopy/Views/History/HistoryItemImagePreviewView.swift:57, Scopy/Views/History/HistoryItemImagePreviewView.swift:99, Scopy/Views/History/HistoryItemFilePreviewView.swift:54, Scopy/Views/History/HistoryItemFilePreviewView.swift:198, Scopy/Views/History/HistoryItemFilePreviewView.swift:234).
- Scroll interaction is central and observable through HistoryListInteractionCoordinator; row views consume events to suppress hover and reset preview state (Scopy/Views/History/HistoryListInteractionCoordinator.swift:28, Scopy/Views/History/HistoryItemView.swift:1373, Scopy/Views/History/HistoryItemView.swift:1385).

Concrete first-slice shape:

1. Introduce an internal row descriptor type under Scopy/Presentation, for example HistoryItemRowDescriptor or HistoryItemRowAssetDescriptor.
2. Move HistoryItemDisplayModel derivation into that Module and keep it behavior-equivalent.
3. Keep the descriptor free of NSImage, Task, @State, @StateObject, and scroll coordinator references.
4. Keep HistoryItemThumbnailView, HistoryItemFileThumbnailView, HistoryItemImagePreviewView, and HistoryItemFilePreviewView owning current async thumbnail/file-preview tasks.
5. Add focused descriptor tests next to current presentation tests to prove legacy title/metadata, file preview summary, markdown/export capability, and thumbnail visibility/height decisions remain identical.

Next one-question grilling prompt:

Should the row descriptor Module include app icon lookup/caching in the first slice, or should it expose only an appIconBundleID/iconRequest field and leave IconService lookup in the row until a separate icon/asset loader seam is designed?

Concrete test and perf gates:

- Descriptor-only slice: run make build and make test-unit. Add or update focused unit tests around descriptor parity using ClipboardItemDTO plus SettingsDTO samples.
- Because descriptor-only changes still touch row/list presentation hot paths, run make test-strict before treating it as implementation-ready confidence.
- If the slice changes row construction logic but does not change async thumbnail/scroll behavior, run make perf-frontend-profile as a smoke guard. Use make perf-frontend-profile-standard for commit-level confidence if row body/display/file preview metrics move or if the user wants performance evidence.
- If thumbnail async loading, scroll-settle budget, ImageLoadRequest, or ThumbnailCache scheduling is moved in any slice, require make perf-frontend-profile-standard and focused tests for cache hit, cache miss, cancellation, scrolling priority, delayed commit, and path-change behavior. Consider make perf-frontend-profile-full before claiming a real perf win.
- If preview markdown/file/video async ownership changes, add focused HistoryItemPreviewCoordinator/FilePreviewSupport coverage and run relevant HistoryList/HistoryItem UI tests.

Evidence that would change the answer:

- A current perf profile showing thumbnail queue/decode/main-commit/load-total buckets dominate long frames across real-snapshot scenarios, with main-thread attribution tying the delay to the current view-owned thumbnail tasks rather than broader SwiftUI/List/QuickLook behavior.
- A small existing testable abstraction already owning ImageLoadRequest, scroll-settle policy, cancellation, and thumbnail commit semantics, making async movement a low-risk adapter extraction rather than a new scheduler design.
- Product acceptance that the first Candidate 3 slice is allowed to change scheduling behavior or visible thumbnail timing, which would remove the behavior-preserving constraint.
- Evidence that app icon lookup or file icon fallback is a larger current row-time cost than descriptor derivation, making an asset loader seam more urgent than presentation cleanup.
- A failed descriptor-only implementation that leaves HistoryItemView still coupled to enough caches/services that the Interface is not meaningfully deeper.

## External References

- None. This research is based on repository code, Trellis specs, task PRD, and existing Scopy perf artifacts. No new Apple or third-party API is proposed.

## Related Specs

- .trellis/spec/frontend/index.md
- .trellis/spec/frontend/directory-structure.md
- .trellis/spec/frontend/component-guidelines.md
- .trellis/spec/frontend/hook-guidelines.md
- .trellis/spec/frontend/state-management.md
- .trellis/spec/frontend/type-safety.md
- .trellis/spec/frontend/quality-guidelines.md
- .trellis/spec/backend/quality-guidelines.md

## Caveats / Not Found

- I did not run new benchmarks; this is a scope decision using current source and existing perf artifacts.
- Existing ThumbnailCache tests do not cover scroll-settle scheduling or cancellation; that is a caveat against moving thumbnail async ownership in the same first slice.
- Existing v0.7.5 frontend profile docs note noisy profile-level frame/drop counters, so perf claims for Candidate 3 should use fresh before/after evidence before implementation claims any improvement.
- No current research file existed in this task before this note.
