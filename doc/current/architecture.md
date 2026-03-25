---
doc_type: spec
status: active
owner: maintainers
last_reviewed: 2026-03-25
canonical: true
related_versions:
  - v0.64
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
- `ClipboardService` coordinates ingest, deduplication, cleanup scheduling, and event emission.
- `StorageService` persists structured items, external payloads, and thumbnail-related artifacts.

### Search Path

- UI and state layers issue typed `SearchRequest` values through backend protocols.
- Backend search uses SQLite-backed storage/indexing plus mode-specific search behavior exposed through `SearchMode`.
- Search results flow back through observables/view models rather than direct view-to-storage access.

### UI And Preview Path

- App/UI shell manages the menubar icon, floating panel, settings window, and preview/export flows.
- Markdown preview assets and bundled tools are staged by build scripts rather than copied ad hoc at runtime.
- Preview and export flows must treat stored content as source-of-truth input, not a side channel that mutates persisted data.

## Operational Invariants

- Views must not directly touch database or filesystem persistence; state and protocols remain the integration boundary.
- Settings retain the explicit Save/Cancel model, while hotkey application still flows through `AppDelegate.applyHotKey` and `.settingsChanged`.
- Cleanup, external file reads/writes, thumbnail work, and other heavy operations should remain backgrounded and bounded.
- External storage access continues to require path validation before file operations.
- Documentation/release automation reads [release-current.yml](../meta/release-current.yml) as the machine-readable source of truth.

## Stability Priorities

- Favor structured concurrency and bounded work queues over detached or unbounded background work.
- Keep correctness above opportunistic performance shortcuts: fallback paths should preserve complete results and safe deletion behavior.
- Treat protocol-first layering and explicit test surfaces as part of the architecture, not just implementation style.

## Where To Put Future Design Work

- New capabilities that are not yet committed belong in [doc/proposals](../proposals/README.md).
- Historical deep dives and prior optimization reasoning belong in [doc/archive/specs](../archive/specs/README.md).
