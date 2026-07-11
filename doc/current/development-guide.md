---
doc_type: guide
status: active
owner: maintainers
last_reviewed: 2026-07-11
canonical: true
related_versions:
  - v0.65.0
---

# Development Guide

This document is the canonical implementation guide for the current Scopy codebase. It explains how the repo is structured, how the main runtime paths work, and how to safely change the project without drifting from release, performance, and documentation contracts.

## Reference State

- Reference release: `v0.65.0`
- Version metadata: [../meta/release-current.yml](../meta/release-current.yml)
- Active requirements: [product-spec.md](./product-spec.md)
- Release workflow: [release-runbook.md](./release-runbook.md)

## Architecture Overview

Scopy is intentionally split into four layers:

| Layer | Responsibility | Main paths |
| --- | --- | --- |
| App / UI shell | App lifecycle, panel/window coordination, menu bar, view composition, settings shell | `Scopy/AppDelegate.swift`, `Scopy/Views`, `Scopy/Observables`, `Scopy/Presentation` |
| Backend library | Clipboard ingest, persistence, search, settings, protocols, domain models | `Scopy/Application`, `Scopy/Domain`, `Scopy/Infrastructure`, `Scopy/Services` |
| UI support library | Reusable non-app-shell UI support code | `ScopyUISupport` |
| Tooling | Benchmarks and release/doc scripts | `Tools/ScopyBench`, `scripts`, `Makefile` |

The app target imports backend/UI support through SwiftPM products rather than compiling every backend source directly into the UI shell.

## Repository Layout

| Path | Purpose |
| --- | --- |
| `project.yml` | XcodeGen project definition and build-script wiring |
| `Package.swift` | SwiftPM products: `ScopyKit`, `ScopyUISupport`, `ScopyBench` |
| `Scopy/Application` | App-facing backend facade, notably `ClipboardService` |
| `Scopy/Domain` | DTOs, protocols, and domain-level types |
| `Scopy/Infrastructure` | Search engine, persistence helpers, settings/configuration infrastructure |
| `Scopy/Services` | Storage, clipboard monitoring, and concrete service primitives |
| `Scopy/Observables` | State/view-model layer that adapts backend protocols to SwiftUI |
| `Scopy/Views` | Main panel, header, history items, settings pages, UI testing harnesses |
| `Scopy/Resources` | Markdown preview assets, bundled tools, third-party runtime resources |
| `ScopyTests` / `ScopyUITests` | Unit and UI test suites |
| `doc/current` | Active docs |
| `doc/releases` | Release index, changelog window, immutable release history |

## Runtime Flows

### 1. Application Startup

1. `AppDelegate.applicationDidFinishLaunching` boots the menu bar app, windows/panel, and root state wiring.
2. `AppState.start()` chooses the service implementation, starts it, subscribes to event streams, and triggers initial loads.
3. `ClipboardService.start()` brings up `ClipboardMonitor`, `StorageService`, and `SearchEngineImpl`.

Implication: app shell code should stay orchestration-only; backend initialization belongs behind `ClipboardServiceProtocol`.

### 2. Clipboard Ingest

1. `ClipboardMonitor` observes pasteboard changes and normalizes clipboard payloads.
2. `ClipboardService.handleNewContent(_:)` decides how to ingest, deduplicate, and schedule cleanup.
3. `StorageService` persists inline/external payloads and validates any external storage paths.
4. `ClipboardService` emits events so state/view models update reactively.

Implication: clipboard semantics, dedup, cleanup triggering, and safe file handling are backend responsibilities, not view responsibilities.

### 3. History Loading And Search

