# Research: Backend Search Storage Stability

- Query: Research Scopy backend/search/storage/clipboard architecture deepening opportunities for performance, stability, and maintainability.
- Scope: internal
- Date: 2026-05-07

## Findings

### Task Context

The task asks for evidence-backed architecture deepening, at least three candidates, a ranked recommendation, and consistent use of Module, Interface, Implementation, Depth, Seam, Adapter, Leverage, and Locality.

Current release metadata is v0.7.6. Product and development constraints come from doc/current/product-spec.md and doc/current/development-guide.md. The relevant contracts are:

- Search modes remain Exact, Fuzzy, Fuzzy+, and Regex. Exact length >= 3 must cover complete history. Exact length <= 2 intentionally searches only the most recent 2000 items. Regex is intentionally recent-only (doc/current/product-spec.md:50, doc/current/product-spec.md:69, doc/current/product-spec.md:78, doc/current/product-spec.md:79).
- External payload handling must validate storage references before filesystem operations (doc/current/product-spec.md:37, doc/current/product-spec.md:39).
- Cleanup, delete, and optimization paths must not remove or rewrite unrelated files (doc/current/product-spec.md:104).
- Heavy I/O, hashing, indexing, cleanup, preview, and export should stay off the main thread (doc/current/product-spec.md:114).
- Baseline remains macOS 14, Swift 5.9, and Xcode 16 (doc/current/product-spec.md:119, project.yml:6, project.yml:31, project.yml:32).
- Backend sources are provided through ScopyKit and excluded from the app target (project.yml:60, project.yml:61, project.yml:64, project.yml:67, project.yml:68, Package.swift:10, Package.swift:16).

### Files Found

- Scopy/Application/ClipboardService.swift - actor facade that composes monitor, storage, search, settings, events, cleanup, thumbnails, and file-size computation.
- Scopy/Services/ClipboardMonitor.swift - MainActor pasteboard monitor, content classification, durable ingest spool, backpressure metrics, replay, and pasteboard writes.
- Scopy/Services/StorageService.swift - MainActor storage facade over SQLite repository plus external files, cleanup planning, stats, validation, and thumbnails.
- Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift - actor that owns SQL, transactions, row parsing, delete plans, and metadata counters.
- Scopy/Infrastructure/Search/SearchEngineImpl.swift - actor that owns search execution, recent cache, full and short indexes, disk cache coordination, and performance metrics.
- Scopy/Infrastructure/Search/SearchPlanner.swift - decision-only search plan Module for path identity, coverage, reason, capabilities, and diagnostics.
- Scopy/Infrastructure/Search/SearchIndexDiskCache.swift - full/short search index disk cache load, preflight, write, and validation helpers.
- Scopy/Infrastructure/Settings/SettingsStore.swift - actor-backed settings source of truth.
- Scopy/Utilities/AsyncPermitPool.swift - actor utility for bounded concurrency.
- Scopy/Utilities/BestEffortFileOps.swift - logging wrapper for best-effort file remove, move, read, and decode operations.
- ScopyTests/SearchPlannerTests.swift - planner branch coverage.
- ScopyTests/SearchServiceTests.swift and ScopyTests/SearchBackendConsistencyTests.swift - search semantics, coverage, pagination, and cache invalidation tests.
- ScopyTests/FullIndexDiskCacheHardeningTests.swift - full-index disk-cache hit, fallback, and reason tests.
- ScopyTests/StorageServiceTests.swift and ScopyTests/ResourceCleanupTests.swift - cleanup behavior, pinned preservation, images-only behavior, and connection cleanup tests.
- ScopyTests/ClipboardMonitorTests.swift - pasteboard classification, large-content spool/replay, and corrupt envelope tests.
- Tools/ScopyBench/main.swift, Makefile, scripts/perf-search-warm-load.sh - release search/service benchmark and warm-load evidence paths.

### Related Specs

