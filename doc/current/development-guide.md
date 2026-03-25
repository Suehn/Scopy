---
doc_type: guide
status: active
owner: maintainers
last_reviewed: 2026-03-25
canonical: true
related_versions:
  - v0.64
---

# Development Guide

This document is the canonical implementation guide for the current Scopy codebase. It explains how the repo is structured, how the main runtime paths work, and how to safely change the project without drifting from release, performance, and documentation contracts.

## Reference State

- Reference release: `v0.64`
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

1. `HistoryViewModel.load()` and `loadMore()` use `fetchRecent(limit:offset:)` for plain recent-history pagination.
2. `HistoryViewModel.search()` builds a `SearchRequest` and calls `search(query:)`.
3. `SearchEngineImpl` executes mode-specific behavior for `exact`, `fuzzy`, `fuzzyPlus`, and `regex`.
4. UI updates are event-driven; the list should not depend on ad hoc full reloads for ordinary mutations.
5. Search results expose `SearchCoverage` so UI can distinguish complete results, staged fuzzy refinement, and intentional recent-only limits.
6. Production search paths should construct `SearchCoverage` directly; `isPrefilter` remains a compatibility shim for legacy and test callers only.

Implication: changes to search semantics belong in the request model, search engine, and user-visible docs together.

### 4. Preview And Export

1. `HistoryItemView` routes hover interactions into image, text, and file preview flows.
2. `HoverPreviewLoader` owns image/file preview decode and downsampling helpers so the row view does not carry raw ImageIO logic.
3. Markdown/LaTeX preview rendering is handled in the text preview path and export pipeline.
4. `MarkdownExportService` now lives under `Scopy/Services/Export` and produces PNG output back to the pasteboard through `ScopyKit`.
5. pngquant settings affect both image history optimization and Markdown/LaTeX export compression where enabled.

Implication: preview/export work must remain background-safe and should not mutate unrelated persisted content.

### 4.5 List Interaction Coordination

1. `HistoryListView` owns `HistoryListInteractionCoordinator` and passes it into rows / observers as list-scoped state.
2. Row lifecycle should hold observation tokens, not raw UUID registrations, so observer cleanup is ownership-driven.
3. Scroll and pointer suppression should stay list-local; do not reintroduce process-global hover/scroll coordination state.

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

### Item Actions

- Context menu actions for copy / pin / delete
- File note editing for file items
- Image optimization for stored image items
- Hover preview for text, image, and file content

### Export And Media

- Markdown/LaTeX render and PNG export
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
- `make test-unit`
- `make test-strict` for concurrency-sensitive work
- `make test-tsan` when the environment supports the hosted test path; the command auto-skips the known-bad `macOS 26.4 (25E241) + Xcode 26.2 (17C52)` hosted runtime combination
- Hosted TSan CI lives in `.github/workflows/tsan.yml` on `macos-15 + Xcode 16.0`; treat that workflow as the supported real-coverage path until the local Apple runtime issue is resolved

### Performance Validation

- `make test-snapshot-perf-release` for release-path backend perf gates
- `make perf-search-warm-load` for backend full-index warm-load latency and peak RSS
- `make perf-frontend-profile` for daily frontend smoke
- `make perf-frontend-profile-standard` before stronger local confidence
- `make perf-frontend-profile-full` before release-grade validation
- `make perf-unified-table` when correlating frontend and backend evidence, including `warm-load-summary.json` when present
- When a profile adds new evidence beyond the release note, add a versioned doc under `doc/perf/release-profiles/` and point `profile_doc` at it

### Documentation And Release Validation

- `make docs-validate`
- `make release-validate`
- `make tag-release`

## Common Change Playbooks

### Search Behavior

- Touch `SearchRequest`, `SearchMode`, and search engine code together.
- Re-check `SearchCoverage`, refine behavior, and any recent-only hint paths together.
- Re-check header controls, search hints, pagination, and requirements docs.
- Run search-focused performance validation, not only unit tests.

### Clipboard Or Storage Semantics

- Touch `ClipboardMonitor`, `ClipboardService`, and `StorageService` as one flow.
- Re-check copy/replay semantics, external storage validation, cleanup behavior, and any item-model field assumptions.

### Settings Or Hotkey Changes

- Touch `SettingsDTO`, settings pages, `SettingsView`, and runtime hotkey flow together.
- Preserve Save/Cancel and `settingsChanged` behavior.
- Verify `/tmp/scopy_hotkey.log` behavior when the hotkey path changes.

### Preview Or Export Changes

- Touch preview UI, rendering pipeline, and `MarkdownExportService` together.
- Re-check pngquant settings interactions, preview latency, and output pasteboard behavior.

### Release Or Documentation Changes

- Update metadata, release note, release index, changelog, and any active current docs that changed semantically.
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