1. `HistoryViewModel.load()` uses `fetchPinned()` plus `fetchRecentUnpinned(limit:offset:)` so pinned rows do not consume the initial recent-page quota.
2. `HistoryViewModel.loadMore()` uses `fetchRecentUnpinned(limit:offset:)` with the current unpinned count as offset; the initial recent page is 50 and load-more pages are 500.
3. `HistoryViewModel.search()` builds a `SearchRequest` and calls `search(query:)`.
4. `SearchEngineImpl` executes mode-specific behavior for `exact`, `fuzzy`, `fuzzyPlus`, and `regex`.
5. Exact search planning and execution must share `SearchPlanner.normalizedExactQuery(_:)` so whitespace trimming affects both coverage decisions and matching consistently.
6. UI updates are event-driven; the list should not depend on ad hoc full reloads for ordinary mutations.
7. Search results expose `SearchCoverage` so UI can distinguish complete results, staged fuzzy refinement, and intentional recent-only limits.
8. Production search paths should construct `SearchCoverage` directly; `isPrefilter` remains a compatibility shim for legacy and test callers only.

Implication: changes to search semantics belong in the request model, search engine, and user-visible docs together.

### 4. Preview And Export

1. `HistoryItemView` routes hover interactions into `HistoryHoverPreviewPipeline` request values for image, text, Markdown file, and file preview flows.
2. `HistoryHoverPreviewPipeline` owns preview planning, cache-hit/cache-miss event emission, suppression checks, and bounded detached preview work before the row applies UI state.
3. `HoverPreviewLoader` owns image/file preview decode and downsampling helpers so the row view does not carry raw ImageIO logic.
4. Markdown/LaTeX preview rendering is handled in the text preview path and export pipeline.
5. The renderer normalizes inline LaTeX, ATX headings, table-row inline-code pipe examples, source-reference citation links, safe HTML placeholders, and CJK punctuation-adjacent emphasis before local `markdown-it` rendering, then strips internal placeholders before user-visible HTML or fallback text. ATX heading and table code-span pipe normalization are shared with the unified renderer so malformed headings like `#标题` cannot fall back to paragraph rendering on one path, and table examples such as `` `| A | B |` `` cannot expand into extra columns on another path.
6. `MarkdownExportService` now lives under `Scopy/Services/Export` and produces PNG output back to the pasteboard through `ScopyKit`.
7. pngquant settings affect both image history optimization and Markdown/LaTeX export compression where enabled.
8. The ChatGPT-aligned Markdown theme uses the captured `markdown markdown-new-styling` rules for heading, paragraph, list, and blockquote rhythm; root text wrapping follows the WACZ `wrap-break-word` utility, and blockquotes keep the captured 24px left inset, 8px vertical padding, and 4px quote bar inset by 8px. Do not fall back to the older AssistantMessage `qN-_1G_MarkdownContent` heading scale unless a new capture proves the DOM has changed again. The detailed source-derived contract lives in `doc/current/markdown-chatgpt-wacz-style-contract.md`.
9. The theme treats `code` inside headings as real inline code. Keep the ChatGPT gray pill, relative `em` sizing, inherited heading line height, and normal wrapping; do not replace heading code with a transparent inherited-text override.
10. Markdown preview must reflow at the active ChatGPT layout profile rather than transform-scaling a fixed text surface. The Scopy output shell stays at the desktop message branch (`48rem`/`768px` content column plus 24px side padding, fixed `816px` render surface). The default `100%` profile uses the full fixed surface as the CSS layout viewport with normal `1.0x` font metrics. Supported layout scale values are clamped to `80%...200%`; each value keeps the same preview/PNG surface, lays out inside an internal CSS viewport of `surface / scale`, then applies WebKit layout zoom back to the fixed surface so both font size and line breaks follow browser zoom. The preview and Settings sliders use light magnetic snapping around every 5% stop, but the renderer contract accepts any integer percent in the range. Preview slider interaction must keep the previous rendered surface visible while the newly selected scale is debounced and rerendered; do not clear the WebView or reset measured height on every slider tick. Do not implement scale changes by enlarging the canvas, multiplying fonts after layout, or reusing another scale's line breaks. Layout scale changes may affect font size and line breaks, but must not change PNG target pixels. The Markdown hover popover width is owned by Scopy's shared preview-frame policy and must match image/file preview width; it is fully decoupled from Markdown content layout. The internal Markdown `renderWidth` must come from the ChatGPT layout profile, not the popover/WebView `100vw`; live preview may fit-scale the already-laid-out visual surface into the shared frame, but that fit scale is display-only. WebView measurements may update height and overflow state only, never shrink or grow the outer frame. Ordinary Markdown pipe tables must use the WACZ root Markdown table column-size model for every table, including normal two-column tables; wide behavior is a scroll/overflow outcome of that same model, not a separate column-count heuristic. Preview code must call the table layout path only; any table transform that fits overflow back into a bitmap belongs exclusively to the export path after the WACZ-equivalent layout has completed. Table-local horizontal scroll must not request a wider hover popover; width escalation is reserved for non-table overflow such as code, KaTeX, footnotes, and details.
10a. The Markdown hover-preview scale switch is a preview-local immediate control. It may persist its last chosen profile in a small UserDefaults key for convenience, but it must not mutate `SettingsDTO` or bypass Settings Save/Cancel semantics. When a user exports from the hover preview, export should use the active preview profile so the PNG matches what the user just inspected.
11. Task lists follow the AssistantMessage source contract: the list container has no bullet markers and each task row is a baseline-aligned flex row with an 8px gap. Markdown-generated checkbox inputs are hidden after their checked state is read, and raw `[x]` text markers feed the same path. Scopy renders one CSS-painted visual marker instead of relying on WebKit's native checkbox tint so preview and PNG export share the same checked/unchecked colors.
12. Markdown table cells use the captured root Markdown pipe-table contract while Scopy keeps a local scroll wrapper for preview/export containment: header padding block is `8px`, body padding block is `10px`, non-last cells keep the root 24px end padding, and the last row keeps the root extra bottom padding. Keep the inner table wrapper with `width: fit-content` and `min-width: 100%` so preview can scroll locally. Column sizes for ordinary Markdown pipe tables are `sm/md/lg/xl` from the WACZ Markdown plugin thresholds `>160/>100/>40/else`, with no `xs` bucket. Root Markdown column widths are based on `thread-content-max-width`, not the narrowed current content width, because browser zoom should be able to make a table overflow horizontally instead of forcing more cell wrapping. Do not add export-only last-column width or padding rules to solve bitmap clipping. Infer per-column sizes in the shared renderer for all tables and keep export as a scale transform, not a separate table stylesheet.
13. Table parsing must not be repaired from CSS. Normalize only table-row one- or two-backtick code spans by escaping their internal unescaped `|` before GFM parsing. Leave three-or-more-backtick fence markers such as ```` ```python ```` as literal cell text so real table delimiters still split columns.
14. Source citations are a separate visual path from ordinary Markdown links. Promote only explicit parenthesized source-reference links such as `([AP News][1])` when the referenced definition resolves to HTTP(S) and the label looks like a source name; collapse grouped source references such as `([AP News][1], [Reuters][2])` to the first source plus `+1`; keep normal parenthesized links like `([guide][1])` on the ordinary dotted-underlined link path.

Search marker: `SCOPY_EXPORT_PDF_GLOBAL_SCALE_MISMATCH`

- Forced PDF export has an extra failure mode that preview and snapshot export do not have: pre-PDF global-scale budgeting uses the WKWebView viewport width, while PDF rasterization ultimately uses the real PDF page boxes.
- If the PDF page box is narrower than the viewport, the final raster height becomes larger than the earlier estimate. Long content can then fail only on the PDF path with symptoms such as clipped long exports or `PDF rasterization too large`.
- When touching Markdown export, keep the PDF preflight/re-scale guard next to this marker and keep `ExportMarkdownPNGUITests.testAutoExportGlobalScalePDFDoesNotLeaveBlankRight()` green.
- Global export scale must preserve the already-laid-out content width. Do not compensate by widening `#content` by `1 / scale`; that changes paragraph line breaks and table column measurement instead of scaling the preview-equivalent layout.