- .trellis/spec/backend/search-guidelines.md:7 defines the decision-only SearchPlanner scenario.
- .trellis/spec/backend/search-guidelines.md:20 says SearchEngineImpl.search(request:) remains the public search entrypoint and callers must not use SearchPlanner as a public Adapter or execution Interface.
- .trellis/spec/backend/search-guidelines.md:27 forbids SearchPlanner from owning SQLite connections, executing SQL, mutating caches, building runner closures, or changing result semantics.
- .trellis/spec/backend/search-guidelines.md:28 allows shared pure predicates/tokenization on SearchPlanner when planner and engine need the same rule.
- .trellis/spec/backend/search-guidelines.md:49 and .trellis/spec/backend/search-guidelines.md:53 require representative planner tests plus build/unit/snapshot perf after search internals change.
- .trellis/spec/backend/database-guidelines.md:7 documents SQLite plus external files and keeps StorageService as owner of thresholds and external path setup.
- .trellis/spec/backend/database-guidelines.md:15 keeps raw SQLite access in repository/connection actors and prepared statements.
- .trellis/spec/backend/database-guidelines.md:41 requires SearchRequest, SearchMode, SearchSortMode, and SearchCoverage alignment across engine, UI, docs, and tests.
- .trellis/spec/backend/database-guidelines.md:53 says external file deletion is DB-first and cleanup changes need unit plus snapshot performance tests.
- .trellis/spec/backend/database-guidelines.md:61 keeps SettingsStore as the settings source of truth.
- .trellis/spec/backend/quality-guidelines.md:7 requires actor-based shared state and protocol/DTO-facing contracts.
- .trellis/spec/backend/quality-guidelines.md:17 forbids blocking the main actor with DB, search, file, or cleanup work and forbids semantic changes without focused tests.
- .trellis/spec/backend/quality-guidelines.md:27 and .trellis/spec/backend/quality-guidelines.md:37 define default and performance-sensitive backend gates.

## Code Patterns

### Pattern 1: SearchEngineImpl is externally deep but internally broad

SearchEngineImpl has a narrow public Interface, but its Implementation owns raw connection state, recent cache, full index, short-query index, pending events, disk-cache persist tasks, fuzzy sorted cache, corpus metrics, timeouts, and scratch arrays in one actor (Scopy/Infrastructure/Search/SearchEngineImpl.swift:903, Scopy/Infrastructure/Search/SearchEngineImpl.swift:908, Scopy/Infrastructure/Search/SearchEngineImpl.swift:913, Scopy/Infrastructure/Search/SearchEngineImpl.swift:930, Scopy/Infrastructure/Search/SearchEngineImpl.swift:937, Scopy/Infrastructure/Search/SearchEngineImpl.swift:957, Scopy/Infrastructure/Search/SearchEngineImpl.swift:978, Scopy/Infrastructure/Search/SearchEngineImpl.swift:980, Scopy/Infrastructure/Search/SearchEngineImpl.swift:983).

Mutation handling and lifecycle state are interleaved with search execution. Upsert, pin, deletion, clear-all, recent-cache reset, full-index reset, and short-index reset live in the same Module (Scopy/Infrastructure/Search/SearchEngineImpl.swift:1041, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1050, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1091, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1118, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1153, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1158, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1168, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1179).

Background index builds capture generation, mutation counter, DB change token, trigger, and reserve size (Scopy/Infrastructure/Search/SearchEngineImpl.swift:1235, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1249, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1312, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1331, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1340). Full index disk-cache load or rebuild happens on demand inside search execution (Scopy/Infrastructure/Search/SearchEngineImpl.swift:2574, Scopy/Infrastructure/Search/SearchEngineImpl.swift:2580, Scopy/Infrastructure/Search/SearchEngineImpl.swift:2615, Scopy/Infrastructure/Search/SearchEngineImpl.swift:2634, Scopy/Infrastructure/Search/SearchEngineImpl.swift:2652).

SearchPlanner is already a decision-only Seam. SearchEngineImpl records planner path and reason but still executes branches itself (Scopy/Infrastructure/Search/SearchEngineImpl.swift:1878, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1882). This matches the spec, so execution should not move into SearchPlanner.

### Pattern 2: Storage cleanup repeats DB-first external-safe deletion

Single-item delete captures/deletes DB first, validates storageRef, then deletes the file off-main (Scopy/Services/StorageService.swift:422, Scopy/Services/StorageService.swift:424, Scopy/Services/StorageService.swift:428, Scopy/Services/StorageService.swift:433, Scopy/Services/StorageService.swift:435).

