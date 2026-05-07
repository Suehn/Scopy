# Research: Grill Q2 Next Product-Code Candidate

- Query: After the Verification Evidence Manifest Module is in place, which next product-code architecture candidate should be implemented now: Storage DeletePlan executor, HistoryHoverPreviewPipeline, or another candidate only if evidence makes it clearly superior?
- Scope: internal
- Date: 2026-05-07

## Findings

### Recommended Answer

Implement **Storage DeletePlan executor** next.

This should be the second implementation slice because it gives the highest near-term Depth with the lowest product risk. The current code already has the domain concept and a partial executor, so the implementation is a consolidation of an existing safety rule rather than a new behavior path. It concentrates DB-first deletion, storageRef validation, bounded file deletion, cache invalidation, and privacy-safe logging into one internal Module with a small Interface.

The accepted first slice, Verification Evidence Manifest Module, was intentionally tooling-only. The next slice should move into product code, but the best first product-code move is still the one with the clearest safety Seam and focused tests. Storage DeletePlan executor fits that better than hover preview right now.

### Files Found

- `Scopy/Services/StorageService.swift` - product-facing storage Module; owns SQLite repository coordination, external payload paths, cleanup policy, deletion, validation, bounded file deletion, and cache invalidation.
- `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift` - SQL Adapter; owns DeletePlan construction and DB-first row deletion in repository transactions.
- `ScopyTests/StorageServiceTests.swift` - focused cleanup tests for count limits, pinned preservation, image-only cleanup, storage isolation, and storage sizing semantics.
- `ScopyTests/ResourceCleanupTests.swift` - cleanup regression tests, including all-pinned cleanup termination.
- `Scopy/Views/HistoryListView.swift` - list-level hover preview coordination and single-active-popover policy.
- `Scopy/Views/History/HistoryItemView.swift` - row-level preview tasks for image, file, markdown file, and text hover previews.
- `Scopy/Views/History/HistoryItemPreviewCoordinator.swift` - current preview identity/task-state coordinator.
- `ScopyTests/HistoryItemPreviewCoordinatorTests.swift` - focused tests for preview tokens and task cancellation, but not a full preview loading pipeline.

### Code Patterns

#### Storage DeletePlan executor has a real Seam now

The product contract requires safe external storage handling: payloads are persisted partly outside SQLite, and external storage references must be validated before filesystem operations (`doc/current/product-spec.md:36`, `doc/current/product-spec.md:39`). The same spec says cleanup/delete/optimization must not remove unrelated files and heavy cleanup work should stay off the main thread (`doc/current/product-spec.md:104`, `doc/current/product-spec.md:114`). The architecture spec repeats the same invariants: cleanup and external file work should be backgrounded and bounded, and external storage access requires path validation (`doc/current/architecture.md:47`, `doc/current/architecture.md:48`).

`StorageService.deleteItem(_:)` already implements the DB-first external-safe sequence for one item: delete/capture the DB row first, validate the storageRef, then remove the file in a detached utility task (`Scopy/Services/StorageService.swift:422`, `Scopy/Services/StorageService.swift:424`, `Scopy/Services/StorageService.swift:428`, `Scopy/Services/StorageService.swift:435`). `deleteAllExceptPinned()` repeats the same larger-batch shape: repository transaction first, validated refs, bounded file deletion, then external-size cache invalidation (`Scopy/Services/StorageService.swift:455`, `Scopy/Services/StorageService.swift:457`, `Scopy/Services/StorageService.swift:460`, `Scopy/Services/StorageService.swift:466`, `Scopy/Services/StorageService.swift:474`).

`applyDeletePlan(_:logContext:)` is already the partial internal Module: its Interface is a DeletePlan plus logContext, and its Implementation owns DB-first batch deletion, ref validation, bounded file deletion, and cache invalidation (`Scopy/Services/StorageService.swift:941`, `Scopy/Services/StorageService.swift:945`, `Scopy/Services/StorageService.swift:947`, `Scopy/Services/StorageService.swift:953`, `Scopy/Services/StorageService.swift:961`). But the Seam is not yet the single owner. Composite cleanup uses it (`Scopy/Services/StorageService.swift:931`, `Scopy/Services/StorageService.swift:937`), while cleanupByCount and sibling cleanup paths still duplicate the executor sequence instead of routing through it (`Scopy/Services/StorageService.swift:967`, `Scopy/Services/StorageService.swift:974`, `Scopy/Services/StorageService.swift:977`, `Scopy/Services/StorageService.swift:983`).

This passes the deletion test: if the executor Module is deleted, its rules reappear across every cleanup/delete caller. Deepening it improves Locality because future safety changes happen at one Seam. It also improves Leverage because focused tests can cross the same Interface for multiple product paths.