Implication: preview/export work must remain background-safe and should not mutate unrelated persisted content.

#### Hover Transfer Contract

- `HistoryItemPreviewCoordinator` owns preview kind/token state, active popover screen geometry, fixed popover-exit cleanup, and the hover-intent controller. `HistoryItemView` starts and cancels transfer lifecycle but does not own geometry math.
- `HoverPreviewIntentPolicy` is the pure geometry/time state machine. Keep it independent of AppKit, SwiftUI, wall-clock reads, and async scheduling so every placement direction and edge case stays deterministic.
- `HoverPreviewIntentController` owns one cancellable `@MainActor` task, samples `NSEvent.mouseLocation` at approximately `16.67ms` only during row-to-popover transfer, and stops no later than `500ms`. It must not become observable.
- `PopoverWindowObserver` is the narrow AppKit bridge. It reports `NSWindow.frame` in screen coordinates on attach, move, resize, and screen change; emits `nil` on close; deduplicates unchanged frames; and removes every notification observer during teardown.
- Safe-triangle geometry is rebuilt only when the target frame changes. The steady-state sample path must not allocate collections or recompute angular tangents.
- `HistoryListInteractionCoordinator` owns the active transfer item ID. Other rows may show visual hover, but must defer selection, dismissal, and preview work until the transfer ends; `HistoryListView` also guards cross-row dismissal/presentation to tolerate AppKit exit/enter ordering at screen edges.
- The coordinator must reject stale geometry and close callbacks by preview kind and token. Row re-entry, target arrival, replacement, scroll, system close, explicit dismissal, invalidation, and teardown must release transfer ownership and cancel both fixed-delay and intent tasks exactly once.
- Row-to-popover uses directional intent. Popover-to-row keeps the fixed `120ms` grace and does not reuse the triangle policy.