Clear-all and cleanup paths repeat the same shape: capture refs or plan IDs, delete rows in repository transaction, validate refs, delete files with bounded concurrency, and invalidate external-size cache (Scopy/Services/StorageService.swift:455, Scopy/Services/StorageService.swift:460, Scopy/Services/StorageService.swift:466, Scopy/Services/StorageService.swift:477, Scopy/Services/StorageService.swift:493, Scopy/Services/StorageService.swift:941, Scopy/Services/StorageService.swift:945, Scopy/Services/StorageService.swift:947, Scopy/Services/StorageService.swift:953, Scopy/Services/StorageService.swift:961).

The same sequence is duplicated in cleanupByCount, cleanupImagesOnlyByCount, cleanupByAge, cleanupBySize, and cleanupExternalStorage (Scopy/Services/StorageService.swift:967, Scopy/Services/StorageService.swift:974, Scopy/Services/StorageService.swift:977, Scopy/Services/StorageService.swift:983, Scopy/Services/StorageService.swift:994, Scopy/Services/StorageService.swift:1001, Scopy/Services/StorageService.swift:1004, Scopy/Services/StorageService.swift:1010, Scopy/Services/StorageService.swift:1022, Scopy/Services/StorageService.swift:1030, Scopy/Services/StorageService.swift:1033, Scopy/Services/StorageService.swift:1039, Scopy/Services/StorageService.swift:1053, Scopy/Services/StorageService.swift:1060, Scopy/Services/StorageService.swift:1063, Scopy/Services/StorageService.swift:1069, Scopy/Services/StorageService.swift:1084, Scopy/Services/StorageService.swift:1097, Scopy/Services/StorageService.swift:1100, Scopy/Services/StorageService.swift:1102).

StorageService already has a concrete Adapter for file removal via StorageFileOps (Scopy/Services/StorageService.swift:58, Scopy/Services/StorageService.swift:60, Scopy/Services/StorageService.swift:67). That makes the delete executor testable without introducing a broad generic filesystem Module.

### Pattern 3: ClipboardMonitor mixes pasteboard polling, classification, and durable ingest queue

ClipboardMonitor stores pasteboard/timer state next to durable ingest queue state: pendingLargeContent, trackedPendingEnvelopePaths, activeIngestTasks, max concurrency, queueLock, contentQueue, and ingestSpoolDirectory (Scopy/Services/ClipboardMonitor.swift:235, Scopy/Services/ClipboardMonitor.swift:237, Scopy/Services/ClipboardMonitor.swift:242, Scopy/Services/ClipboardMonitor.swift:243, Scopy/Services/ClipboardMonitor.swift:244, Scopy/Services/ClipboardMonitor.swift:245, Scopy/Services/ClipboardMonitor.swift:247, Scopy/Services/ClipboardMonitor.swift:249, Scopy/Services/ClipboardMonitor.swift:252).

Start/stop monitoring replays disk envelopes, installs the timer, cancels tasks, clears pending items, and publishes metrics (Scopy/Services/ClipboardMonitor.swift:323, Scopy/Services/ClipboardMonitor.swift:330, Scopy/Services/ClipboardMonitor.swift:331, Scopy/Services/ClipboardMonitor.swift:335, Scopy/Services/ClipboardMonitor.swift:347, Scopy/Services/ClipboardMonitor.swift:350, Scopy/Services/ClipboardMonitor.swift:351).

Polling extracts raw data on MainActor and chooses sync hash or async durable ingest (Scopy/Services/ClipboardMonitor.swift:639, Scopy/Services/ClipboardMonitor.swift:657, Scopy/Services/ClipboardMonitor.swift:676, Scopy/Services/ClipboardMonitor.swift:678, Scopy/Services/ClipboardMonitor.swift:684, Scopy/Services/ClipboardMonitor.swift:693).

