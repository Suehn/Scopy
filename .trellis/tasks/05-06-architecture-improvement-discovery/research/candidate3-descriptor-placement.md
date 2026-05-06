# Research: Candidate 3 descriptor placement

- Query: Should the first RowAssetDescriptor implementation be placed in Scopy/Presentation as HistoryItemRowDescriptor with injectable cache dependencies for tests, or should it stay as an internal nested/private type near HistoryItemView until its Interface stabilizes?
- Scope: internal
- Date: 2026-05-07

## Findings

Recommended answer: place the first implementation in `Scopy/Presentation` as an internal app-target type, preferably `HistoryItemRowDescriptor`, with narrow injectable presentation dependencies for focused tests. Do not keep it as a private nested type in `HistoryItemView`, and do not publish it through `ScopyKit` or `ScopyUISupport`.

This is the right middle ground: the descriptor is already more than view-local rendering because it adapts `ClipboardItemDTO`, `SettingsDTO`, `HistoryItemPresentationCache`, and `ClipboardItemDisplayText` into a row-ready contract. But it is still presentation-only app code, so it should remain `internal` and app-target scoped until later slices prove a stable cross-target asset interface is needed.

Use a production initializer that defaults to the current shared presentation caches, and a test initializer that accepts a small dependency value or protocols for:

- display text derivation: title/metadata for a `ClipboardItemDTO`
- presentation derivation: file preview summary and PNG export capability

The dependency shape should stay value/presentation-oriented. It should not inject `IconService`, `ThumbnailCache`, `NSImage`, `NSWorkspace`, `Task`, `HistoryListInteractionCoordinator`, or any SwiftUI state object in the first slice.

Architecture vocabulary reading:

- Module: `HistoryItemRowDescriptor` should be a small presentation Module under `Scopy/Presentation`. It is not a view, not a backend domain model, and not the future async asset loader.
- Interface: the Interface should expose row-ready values: title text, metadata text, thumbnail height/show flags, file preview path/kind/markdown flags, PNG export capability, thumbnail-height need, and optional app icon request identity. Keeping this type private inside `HistoryItemView` would hide the Interface from direct unit tests and make the seam weaker.
- Implementation: the Implementation can initially be the moved `HistoryItemDisplayModel` logic. Its cache dependencies should be injectable because the current logic reaches into `HistoryItemPresentationCache.shared` and `ClipboardItemDisplayText.shared`, which otherwise makes parity tests depend on singleton cache state.
- Depth: a dedicated `Scopy/Presentation` type is deeper than a nested private type because it hides row derivation and cache lookup shape behind a reusable row-facing contract. It should still avoid a public API because the first descriptor interface is expected to evolve.
- Seam: the seam belongs between `HistoryItemView` rendering/interaction and presentation derivation. It does not belong between the row and async thumbnail/icon loading yet; prior research keeps those as separate future seams.
- Adapter: the descriptor should act as an Adapter from DTO/settings/cache data to row presentation fields. The app icon part should remain request identity only, following the prior icon-scope decision.
- Leverage: `Scopy/Presentation` gives high test leverage because `ScopyTests` compiles app UI/Presentation sources and already has `@testable import Scopy` presentation tests. A private nested type would force view-level tests for pure derivation rules.
- Locality: `Scopy/Presentation` is the project-local home for pure display formatting and row presentation caches. Keeping the descriptor next to `HistoryItemView` would preserve physical locality but keep semantic locality poor: a view file would still own cache adaptation, file-preview decisions, markdown export capability, and layout flags.

Concrete first-slice shape:

1. Add `Scopy/Presentation/HistoryItemRowDescriptor.swift`.
2. Move the current `HistoryItemDisplayModel` fields and initializer logic from `HistoryItemView` into that internal type.
3. Add a small internal dependency container such as `HistoryItemRowDescriptor.Dependencies` with default closures backed by `HistoryItemPresentationCache.shared` and `ClipboardItemDisplayText.shared`.
4. Keep `HistoryItemView` owning rendering, interaction, hover, popovers, row controller state, preview coordinator state, and thumbnail view composition.
5. Keep icon lookup in `HistoryItemView`; the descriptor exposes only `appIconBundleID` or an equivalent request value.
6. Keep thumbnail async loading and scroll-settle behavior in `HistoryItemThumbnailView` / `HistoryItemFileThumbnailView`.

Next one-question grilling prompt:

Should the descriptor production path keep the existing `row.display_model_ms` metric name around `HistoryItemRowDescriptor` construction for profile continuity, or should the extraction rename it to a new metric such as `row.descriptor_ms` and update perf analysis scripts/docs in the same slice?

Concrete tests and perf gates:

- Add `ScopyTests/HistoryItemRowDescriptorTests.swift` with `@testable import Scopy`.
- Test descriptor parity for text, rtf/html markdown candidates, file preview path/kind/markdown, image thumbnail flags, file thumbnail flags, thumbnail height, `needsThumbnailHeight`, and `canExportPNG`.
- Test injectable dependencies by returning fixed title/metadata/file-preview/export values and proving the descriptor uses those values instead of singleton cache state.
- Test `appIconBundleID` / app-icon request mirrors `ClipboardItemDTO.appBundleID` for nil and non-nil values without invoking `IconService`.
- Keep existing row/UI identifiers unchanged; no UI test update should be needed for descriptor-only extraction.
- Minimum gates for implementation: `make build`, `make test-unit`, and `make test-strict`.
- Because this touches row construction and profile buckets, run `make perf-frontend-profile` as a smoke guard. Use `make perf-frontend-profile-standard` before commit-level confidence if `swiftui.row_body_ms`, `row.display_model_ms`, file preview, thumbnail, or app-icon attribution changes.

Evidence that would change the answer:

- `HistoryItemRowDescriptor` needs to be consumed outside app UI/Presentation, for example by `ScopyUISupport`, `ScopyKit`, an extension, or a non-app package. That would argue for a different target boundary.
- Implementation shows the descriptor cannot be tested without importing SwiftUI/AppKit view state, row controllers, preview coordinators, `NSImage`, `Task`, or scroll coordinators. That would mean the proposed Interface is too broad and should return to a smaller nested/private transition.
- Fresh profiling proves the main risk is not descriptor derivation but icon or thumbnail loading, making a dedicated asset-loader seam more valuable than extracting presentation derivation first.
- A descriptor-only extraction leaves most cache/service coupling inside `HistoryItemView`, so the Module fails to improve Depth or Locality.
- Public or cross-target consumers require API stability guarantees. In that case, the Interface should stabilize through more grilling before being moved beyond app-internal `Scopy/Presentation`.

Files found:

- .trellis/tasks/05-06-architecture-improvement-discovery/prd.md:115 - Candidate 3 is the row asset and preview pipeline Module candidate.
- .trellis/tasks/05-06-architecture-improvement-discovery/prd.md:127 - Candidate 3 notes that presentation cache, preview budget, icon loading, and thumbnail decode already exist while the row still reaches into multiple services.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-row-asset-scope.md:9 - Prior Candidate 3 research limits the first slice to a row-ready descriptor.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-row-asset-scope.md:11 - Prior scope defines descriptor outputs and says it can delegate to existing presentation caches and helpers.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-row-asset-scope.md:17 - Prior scope names a narrow value Interface and keeps thumbnail loading separate.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-icon-scope.md:9 - Prior icon-scope research says the first descriptor should expose only app icon request data.
- .trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-icon-scope.md:24 - Prior icon-scope research gives the concrete first-slice shape for app icon request identity.
- .trellis/tasks/05-06-architecture-improvement-discovery/implement.jsonl:1 - Implement context starts from frontend specs for row/list work.
- .trellis/tasks/05-06-architecture-improvement-discovery/implement.jsonl:9 - Implement context includes the prior Candidate 3 row asset scope research.
- .trellis/tasks/05-06-architecture-improvement-discovery/check.jsonl:1 - Check context starts from frontend specs for row/list work.
- .trellis/tasks/05-06-architecture-improvement-discovery/check.jsonl:9 - Check context includes the prior Candidate 3 row asset scope research.
- .trellis/spec/frontend/directory-structure.md:14 - `Scopy/Presentation` owns UI-facing formatting and presentation caches.
- .trellis/spec/frontend/directory-structure.md:21 - The app target includes UI files while `ScopyKit` excludes UI directories.
- .trellis/spec/frontend/directory-structure.md:31 - Pure display formatting and row presentation caches belong in `Scopy/Presentation`.
- .trellis/spec/frontend/component-guidelines.md:9 - Do not split stateful interaction flows so aggressively that ownership becomes unclear.
- .trellis/spec/frontend/component-guidelines.md:19 - History row work is performance-sensitive and expensive preview/thumbnail/hover work should stay behind caches/controllers/profile hooks.
- .trellis/spec/frontend/component-guidelines.md:48 - Views should not trigger file IO, search, markdown rendering, or thumbnail generation directly from body recomputation.
- .trellis/spec/frontend/hook-guidelines.md:21 - Long-running async work belongs in a view model, service, or coordinator, not repeated body expressions.
- .trellis/spec/frontend/quality-guidelines.md:19 - Default UI gates are `make build` and `make test-unit`.
- .trellis/spec/frontend/quality-guidelines.md:29 - Scroll/render/thumbnail/preview performance changes require frontend perf profiling.
- Scopy/Views/History/HistoryItemView.swift:12 - The current private `HistoryItemDisplayModel` is the direct seed for the descriptor.
- Scopy/Views/History/HistoryItemView.swift:26 - The current display model derives row fields from `ClipboardItemDTO` and `SettingsDTO`.
- Scopy/Views/History/HistoryItemView.swift:39 - The current display model reaches into `HistoryItemPresentationCache.shared`.
- Scopy/Views/History/HistoryItemView.swift:47 - The current display model reaches into `ClipboardItemDisplayText.shared`.
- Scopy/Views/History/HistoryItemView.swift:63 - `PreviewTaskBudget` is a separate actor and should not be part of the descriptor.
- Scopy/Views/History/HistoryItemView.swift:130 - `HistoryItemView` stores the display model separately from row controller and preview coordinator state.
- Scopy/Views/History/HistoryItemView.swift:177 - `HistoryItemView` currently constructs the display model in init.
- Scopy/Views/History/HistoryItemView.swift:580 - Current app icon lookup is row-local.
- Scopy/Views/History/HistoryItemView.swift:583 - Current row icon lookup calls `IconService.shared.icon(bundleID:)`.
- Scopy/Views/History/HistoryItemView.swift:633 - Row rendering branches on descriptor-like flags and item type.
- Scopy/Views/History/HistoryItemView.swift:707 - Row body is profiled as `swiftui.row_body_ms`.
- Scopy/Views/History/HistoryItemView.swift:739 - Row rendering keeps app icon display as part of visible row composition.
- Scopy/Views/History/HistoryItemView.swift:785 - Row layout uses the display-model `needsThumbnailHeight` value.
- Scopy/Views/History/HistoryItemThumbnailView.swift:30 - Image thumbnail loading remains a SwiftUI `.task` keyed by thumbnail path.
- Scopy/Views/History/HistoryItemFileThumbnailView.swift:32 - File thumbnail loading has a parallel `.task` path.
- Scopy/Presentation/HistoryItemPresentationCache.swift:5 - Existing row-derived cache is explicitly presentation-only.
- Scopy/Presentation/HistoryItemPresentationCache.swift:73 - Existing presentation prewarm computes values off the main thread before MainActor storage.
- Scopy/Presentation/ClipboardItemDisplayText.swift:5 - Display-text cache is explicitly presentation-only and keeps UI rendering cheap.
- Scopy/Presentation/ClipboardItemDisplayText.swift:89 - Display-text prewarm uses snapshot-derived row strings.
- ScopyUISupport/IconService.swift:4 - `IconService` is a centralized app icon/name cache, not a row descriptor.
- ScopyUISupport/IconService.swift:26 - `IconService.icon(bundleID:)` is a load-on-miss API.
- project.yml:52 - `Scopy` app target owns application source configuration.
- project.yml:56 - `Scopy` app target includes the `Scopy` directory.
- project.yml:59 - The app target only keeps App/UI/Presentation.
- project.yml:206 - `ScopyTests` includes the `Scopy` directory in the unit-test bundle.
- project.yml:228 - `ScopyTests` uses independent bundle mode for `@testable import`.
- Package.swift:15 - `ScopyKit` target is built from `Scopy`.
- Package.swift:27 - `ScopyKit` explicitly excludes `Presentation`.
- Package.swift:34 - `ScopyUISupport` is a separate target.
- ScopyTests/ClipboardItemDisplayTextTests.swift:5 - Existing presentation tests use `@testable import Scopy`.
- ScopyTests/ClipboardItemDisplayTextTests.swift:94 - Existing tests already cover presentation prewarm behavior.