### 4.1 Storage Cleanup Execution

1. `StorageService` builds repository `DeletePlan` values for cleanup-by-count, cleanup-by-age, cleanup-by-size, image-only cleanup, external-storage cleanup, and composite cleanup.
2. `StorageService.applyDeletePlan` is the single adapter that deletes database rows and removes validated external payloads for those plans.
3. Repository paths that need atomic row/content deletion can remain separate when they must preserve a tighter transaction boundary.

Implication: new cleanup variants should reuse the delete-plan executor unless they require a documented atomicity exception.

### 4.5 List Interaction Coordination

1. `HistoryListView` owns `HistoryListInteractionCoordinator` and passes it into rows / observers as list-scoped state.
2. `HistoryItemView` keeps its passive descriptor and content revision directly, but creates one optional `HistoryItemInteractionState` only for a real hover/action or owned asynchronous lifetime. Do not restore eager row controllers.
3. The coordinator owns one tokenized active slot and one suppressed-hover candidate. Row lifecycle holds ownership tokens, not broadcast observers or raw UUID registrations.
4. Scroll-end cooldown may restore a stationary pointer only when item, revision, token, pointer location, and visibility still match.
5. The AppKit adapter starts pointer suppression only when `NSScroller.testPart(_:)` identifies an actionable vertical or horizontal scroller part; mouse-up must match the originating token.
6. Stable context-menu predicates belong in `HistoryItemPresentationCache`, keyed by `ClipboardItemContentRevision`. Keep `markdownMenuSignalCache` separate from the exact Markdown export-capability cache: exact `true` or `false` always wins, while the heuristic caches both outcomes, prewarms off-main, deduplicates in-flight work, and rejects stale generation completion.
7. `HistoryRelativeTimeClock` and `HistoryItemPresentationCache` remain list/presentation concerns: pause ticking while scrolling or hidden, keep caches bounded, and invalidate by content revision.
8. Scroll and pointer suppression stay list-local; do not reintroduce process-global hover/scroll coordination state.

Implication: SwiftUI row rendering should remain decoupled from global singleton churn during fast scroll and preview suppression.

### 5. Settings And Hotkey Flow

