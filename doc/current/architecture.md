---
doc_type: spec
status: active
owner: maintainers
last_reviewed: 2026-07-11
canonical: true
related_versions:
  - v0.70.0
  - v0.65.0
---

# Architecture

This document describes the current system shape and operational invariants. For repository workflow, runtime change entrypoints, and validation guidance, use [development-guide.md](./development-guide.md). The historical optimization supplement is preserved in [architecture-v0-supplement-legacy.md](../archive/specs/architecture-v0-supplement-legacy.md).

## Current System Shape

- `Scopy` app target owns app lifecycle, panel/window orchestration, observables, presentation logic, and views.
- `ScopyKit` owns the backend domain/application/infrastructure/services layer and is imported by the app and tests.
- `ScopyUISupport` holds reusable UI support code shared by app-side views.
- `ScopyBench` provides benchmark tooling for backend/perf verification.

## Runtime Data Flow

### Clipboard Path

- `ClipboardMonitor` observes pasteboard changes and normalizes incoming clipboard content.
- `ClipboardMonitor` publishes durable external captures to an Application Support-owned ingest spool before handing work to the service. Pending envelopes remain replayable across process restart; terminal markers make acknowledgement restart-safe.
- `ClipboardService` coordinates ingest, deduplication, cleanup scheduling, and event emission. It publishes search/UI changes only from committed storage outcomes and hands committed cleanup events to an independent cancellation lifetime.
- `StorageService` persists structured items, external payloads, and thumbnail-related artifacts. For a durable ingest ID it retains the source, publishes a unique managed candidate, and commits the item mutation plus the schema-v8 `ingest_receipts` row in one `BEGIN IMMEDIATE` transaction.
- Cleanup planning is advisory. `SQLiteClipboardRepository.commitDeletePlan` revalidates the candidate snapshot and deletes matching rows in one write transaction, then returns the exact committed IDs and storage refs used by bounded file cleanup, search invalidation, and one bulk history event.

### Search Path

- UI and state layers issue typed `SearchRequest` values through backend protocols.
- Backend search uses SQLite-backed storage/indexing plus mode-specific search behavior exposed through `SearchMode`.
- Search results flow back through observables/view models rather than direct view-to-storage access.

### UI And Preview Path

- App/UI shell manages the menubar icon, floating panel, settings window, and preview/export flows.
- History action flows resolve shareable file URLs through backend protocols; UI rows decide visibility from DTO-level capability hints and do not directly read storage internals.
- Markdown preview/export uses one local CommonMark/GFM-to-HTML pipeline for preview and PNG: stable footnote IDs, HTML-only KaTeX, syntax highlighting, tasks/tables/citations, a closed safe-HTML AST extension with all residual HTML literalized, bounded source-profile repair, strict `scopy-rich` v2 web/image/news/weather/finance/currency envelopes, and one field-preserving consecutive-public-image presentation adapter. Missing assets and invalid rich envelopes fail visibly; there is no alternate renderer, silent fallback, or prose-to-card inference. The normative semantics, typography, responsive layout, evidence boundary, and verification matrix live in [markdown-chatgpt-wacz-style-contract.md](./markdown-chatgpt-wacz-style-contract.md).
- Markdown preview assets and bundled tools are one manifest-verified release unit. The renderer IIFE, its sidecar, KaTeX CSS, and the complete lockfile-matched KaTeX font set are generated/verified together and staged once in their canonical subdirectories; flat duplicate bundle resources are a build failure rather than a cross-machine fallback.
- Rich cards may resolve only assets from the bundled closed allowlist. Preview hydrates deterministic controls from frozen envelope data; export freezes the same DOM before PDF or snapshot capture. No renderer path fetches remote images, live weather, market data, exchange rates, or hidden citation targets.
- Navigation is split by destination class. Fragment links stay inside the WebView; validated HTTP(S) and strict Codex absolute-file links cross the native boundary only after explicit user activation; every other scheme/path form is cancelled.
- Each Markdown WebView navigation has a render ID. Only current main-frame readiness/metrics may update preview state, and metric equality includes overflow plus success/error state as well as geometry.
- Terminal readiness is a conjunction of renderer completion, stylesheet readiness, font readiness, terminal local-image state, runtime hydration, paint completion, and measured layout. Resize/toggle bursts are coalesced through one animation-frame epoch; preview opacity is enabled only after current-owner terminal success, while export times out as failure rather than snapshotting a merely nonzero but incomplete DOM.
- The shared preview controller also carries an owner lease. Only the current SwiftUI representable may attach, navigate, configure scrolling, or detach it; identical in-flight HTML is a no-op, and scroll setup retries until WebKit's internal `NSScrollView` exists. Hidden premeasurement must not share the controller.
- Preview and export flows must treat stored content as source-of-truth input, not a side channel that mutates persisted data.

## Operational Invariants

- Views must not directly touch database or filesystem persistence; state and protocols remain the integration boundary.
- System sharing may materialize temporary files for explicit user actions, but file-reveal actions must remain constrained to real user files.
- Settings retain the explicit Save/Cancel model, while hotkey application still flows through `AppDelegate.applyHotKey` and `.settingsChanged`.
- Cleanup, external file reads/writes, thumbnail work, and other heavy operations should remain backgrounded and bounded.
- External storage access continues to require path validation before file operations.
- A durable ingest source is not moved or deleted before the database commit. Receipt replay is an internal no-op, including after the committed item has since been deleted, and acknowledgement reaches a non-replay terminal marker before receipt removal.
- File deletion is DB-first and consumes only commit-time validated refs. Planned rows that became pinned or changed payload identity are skipped, and shared refs are rechecked under path reservations before unlink.
- The storage protocol claims D1 process-crash/restart consistency only; WAL `synchronous=NORMAL` and unsynced rename/write paths are not a D2/D3 power-loss guarantee.
- Documentation/release automation reads [release-current.yml](../meta/release-current.yml) as the machine-readable source of truth.

## Stability Priorities

- Favor structured concurrency and bounded work queues over detached or unbounded background work.
- Keep correctness above opportunistic performance shortcuts: fallback paths should preserve complete results and safe deletion behavior.
- Treat protocol-first layering and explicit test surfaces as part of the architecture, not just implementation style.

## Where To Put Future Design Work

- New capabilities that are not yet committed belong in [doc/proposals](../proposals/README.md).
- Historical deep dives and prior optimization reasoning belong in [doc/archive/specs](../archive/specs/README.md).