Code patterns:

- Existing presentation-only caches are standalone `Scopy/Presentation` files, `@MainActor`, internal to the app target, and tested through `@testable import Scopy`. This matches a `HistoryItemRowDescriptor` file better than a nested private view type.
- `HistoryItemDisplayModel` already contains the full row descriptor field set and constructs from DTO/settings plus presentation singletons. Moving it mostly changes ownership, not behavior.
- `HistoryItemView` mixes three different concerns today: row-ready derivation, row rendering, and row interaction/preview lifecycle. Extracting the descriptor improves Locality while leaving interaction ownership near the view.
- `ScopyUISupport` is for reusable UI support utilities such as `IconService` and `ThumbnailCache`; moving this descriptor there would force a broader target/API boundary before the Interface is stable.
- `ScopyKit` excludes `Presentation`, so adding `Scopy/Presentation/HistoryItemRowDescriptor.swift` keeps backend/source-of-truth boundaries unchanged.
- Current tests already compile app sources into `ScopyTests`, so an `internal` descriptor in `Scopy/Presentation` can get focused tests without making it public.
- The code-reuse guide favors extracting shared logic when logic is complex enough to have bugs and should not be copy-pasted. A descriptor extraction should move the existing logic once rather than duplicating row derivation in tests or helper fixtures.

External references:

- None. This research is based on repository code, Trellis specs, task context, and existing local memory/perf context. No new Apple API or third-party API is proposed.

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

## Caveats / Not Found

- I did not run new benchmarks. This is a placement/scope decision using current source, Trellis specs, prior Candidate 3 research, and existing local perf context.
- I did not find a current public `RowAssetDescriptor` or `HistoryItemRowDescriptor` type; the existing seed is the private `HistoryItemDisplayModel` inside `HistoryItemView`.
- I did not find focused `IconService` tests in this pass. That reinforces keeping icon loading out of the first descriptor slice.
- Keeping the descriptor `internal` means future non-app consumers would need a separate design decision before reusing it across targets.
- The dependency injection should stay tiny. If it grows into a general service locator, the slice should be stopped and narrowed.