1. `SettingsView` maintains a transactional draft copy of `SettingsDTO`.
2. Saving applies a `SettingsPatch` merge rather than overwriting with stale snapshots.
3. Hotkey recording is special-cased to apply immediately and persist independently.
4. `.settingsChanged` events flow back through `AppState` so runtime state stays in sync.

Implication: if you touch settings behavior, preserve the Save/Cancel model and the immediate hotkey-apply semantics.

## Current User Feature Surface

### Main Panel

- Recent-history list with incremental loading
- Keyboard navigation and copy/paste selection
- Pin/unpin and delete
- Search box, app filter, type filter, mode switch, and sort switch
- Search focus and list selection remain independent; hover reselection is allowed while the field is focused

### Item Actions

- Context menu actions for copy / pin / delete
- Send via AirDrop for image rows and resolvable file rows
- Open Containing Folder only for real file-backed rows, not temporary image share files
- Paste-optimized for Codex copies the optimized payload, closes the panel, and posts `Control+V`
- File note editing for file items
- Image optimization for stored image items
- Hover preview for text, image, and file content

### Export And Media

- Markdown/LaTeX render and PNG export with local CommonMark/GFM, footnote, math, and syntax-highlight assets
- Optional pngquant compression for exported PNG
- Optional automatic compression for newly ingested image history
- Thumbnail display and configurable thumbnail sizing

### Settings Pages

- `General`: default search mode
- `Shortcuts`: global hotkey recording
- `Clipboard`: saved content types, pngquant image/export controls, polling interval
- `Appearance`: thumbnail visibility, thumbnail size, preview delay
- `Storage`: item/content limits, image-only cleanup, storage statistics, Finder reveal
- `About`: version/build info, performance metrics, GitHub/feedback links

## Build, Test, And Validation Workflow

### Baseline Build/Test

- `make build`
- `./deploy.sh release --no-launch` for a repeatable local Release build and `/Applications` install; Xcode products stay in isolated DerivedData while SwiftPM continues to own `.build`
- `make test-unit`
- `make test-strict` for concurrency-sensitive work
- `make test-tsan` when the environment supports the hosted test path; the command auto-skips the known-bad `macOS 26.x + Xcode 26.2 (17C52)` hosted runtime combination
- Hosted TSan CI lives in `.github/workflows/tsan.yml` on `macos-15 + Xcode 16.0`; treat that workflow as the supported real-coverage path until the local Apple runtime issue is resolved
- Resource staging scripts in `project.yml` intentionally stay correctness-first for SwiftPM bundles and app resources. Optimize their internal work with idempotent/differential copy behavior; do not skip dynamic staging by enabling dependency analysis unless the input/output contract is fully explicit.

### Performance Validation

- `make test-snapshot-perf-release` for release-path backend perf gates
- `make perf-search-warm-load` for backend full-index warm-load latency and peak RSS
- `scripts/perf-warm-scroll-ab.sh` for causal fixed-workload comparisons. The default `passive-row` axis changes only `SCOPY_PERF_PASSIVE_ROW`; `--axis markdown-menu-cache` keeps both variants passive and changes only `SCOPY_PERF_MARKDOWN_MENU_SIGNAL_CACHE`. Require at least two repeats, exact AB/BA order validation, equal observed work, Release configuration, axis-specific counters, and all-pair improvement gates.
- `make perf-frontend-profile` for daily frontend smoke
- `make perf-frontend-profile-standard` before stronger local confidence
- `make perf-frontend-profile-full` before release-grade validation
- `scripts/perf-frontend-profile.sh --include-hover` when preview work needs direct hover-preview bucket evidence
- `make perf-unified-table` when correlating frontend and backend evidence, including `warm-load-summary.json` when present
- When a profile adds new evidence beyond the release note, add a versioned doc under `doc/perf/release-profiles/` and point `profile_doc` at it
- XCTest performance inputs and in-progress outputs must use the test bundle, DerivedData, or `/tmp`, not runtime `#filePath` or direct repository paths under `~/Documents`. Copy only completed evidence back to `logs/` after the test succeeds.
- Display-link callback intervals describe callback cadence, not presented frames. Never relabel them FPS without compositor-backed evidence.