Async ingest persists envelopes, records soft-limit metrics, starts detached workers, loads payloads, converts TIFF to PNG, hashes, builds payloads, validates session state on MainActor, emits content, and finishes workers (Scopy/Services/ClipboardMonitor.swift:698, Scopy/Services/ClipboardMonitor.swift:715, Scopy/Services/ClipboardMonitor.swift:721, Scopy/Services/ClipboardMonitor.swift:736, Scopy/Services/ClipboardMonitor.swift:746, Scopy/Services/ClipboardMonitor.swift:761, Scopy/Services/ClipboardMonitor.swift:768, Scopy/Services/ClipboardMonitor.swift:782, Scopy/Services/ClipboardMonitor.swift:792, Scopy/Services/ClipboardMonitor.swift:806, Scopy/Services/ClipboardMonitor.swift:818, Scopy/Services/ClipboardMonitor.swift:828, Scopy/Services/ClipboardMonitor.swift:838, Scopy/Services/ClipboardMonitor.swift:846).

Envelope file operations are already clustered enough to extract: replay, persist, write, load, discover, payload lookup, payload read, and cleanup are all local (Scopy/Services/ClipboardMonitor.swift:910, Scopy/Services/ClipboardMonitor.swift:931, Scopy/Services/ClipboardMonitor.swift:972, Scopy/Services/ClipboardMonitor.swift:977, Scopy/Services/ClipboardMonitor.swift:994, Scopy/Services/ClipboardMonitor.swift:1008, Scopy/Services/ClipboardMonitor.swift:1014, Scopy/Services/ClipboardMonitor.swift:1026).

### Pattern 4: Search and storage have usable verification seams

SearchPlanner has representative tests for empty query, short Exact recent-only, long Exact FTS, Regex recent-only, fuzzy staged prefilter, forced Fuzzy+ substring fallback, short query full-index, and short-query fallback behavior (ScopyTests/SearchPlannerTests.swift:5, ScopyTests/SearchPlannerTests.swift:14, ScopyTests/SearchPlannerTests.swift:23, ScopyTests/SearchPlannerTests.swift:32, ScopyTests/SearchPlannerTests.swift:53, ScopyTests/SearchPlannerTests.swift:65, ScopyTests/SearchPlannerTests.swift:76, ScopyTests/SearchPlannerTests.swift:88).

SearchServiceTests cover user-visible coverage semantics such as Exact short recent-only and Regex recent-only (ScopyTests/SearchServiceTests.swift:51, ScopyTests/SearchServiceTests.swift:58, ScopyTests/SearchServiceTests.swift:62, ScopyTests/SearchServiceTests.swift:63, ScopyTests/SearchServiceTests.swift:103, ScopyTests/SearchServiceTests.swift:116, ScopyTests/SearchServiceTests.swift:119, ScopyTests/SearchServiceTests.swift:131, ScopyTests/SearchServiceTests.swift:133).

FullIndexDiskCacheHardeningTests already cover disk-cache hit, legacy metadata, fingerprint mismatch, SHM drift, tombstone stale, checksum mismatch, and invalid postings fallback (ScopyTests/FullIndexDiskCacheHardeningTests.swift:9, ScopyTests/FullIndexDiskCacheHardeningTests.swift:19, ScopyTests/FullIndexDiskCacheHardeningTests.swift:31, ScopyTests/FullIndexDiskCacheHardeningTests.swift:53, ScopyTests/FullIndexDiskCacheHardeningTests.swift:69, ScopyTests/FullIndexDiskCacheHardeningTests.swift:85, ScopyTests/FullIndexDiskCacheHardeningTests.swift:96).

Storage tests cover cleanup count, pinned preservation, images-only cleanup by size/count, and test storage isolation (ScopyTests/StorageServiceTests.swift:258, ScopyTests/StorageServiceTests.swift:279, ScopyTests/StorageServiceTests.swift:302, ScopyTests/StorageServiceTests.swift:330, ScopyTests/StorageServiceTests.swift:360). ResourceCleanupTests cover all-pinned cleanup termination (ScopyTests/ResourceCleanupTests.swift:39, ScopyTests/ResourceCleanupTests.swift:63, ScopyTests/ResourceCleanupTests.swift:68, ScopyTests/ResourceCleanupTests.swift:72).

ClipboardMonitorTests cover large-content durability and replay (ScopyTests/ClipboardMonitorTests.swift:854, ScopyTests/ClipboardMonitorTests.swift:886, ScopyTests/ClipboardMonitorTests.swift:892, ScopyTests/ClipboardMonitorTests.swift:927, ScopyTests/ClipboardMonitorTests.swift:935, ScopyTests/ClipboardMonitorTests.swift:973).

