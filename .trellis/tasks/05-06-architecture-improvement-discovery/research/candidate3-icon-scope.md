# Research: Candidate 3 icon scope

- Query: For Candidate 3 RowAssetDescriptor first slice, should the row descriptor Module include app icon lookup/caching in the first slice, or should it expose only an app icon request field such as appBundleID and leave IconService lookup in HistoryItemView until a separate icon/asset loader seam is designed?
- Scope: internal
- Date: 2026-05-07

## Findings

Recommended answer: the first RowAssetDescriptor slice should expose only app icon request data, preferably an optional appIconBundleID or small appIconRequest value that carries the bundle identifier. It should not include app icon lookup, NSImage state, IconService caching, or NSWorkspace fallback behavior in the first slice.

The row descriptor's first job should stay value-like: derive row-ready title, metadata, thumbnail layout flags, file preview fields, export capability, and app icon request identity from ClipboardItemDTO plus SettingsDTO and existing presentation caches. HistoryItemView can continue to turn that request into the visible Image by calling IconService.shared.icon(bundleID:) and rendering the existing fallback when the lookup misses.

Architecture vocabulary reading:

- Module: RowAssetDescriptor should be the row presentation/asset-request Module, not the icon loader Module. IconService is already a separate Module for app icon/name cache and NSWorkspace lookup.
- Interface: the descriptor Interface should expose appIconBundleID: String? or appIconRequest: AppIconRequest?, not NSImage?. This keeps the descriptor contract explicit and testable with ClipboardItemDTO samples.
- Implementation: icon lookup currently performs MainActor cache access and may call NSWorkspace on cache miss. Folding that Implementation into the descriptor would mix presentation derivation with AppKit resource lookup.
- Depth: a descriptor that hides row derivation rules and emits icon request identity is deeper than the current inline display model. A descriptor that simply calls IconService and stores NSImage widens the contract without solving a distinct ownership problem.
- Seam: the useful first seam is between HistoryItemView and presentation/asset request derivation. Icon lookup/caching is a second seam between row rendering, app filter UI, IconService, NSWorkspace, and possible future preloading.
- Adapter: RowAssetDescriptor can act as an Adapter from item.appBundleID to an icon request. A later IconAssetLoader Adapter can decide cached-only vs load-on-miss, fallback image policy, preload, metrics, and test injection.
- Leverage: descriptor tests can validate request identity without AppKit or cache state. Icon loader tests/perf gates need different fixtures, cache-miss behavior, and row/header reuse checks.
- Locality: keeping IconService lookup where rendering already happens preserves current Locality of UI image creation while the descriptor extraction reduces row derivation spread. Moving icons now would split icon policy across descriptor, HistoryItemView, HeaderView, HistoryViewModel preloading, and IconService.

Concrete first-slice shape:

1. Add appIconBundleID or appIconRequest to the descriptor, sourced directly from item.appBundleID.
2. Keep descriptor free of NSImage, NSWorkspace, IconService, Task, @State, @StateObject, and scroll coordinator references.
3. In HistoryItemView, replace direct item.appBundleID access with descriptor.appIconBundleID, then call IconService.shared.icon(bundleID:) exactly as today.
4. Preserve the current fallback Image(systemName: ScopyIcons.app) when the icon request is nil or IconService returns nil.
5. Do not change HeaderView icon/app-name behavior in this first slice; it uses the same IconService but is outside the row descriptor scope.

Files found:

- .trellis/tasks/05-06-architecture-improvement-discovery/prd.md:115 - Candidate 3 is the row asset and preview pipeline Module candidate.
- .trellis/tasks/05-06-architecture-improvement-discovery/prd.md:127 - Candidate 3 notes presentation cache, preview budget, icon loading, and thumbnail decode already exist while the row still reaches into several services.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-row-asset-scope.md:20 - Prior Candidate 3 decision says the descriptor should include optional app icon request data, while async asset loading stays separate.
- .trellis/tasks/05-06-architecture-improvement-discovery/implement.jsonl:1 - Implement context starts from frontend specs for row/list work.
- .trellis/tasks/05-06-architecture-improvement-discovery/implement.jsonl:9 - Implement context includes the prior Candidate 3 row asset scope decision.
- .trellis/tasks/05-06-architecture-improvement-discovery/check.jsonl:1 - Check context starts from frontend specs for row/list work.
- .trellis/tasks/05-06-architecture-improvement-discovery/check.jsonl:9 - Check context includes the prior Candidate 3 row asset scope decision.
- .trellis/spec/frontend/directory-structure.md:14 - Scopy/Presentation owns UI-facing formatting and presentation caches.
- .trellis/spec/frontend/directory-structure.md:18 - ScopyUISupport owns IconService and ThumbnailCache.
- .trellis/spec/frontend/directory-structure.md:31 - Pure display formatting and row presentation caches belong in Scopy/Presentation.
- .trellis/spec/frontend/component-guidelines.md:19 - History row work is performance-sensitive and expensive preview/thumbnail/hover work should stay behind existing caches/controllers/profile hooks.
- .trellis/spec/frontend/component-guidelines.md:48 - Body recomputation should not directly trigger expensive IO/search/markdown/thumbnail generation.
- .trellis/spec/frontend/hook-guidelines.md:21 - Long-running async work should be owned by a view model, service, or coordinator, not repeated body expressions.
- .trellis/spec/frontend/state-management.md:11 - @ObservationIgnored is for dependencies, tasks, handlers, and caches that should not trigger view invalidation.
- .trellis/spec/frontend/type-safety.md:25 - UI mutation stays on MainActor and services/tasks/caches should remain explicit.
- .trellis/spec/frontend/quality-guidelines.md:29 - Row/list/thumbnail/preview performance changes require frontend perf profiling gates.
- Scopy/Views/History/HistoryItemView.swift:12 - Current HistoryItemDisplayModel is the seed of the descriptor and derives row presentation fields.
- Scopy/Views/History/HistoryItemView.swift:26 - Display model currently derives from ClipboardItemDTO and SettingsDTO.
- Scopy/Views/History/HistoryItemView.swift:39 - Display model already reaches into HistoryItemPresentationCache.
- Scopy/Views/History/HistoryItemView.swift:47 - Display model already reaches into ClipboardItemDisplayText.
- Scopy/Views/History/HistoryItemView.swift:177 - HistoryItemView initializes the display model during row init.
- Scopy/Views/History/HistoryItemView.swift:580 - Row appIcon is a computed property that uses item.appBundleID.
- Scopy/Views/History/HistoryItemView.swift:583 - Row appIcon calls IconService.shared.icon(bundleID:) directly.
- Scopy/Views/History/HistoryItemView.swift:739 - Row rendering keeps the app icon as a visible leading element.
- Scopy/Views/History/HistoryItemView.swift:740 - Row renders Image(nsImage:) when IconService returns an icon.
- Scopy/Views/History/HistoryItemView.swift:746 - Row falls back to ScopyIcons.app when no icon is available.
- Scopy/Views/History/HistoryItemView.swift:1702 - HistoryItemView also has an appName helper backed by IconService, showing icon/name lookup is not purely descriptor data.
- ScopyUISupport/IconService.swift:4 - IconService is documented as the centralized app icon/name cache.
- ScopyUISupport/IconService.swift:5 - IconService is @MainActor.
- ScopyUISupport/IconService.swift:9 - IconService owns the NSCache for NSImage icons.
- ScopyUISupport/IconService.swift:22 - IconService exposes cachedIcon(bundleID:) separately from load-on-miss icon(bundleID:).
- ScopyUISupport/IconService.swift:26 - icon(bundleID:) is the load-on-miss API.
- ScopyUISupport/IconService.swift:31 - icon(bundleID:) calls NSWorkspace.urlForApplication on cache miss.
- ScopyUISupport/IconService.swift:35 - icon(bundleID:) calls NSWorkspace.icon(forFile:) before caching.
- ScopyUISupport/IconService.swift:40 - preloadIcon(bundleID:) already exists as an explicit cache-warming API.
- ScopyUISupport/IconService.swift:44 - IconService also owns appName lookup/caching.
- Scopy/Observables/HistoryViewModel.swift:323 - HistoryViewModel has a focused preloadAppIcons method.
- Scopy/Observables/HistoryViewModel.swift:327 - preloadAppIcons warms IconService from recent app bundle IDs.
- Scopy/Views/HeaderView.swift:259 - HeaderView has its own appIcon(for:) helper using IconService.
- Scopy/Views/HeaderView.swift:263 - HeaderView has its own appName(for:) helper using IconService.
- scripts/perf-frontend-profile.sh:505 - frontend perf summary includes swiftui.row_body_ms p95.
- scripts/perf-frontend-profile.sh:507 - frontend perf summary includes row.display_model_ms p95.
- logs/perf-frontend-profile-2026-05-01_14-59-03/frontend-scroll-profile-summary.md:93 - prior profile shows row.app_icon_ms was much smaller than row_body in one current mixed scenario.
- logs/perf-frontend-profile-static-scroll-2026-05-01_16-33-41/frontend-scroll-profile-summary.md:102 - another profile shows row.app_icon_ms is still a small correlated component compared with row_body.

Code patterns:

- Presentation-only caches are explicit and scoped to display values that are safe to precompute. HistoryItemPresentationCache calls itself presentation-only and computes file preview/markdown capability from sendable snapshots before storing back on MainActor (Scopy/Presentation/HistoryItemPresentationCache.swift:5, Scopy/Presentation/HistoryItemPresentationCache.swift:73, Scopy/Presentation/HistoryItemPresentationCache.swift:115).
- ClipboardItemDisplayText follows the same pattern: UI-specific title/metadata are not stored on the domain DTO, and prewarm computes snapshot-derived strings before MainActor cache storage (Scopy/Presentation/ClipboardItemDisplayText.swift:5, Scopy/Presentation/ClipboardItemDisplayText.swift:7, Scopy/Presentation/ClipboardItemDisplayText.swift:89, Scopy/Presentation/ClipboardItemDisplayText.swift:132).
- IconService is deliberately a shared UI support service, not a presentation cache. It has load-on-miss semantics, NSImage state, NSWorkspace lookup, app-name caching, preload, and clear-all behavior (ScopyUISupport/IconService.swift:4, ScopyUISupport/IconService.swift:22, ScopyUISupport/IconService.swift:26, ScopyUISupport/IconService.swift:40, ScopyUISupport/IconService.swift:44, ScopyUISupport/IconService.swift:60).
- There are at least two IconService consumers: HistoryItemView rows and HeaderView app filter UI. Changing icon loading ownership in the descriptor would not cover HeaderView, so the first slice would create an uneven partial abstraction (Scopy/Views/History/HistoryItemView.swift:583, Scopy/Views/HeaderView.swift:260, Scopy/Views/HeaderView.swift:264).
- Existing icon preloading already happens from HistoryViewModel recent-app state, which suggests future icon work should be an app-icon asset loader/preloader seam, not a row descriptor concern (Scopy/Observables/HistoryViewModel.swift:323, Scopy/Observables/HistoryViewModel.swift:327).
- The row's current visible behavior is simple: IconService result becomes Image(nsImage:), otherwise the ScopyIcons.app fallback renders at a fixed app-icon frame (Scopy/Views/History/HistoryItemView.swift:739, Scopy/Views/History/HistoryItemView.swift:740, Scopy/Views/History/HistoryItemView.swift:746, Scopy/Views/History/HistoryItemView.swift:749).

Next one-question grilling prompt:

Should the first RowAssetDescriptor implementation be placed in Scopy/Presentation as HistoryItemRowDescriptor with injectable cache dependencies for tests, or should it stay as an internal nested/private type near HistoryItemView until its Interface stabilizes?

Concrete tests and perf gates:

- Add focused descriptor tests proving appIconBundleID/appIconRequest mirrors ClipboardItemDTO.appBundleID for nil, known bundle ID, and changed bundle ID cases.
- Add descriptor parity tests for title, metadata, file preview info/path/kind/markdown, canExportPNG, canShowFileThumbnail, showThumbnails, thumbnailHeight, and needsThumbnailHeight.
- Keep existing row tests/UI identifiers unchanged. If row code only swaps item.appBundleID for descriptor.appIconBundleID, use make build and make test-unit as the minimum gate.
- Run make test-strict because the descriptor touches @MainActor UI/presentation boundaries and the first slice should not introduce Sendable/actor drift.
- Run make perf-frontend-profile as a smoke guard because row construction and body hot paths are touched. Use make perf-frontend-profile-standard before commit-level confidence if row_body, row.display_model, row.app_icon, file preview, or thumbnail metrics move.
- If a future slice changes IconService, icon preloading, cached-only vs load-on-miss policy, NSWorkspace calls, or icon metrics, add focused IconService/icon-loader tests and run make perf-frontend-profile-standard. Include HeaderView/app filter behavior in the check because it shares IconService.
- If icon loading becomes async or cancellable, add tests for cache hit, miss, nil bundle ID, deleted/missing app, cancellation/stale request, fallback rendering, and recent-app preload behavior.

Evidence that would change the answer:

- A fresh real-snapshot profile showing row.app_icon_ms or NSWorkspace icon lookup dominates row/render long-frame attribution, with cache-miss samples tied to HistoryItemView row construction.
- Evidence that current preloading misses most visible row bundle IDs, causing row-time NSWorkspace lookups that cannot be fixed by improving preload or cached-only lookup.
- A small existing IconAssetLoader abstraction already covering rows and HeaderView with injectable cache, preload, fallback, metrics, and AppKit lookup policy.
- Product acceptance that the first Candidate 3 slice may change icon timing, fallback behavior, or cache-miss semantics instead of being behavior-preserving.
- A descriptor-only implementation that leaves HistoryItemView's remaining IconService coupling as the primary reason the Module is not meaningfully deeper.

## External References

- None. This research is based on repository code, Trellis specs, task context, and existing local perf artifacts. No new Apple API or third-party API is proposed.

## Related Specs

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

## Caveats / Not Found

- I did not run new benchmarks. The performance judgment uses existing local frontend profile artifacts and current source inspection.
- The current source has row.app_icon_ms profile artifacts in logs, but scripts/perf-frontend-profile.sh summary code shown in this pass did not list row.app_icon_ms in the metric pair table around lines 499-520. Long-frame attribution still reports it in existing profile summaries.
- There is no focused IconService test found in this pass. That is another reason to keep icon loading outside the first descriptor slice unless a dedicated icon loader seam is designed with tests.
- App icon lookup is @MainActor today. Moving NSImage or NSWorkspace lookup into a descriptor that might later be precomputed off-main would create a concurrency/design constraint that the descriptor does not need in its first version.