### Documentation And Release Validation

- `make docs-validate`
- `make release-validate`
- `make tag-release`
- `make quality-manifest-self-test` when changing quality evidence tooling

## Common Change Playbooks

### Search Behavior

- Touch `SearchRequest`, `SearchMode`, and search engine code together.
- Keep exact-search query normalization shared between `SearchPlanner.planExact` and `SearchEngineImpl.searchExact`.
- Re-check `SearchCoverage`, refine behavior, and any recent-only hint paths together.
- Re-check header controls, search hints, pagination, and requirements docs.
- Run search-focused performance validation, not only unit tests.

### Clipboard Or Storage Semantics

- Touch `ClipboardMonitor`, `ClipboardService`, and `StorageService` as one flow.
- Re-check copy/replay semantics, external storage validation, cleanup behavior, and any item-model field assumptions.
- Route new cleanup variants through `StorageService.applyDeletePlan` unless there is a specific atomicity reason to keep the path separate.

### Settings Or Hotkey Changes

- Touch `SettingsDTO`, settings pages, `SettingsView`, and runtime hotkey flow together.
- Preserve Save/Cancel and `settingsChanged` behavior.
- Verify `/tmp/scopy_hotkey.log` behavior when the hotkey path changes.

### Preview Or Export Changes

- Touch preview UI, rendering pipeline, and `MarkdownExportService` together.
- Keep hover preview planning in `HistoryHoverPreviewPipeline`; row views should apply typed events rather than own decode/cache/metric policy.
- For hover-preview work, run a focused test plus `scripts/perf-frontend-profile.sh --include-hover` so Markdown and image hover buckets are present.
- For hover-transfer changes, cover pure geometry/session behavior, controller cancellation and generation replacement, list-level transfer ownership, stale popover-token geometry, and XCUI trajectories both through and outside the real corridor.
- Run strict-concurrency coverage because the controller lifecycle is task-based. Treat the include-hover frontend profile as a broad rendering regression smoke; do not claim it measures safe-triangle travel unless its automation explicitly crosses row-to-popover geometry.
- For Markdown renderer fixes, update focused renderer tests such as `KaTeXRenderToStringTests` / `MarkdownMathRenderingTests`, and add export UI coverage when the PNG output contract changes.
- Re-check pngquant settings interactions, preview latency, and output pasteboard behavior.

### File Action Or Context Menu Changes

- Keep file-system action resolution behind `ClipboardServiceProtocol.fileURLs(itemID:)`; views should not read persistence or storage paths directly.
- Treat AirDrop and Open Containing Folder as different contracts: AirDrop may use temporary PNGs for image rows, while Open Containing Folder must only reveal real source files.
- Update unit coverage for service URL resolution and UI coverage for menu visibility/action identifiers in the same change.

### Release Or Documentation Changes

- Update metadata, release note, release index, changelog, and any active current docs that changed semantically.
- For release/versioning fixes, test both `scripts/version.sh --tag` and the release packaging path so the app bundle version, DMG name, and release metadata resolve from the same tag.
- Avoid putting new truth into compatibility directories or legacy archives.

## Important Invariants

- `project.yml` is the baseline source for Swift/Xcode/deployment targets.
- Active docs live under `doc/current`, `doc/releases`, and `doc/meta`.
- Legacy directories under `doc/implementation`, `doc/profiles`, and `doc/specs` are compatibility entrypoints only.
- Heavy work should stay off the main thread; correctness beats opportunistic speedups.
- Views should not directly become persistence clients.

## Related Docs

- Active requirements: [product-spec.md](./product-spec.md)
- Release workflow: [release-runbook.md](./release-runbook.md)
- Short maintainer navigation: [maintainer-guide.md](./maintainer-guide.md)
- Current release window: [../releases/README.md](../releases/README.md)