## Candidates

### Candidate 1: Deepen The Search Index Lifecycle Module

Files: Scopy/Infrastructure/Search/SearchEngineImpl.swift, Scopy/Infrastructure/Search/SearchIndexDiskCache.swift, Scopy/Infrastructure/Search/SearchPlanner.swift, ScopyTests/FullIndexDiskCacheHardeningTests.swift, ScopyTests/SearchServiceTests.swift, Tools/ScopyBench/main.swift, Makefile.

Problem: SearchEngineImpl is deep for callers but internally too broad. The Implementation interleaves search execution with index lifecycle, disk cache lifecycle, generation invalidation, pending event replay, tombstone decisions, and warm-load diagnostics. This creates weak Locality for performance/stability work. SearchPlanner cannot absorb this because the spec makes it decision-only.

Solution: Create an internal SearchIndexLifecycle or SearchIndexCoordinator Module under Scopy/Infrastructure/Search. Keep SearchEngineImpl.search(request:) as the public Interface. Keep SearchPlanner decision-only. The new internal Module should own mutation events, full/short index state, background build start/finish, disk-cache load/persist, tombstone stale decisions, planner state construction, and debug health. The first implementation should preserve all SQL execution, scoring, SearchCoverage, and result ordering.

Benefits: Higher Depth behind the same search Interface; better Locality for index health and warm-load work; more Leverage for future disk-cache and tombstone tests; no UI-facing contract change.

Risks: Cross-actor copies of large indexes can hurt performance. A new actor can introduce concurrency risk. Start with an actor-owned internal struct/helper unless the design proves a separate actor is worth it. Preserve debug helper compatibility.

Tests and performance verification: extend FullIndexDiskCacheHardeningTests for moved reason/debug behavior; keep SearchPlannerTests unchanged unless planner state changes; run SearchServiceTests and SearchBackendConsistencyTests for coverage/cache behavior. Gates: make build, make test-unit, make test-strict, make test-snapshot-perf-release. If warm-load or disk-cache behavior changes, run make perf-search-warm-load.

### Candidate 2: Deepen Storage Cleanup/Delete Execution Into A DeletePlan Executor

Files: Scopy/Services/StorageService.swift, Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift, ScopyTests/StorageServiceTests.swift, ScopyTests/ResourceCleanupTests.swift.

Problem: The safety-critical sequence for cleanup is repeated: repository plan, DB-first deletion, storageRef validation, bounded off-main file deletion, external-size cache invalidation, and privacy-safe logging. The current applyDeletePlan Module exists but is only used by composite cleanup, so the Interface is not yet the single owner of DB-first external-safe delete execution.

Solution: Promote applyDeletePlan into the common internal delete execution Seam. Route cleanupByCount, cleanupImagesOnlyByCount, cleanupByAge, cleanupBySize, cleanupExternalStorage, and possibly deleteAllExceptPinned through it. Keep StorageService as the product-facing Module and SQLiteClipboardRepository as the SQL Adapter. The executor Interface should accept a DeletePlan, logContext, and StorageFileOps Adapter, and own DB-first delete, validation, bounded file delete, and cache invalidation.

Benefits: Strong Locality for file safety rules; higher Leverage from existing StorageFileOps test Adapter; smaller blast radius than search lifecycle; preserves behavior while reducing duplicated Implementation.

Risks: A mechanical consolidation can accidentally change no-op behavior or cache invalidation timing. Keep contextual logging and wait for the detached deletion task as today.

Tests and performance verification: keep existing cleanup tests green. Add focused tests with injected StorageFileOps to assert invalid refs are skipped and DB delete failure does not call removeFile. Add coverage for any newly routed cleanupExternalStorage/deleteAllExceptPinned path. Gates: make build, make test-unit, make test-strict. If cleanup planning or large delete behavior changes beyond consolidation, run make test-snapshot-perf-release.

### Candidate 3: Deepen Clipboard Ingest Spool And Backpressure Into An Internal Queue Module

Files: Scopy/Services/ClipboardMonitor.swift, Scopy/Utilities/BestEffortFileOps.swift, ScopyTests/ClipboardMonitorTests.swift.