#### Existing Adapters make this low-risk and testable

`StorageService` already has a concrete `StorageFileOps` Adapter for file removal (`Scopy/Services/StorageService.swift:58`, `Scopy/Services/StorageService.swift:60`, `Scopy/Services/StorageService.swift:67`). That means tests can observe or fail file removal without introducing a broad generic filesystem Module.

`SQLiteClipboardRepository` already supplies the SQL Adapter side by returning plans and deleting batches in transactions. The selected slice should keep SQL planning inside the repository and should not move raw SQL into `StorageService`.

Existing tests cover the product cleanup shape but not the executor as the central Interface. Current research identified coverage for cleanup count, pinned preservation, images-only cleanup by size/count, storage isolation, and all-pinned termination (`.trellis/tasks/05-07-architecture-quality-deepening/research/backend-stability.md:97`, `.trellis/tasks/05-07-architecture-quality-deepening/research/backend-stability.md:99`). The next implementation should add focused StorageFileOps-based tests for invalid refs skipped, DB failure does not call removeFile, and newly routed cleanup paths preserve cache invalidation and no-op behavior.

#### Why this beats HistoryHoverPreviewPipeline now

`HistoryHoverPreviewPipeline` is still a strong follow-up candidate. The frontend research recommends it first for direct UI/runtime architecture because hover preview remains the thickest frontend Module (`.trellis/tasks/05-07-architecture-quality-deepening/research/frontend-hot-paths.md:116`, `.trellis/tasks/05-07-architecture-quality-deepening/research/frontend-hot-paths.md:118`). The product contract also makes preview important: text, image, and file hover previews are current user-facing capabilities (`doc/current/product-spec.md:55`, `doc/current/product-spec.md:57`).

However, the current preview Implementation has a wider blast radius. `HistoryListView` owns one active popover, pending popover state, dismissal snapshots, and the shared Markdown WebView controller (`Scopy/Views/HistoryListView.swift:33`, `Scopy/Views/HistoryListView.swift:38`, `Scopy/Views/HistoryListView.swift:39`, `Scopy/Views/HistoryListView.swift:40`). It schedules popover presentation and coordinates re-hover behavior (`Scopy/Views/HistoryListView.swift:195`, `Scopy/Views/HistoryListView.swift:222`). `HistoryItemView` separately owns image preview prefetch/decode/cache/presentation (`Scopy/Views/History/HistoryItemView.swift:1037`, `Scopy/Views/History/HistoryItemView.swift:1052`, `Scopy/Views/History/HistoryItemView.swift:1067`, `Scopy/Views/History/HistoryItemView.swift:1097`, `Scopy/Views/History/HistoryItemView.swift:1109`), file preview QuickLook/video/image paths (`Scopy/Views/History/HistoryItemView.swift:1119`, `Scopy/Views/History/HistoryItemView.swift:1159`, `Scopy/Views/History/HistoryItemView.swift:1161`, `Scopy/Views/History/HistoryItemView.swift:1171`, `Scopy/Views/History/HistoryItemView.swift:1198`), and text/Markdown detection/render/cache/presentation (`Scopy/Views/History/HistoryItemView.swift:1483`, `Scopy/Views/History/HistoryItemView.swift:1504`, `Scopy/Views/History/HistoryItemView.swift:1535`, `Scopy/Views/History/HistoryItemView.swift:1575`, `Scopy/Views/History/HistoryItemView.swift:1583`).

The preview coordinator only owns tokens and task references today; tests cover cancellation and token invalidation, not preview loading semantics (`Scopy/Views/History/HistoryItemPreviewCoordinator.swift:13`, `Scopy/Views/History/HistoryItemPreviewCoordinator.swift:14`, `Scopy/Views/History/HistoryItemPreviewCoordinator.swift:15`, `ScopyTests/HistoryItemPreviewCoordinatorTests.swift:7`, `ScopyTests/HistoryItemPreviewCoordinatorTests.swift:69`). A proper preview pipeline would therefore need more design and more verification: UI behavior, popover identity, WebView reuse, QuickLook/video behavior, markdown rendering, cache semantics, and frontend profiling.

The frontend profile harness already names hover metrics, but the latest frontend research caveat says standard scenarios did not exercise hover-preview rendering enough to make performance claims (`scripts/perf-frontend-profile.sh:212`, `.trellis/tasks/05-07-architecture-quality-deepening/research/frontend-hot-paths.md:145`). Memory from prior Scopy perf work also warns that row-level or frontend micro-optimizations can look plausible but fail on real snapshot metrics, and that profile evidence should decide frontend changes. That makes hover preview a good third slice after the storage executor, not the best second slice.