Problem: ClipboardMonitor mixes pasteboard polling, classification, pasteboard write-back, durable ingest spool, backpressure metrics, worker scheduling, payload conversion, and envelope cleanup. The public Module is deep, but internal Locality is weak: durable ingest behavior is spread across MainActor state, NSLock-protected arrays, tracked path sets, disk files, detached tasks, session checks, and manual metrics.

Solution: Introduce an internal ClipboardIngestQueue or ClipboardIngestSpool Module owned by ClipboardMonitor. Keep public start/stop/contentStream behavior unchanged. The new Module owns envelope/payload persistence and discovery, tracked pending paths, active task bookkeeping, soft-limit metrics, worker scheduling, replay, and cleanup of acknowledged/corrupt envelopes. Leave pasteboard classification and write-back in ClipboardMonitor for the first pass.

Benefits: Better Locality for durable large-content ingest; deeper internal Interface for queue/replay/backpressure; more direct testability for spool failures; preserves user-facing clipboard contracts.

Risks: This touches MainActor, locks, detached tasks, AsyncStream emission, and cancellation. A separate actor may be riskier than a MainActor-owned helper in the first implementation. Do not combine with classification deduplication unless specifically selected.

Tests and performance verification: rerun and extend ClipboardMonitorTests around large-content survives polling interval change, restart replay, TIFF conversion, corrupt envelope cleanup, and soft-limit metrics. Gates: make build, make test-unit, make test-strict; consider make test-tsan because this touches event streams, detached tasks, lock/actor interaction, and cancellation.

### Candidate 4: Avoid A Standalone Generic File Adapter

Files: Scopy/Utilities/BestEffortFileOps.swift, Scopy/Services/StorageService.swift, Scopy/Services/ClipboardMonitor.swift.

Problem: BestEffortFileOps and StorageService.writeAtomically are shared, but a broad FileStorageAdapter would be shallow. Callers would still need to know operation mode, path safety, logging privacy, error policy, and payload ownership.

Solution: Do not pick this as a standalone candidate. Extract file operations only behind concrete domain Interfaces: DeletePlan execution for Candidate 2 or ingest envelope persistence for Candidate 3.

Benefits: Avoids over-abstraction. Preserves safety-specific Locality.

Risks: A generic file Module could hide important differences between best-effort cleanup, required atomic writes, validated external payload reads, and thumbnail writes.

Tests and performance verification: no standalone implementation recommended. Verify through the selected parent candidate.

## Ranked Recommendation

1. First implementation: Candidate 2, Storage DeletePlan executor. It has the best risk/reward ratio: repeated Implementation, clear safety Interface, existing fileOps Adapter, strong Locality gains, and focused tests. It preserves user-visible behavior and avoids search/clipboard semantic risk.
2. Second: Candidate 1, Search index lifecycle Module. It has the largest long-term Leverage for performance and warm-load maintainability, but it touches hot search paths, actor state, disk-cache behavior, and benchmark-sensitive code.
3. Third: Candidate 3, Clipboard ingest spool Module. It is valuable for stability but riskier because it touches MainActor/timer/task/lock behavior and durable ingest semantics.
4. Do not do standalone: Candidate 4. Use only as a supporting extraction inside Candidate 2 or 3.

## External References

- No external documentation was required. This research is based on internal code, docs, Trellis specs, and local benchmark/test tooling.
- Tooling references are local: make test-snapshot-perf-release (Makefile:128), bench-snapshot-search (Makefile:299), and perf-search-warm-load (Makefile:310).

## Caveats / Not Found

- I did not run tests or benchmarks; this is a read-only research pass plus one write under the task research directory.
- I did not inspect every line of SearchEngineImpl.swift; findings focus on search lifecycle, storage cleanup, and clipboard ingest areas named in the query.
- No repo CONTEXT.md or ADR files were found in the task PRD prior scan, so architecture vocabulary comes from the requested improve-codebase-architecture glossary and Trellis specs.
- SearchPlanner must remain decision-only. Any design that moves SQL execution, cache mutation, or result semantics into SearchPlanner would violate .trellis/spec/backend/search-guidelines.md:27.