### Accepted Q2 Decision

Question: After the quality manifest is in place, which next product-code architecture candidate should be implemented now?

Recommended answer: **Storage DeletePlan executor**.

Reasoning:

1. It is product code, so it advances beyond the tooling-only first slice.
2. It deepens an existing Module rather than inventing a new broad abstraction.
3. It has a real Seam: DeletePlan execution already exists but is inconsistently used.
4. It has a real Adapter: `StorageFileOps` already makes file removal testable.
5. It improves correctness Locality for safety-critical external-file deletion.
6. It has a smaller verification surface than hover preview, while preserving behavior.

### Implementation Boundary

Implement only the Storage DeletePlan executor slice:

- Keep `StorageService` as the product-facing Module.
- Keep `SQLiteClipboardRepository` as the SQL Adapter and keep DeletePlan construction there.
- Promote `applyDeletePlan(_:logContext:)` into the single internal executor Seam for cleanup plan execution.
- Route `cleanupByCount`, `cleanupImagesOnlyByCount`, `cleanupByAge`, `cleanupBySize`, and `cleanupExternalStorage` through the executor.
- Consider routing `deleteAllExceptPinned()` through a compatible plan only if it does not distort the Interface; otherwise leave it as a separate batch-delete path and document why.
- Do not change cleanup policy, retention thresholds, item ordering, pinned semantics, external-size accounting, search behavior, preview behavior, UI strings, settings semantics, or release metadata.
- Do not introduce a generic FileStorageAdapter. The file Seam is domain-specific: validated external payload deletion.

### Risks

- A mechanical consolidation can accidentally change no-op behavior, especially when a plan has IDs but no file refs, or file refs but no valid paths.
- Cache invalidation timing must remain equivalent. Current paths invalidate even when there are no valid file URLs after DB deletion.
- Error ordering must stay DB-first. If repository deletion throws, file removal must not run.
- Logging should retain the contextual logContext so future debugging still identifies count, age, size, external, clear-all, or composite cleanup.
- Because `StorageService` is `@MainActor`, file deletion must remain detached and bounded rather than moving heavy I/O back onto the main actor.

### Required Verification Gates

Focused tests to add or extend:

- Unit test: executor skips invalid storageRefs and still completes DB deletion/cache invalidation.
- Unit test: injected `StorageFileOps.removeFile` is not called when repository delete fails.
- Unit test: routed cleanupByCount/imagesOnly/age/size/external paths preserve existing item counts and pinned behavior.
- Unit test: deleteAllExceptPinned remains DB-first and external-safe whether routed through the executor or intentionally left separate.

Required commands after implementation:

- `make build`
- `make test-unit`
- `make test-strict`
- Run the new focused StorageService tests directly if full unit output makes failures hard to isolate.

Conditional gates:

- Run `make test-snapshot-perf-release` only if cleanup planning, large-delete behavior, size accounting, or repository SQL changes beyond consolidation.
- Product frontend performance gates are not required for this Storage slice because it does not touch search, scrolling, thumbnails, preview, or rendering.

## Related Specs

- `.trellis/spec/backend/database-guidelines.md` - StorageService owns SQLite plus external files; external deletion is DB-first and cleanup changes require unit plus snapshot performance tests when behavior/perf-sensitive.
- `.trellis/spec/backend/quality-guidelines.md` - backend changes must preserve actor isolation, avoid blocking the main actor, and keep DB/search/storage/settings/UI state consistent.
- `.trellis/spec/frontend/component-guidelines.md` - relevant for the deferred hover preview candidate; expensive preview/markdown/thumbnail behavior should stay behind caches/controllers/profile hooks.
- `.trellis/spec/frontend/hook-guidelines.md` - relevant for the deferred hover preview candidate; long-running preview work must be cancellable and owned by coordinator/view-model-like Modules rather than repeated render paths.

## External References

- No external documentation was required. This decision is based on internal task artifacts, local specs, current source code, and existing memory about Scopy frontend performance validation.

## Caveats / Not Found

- No product code was modified during this research pass.
- No tests or benchmarks were run during this research pass.
- No repo `CONTEXT.md` or ADR files were found, so architecture vocabulary is from the requested `improve-codebase-architecture` skill.
- The recommendation does not reject `HistoryHoverPreviewPipeline`. It remains the strongest direct UI/runtime follow-up after Storage DeletePlan executor, especially if the next slice adds a hover-specific profile or focused preview UI smoke.
- Search index lifecycle remains a higher-risk follow-up candidate, not the recommended second slice.
