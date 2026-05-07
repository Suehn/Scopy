# Research: grill q5 search index lifecycle

- Query: Now that Q1-Q4 are implemented and verified, should the remaining SearchIndexLifecycle candidate be implemented as the next slice, narrowed/researched further, or explicitly rejected/out-of-scope so the broad objective can be considered complete?
- Scope: internal
- Date: 2026-05-07

## Findings

### Grill-Me Q5 Question

Question: Now that Q1-Q4 are implemented and verified, should the remaining SearchIndexLifecycle candidate be implemented as the next slice, narrowed/researched further, or explicitly rejected/out-of-scope so the broad objective can be considered complete?

Recommended answer: OUT_OF_SCOPE_FOR_THIS_TASK for the broad SearchIndexLifecycle extraction, plus NEXT_SLICE only if the parent wants one more small code change: SearchExactQueryNormalization. The SearchIndexLifecycle friction is real, but after Q1-Q4 it is no longer a necessary high-value improvement before marking the architecture-quality objective complete. A broad lifecycle Module extraction would touch a larger correctness/performance surface than the remaining proven benefit justifies. The smaller exact-query normalization fix has clearer Locality, lower risk, and direct correctness value.

Accepted decision for this research pass: Do not proceed with SearchIndexLifecycle before completion. Treat it as explicitly out of scope for this task unless a future search-focused task reopens it with a tighter design. If execution continues anyway, implement the smaller SearchExactQueryNormalization correctness slice first.

### Prompt-To-Artifact Completion Audit Update

Q1-Q4 now satisfy the task's implemented-slice objective. The PRD records completed acceptance criteria for at least three candidates, grill selection, Q4 implementation, focused tests, baseline gates, performance gates, and a completion audit (.trellis/tasks/05-07-architecture-quality-deepening/prd.md:34, .trellis/tasks/05-07-architecture-quality-deepening/prd.md:35, .trellis/tasks/05-07-architecture-quality-deepening/prd.md:39, .trellis/tasks/05-07-architecture-quality-deepening/prd.md:40, .trellis/tasks/05-07-architecture-quality-deepening/prd.md:41, .trellis/tasks/05-07-architecture-quality-deepening/prd.md:42). The PRD also records final passed manifests for Verification Evidence Manifest Module, Storage DeletePlan executor, hover profile evidence, and HistoryHoverPreviewPipeline (.trellis/tasks/05-07-architecture-quality-deepening/prd.md:87, .trellis/tasks/05-07-architecture-quality-deepening/prd.md:97, .trellis/tasks/05-07-architecture-quality-deepening/prd.md:107, .trellis/tasks/05-07-architecture-quality-deepening/prd.md:115).

The remaining open wording came from Q4: SearchIndexLifecycle was deferred, not rejected, and required a narrower search-specific grill question before implementation (.trellis/tasks/05-07-architecture-quality-deepening/prd.md:127, .trellis/tasks/05-07-architecture-quality-deepening/prd.md:128). This Q5 answers that gap. The broad objective can be considered complete after this decision record if the parent accepts "out of scope for this task" for SearchIndexLifecycle and does not require the small exact-query correctness fix as part of the architecture-deepening task.

Why no more high-value necessary architecture improvements remain:

- Verification Evidence Manifest Module created the evidence Seam used by later runtime work; its Interface is opt-in and did not change product behavior (.trellis/tasks/05-07-architecture-quality-deepening/info.md:5, .trellis/tasks/05-07-architecture-quality-deepening/info.md:17, .trellis/tasks/05-07-architecture-quality-deepening/info.md:36, .trellis/tasks/05-07-architecture-quality-deepening/info.md:65).
- Storage DeletePlan executor concentrated cleanup plan execution behind an internal Seam while preserving the SQL Adapter and file-removal Adapter (.trellis/tasks/05-07-architecture-quality-deepening/info.md:80, .trellis/tasks/05-07-architecture-quality-deepening/info.md:99, .trellis/tasks/05-07-architecture-quality-deepening/info.md:100, .trellis/tasks/05-07-architecture-quality-deepening/info.md:101).
- Hover profile evidence added the missing profile Adapter before runtime preview changes (.trellis/tasks/05-07-architecture-quality-deepening/info.md:110, .trellis/tasks/05-07-architecture-quality-deepening/info.md:112, .trellis/tasks/05-07-architecture-quality-deepening/info.md:135, .trellis/tasks/05-07-architecture-quality-deepening/info.md:136).
- HistoryHoverPreviewPipeline then moved hover planning/loading/cache/metric behavior behind a narrower preview Module Interface, while preserving row rendering and behavior (.trellis/tasks/05-07-architecture-quality-deepening/info.md:144, .trellis/tasks/05-07-architecture-quality-deepening/info.md:146, .trellis/tasks/05-07-architecture-quality-deepening/info.md:150, .trellis/tasks/05-07-architecture-quality-deepening/info.md:152).

Those four slices gave real Depth, Locality, and Leverage in tooling, storage, and frontend preview hot paths. The only remaining named candidate is SearchIndexLifecycle, and the evidence below supports rejecting it for this task rather than treating it as necessary completion work.

### Files Found

- Scopy/Infrastructure/Search/SearchEngineImpl.swift - search execution Module that also owns recent cache, full/short index state, mutation lifecycle, disk-cache persist/load, debug health, and exact/fuzzy/regex execution.
- Scopy/Infrastructure/Search/SearchPlanner.swift - decision-only planner Module and Seam for path identity, coverage, reason, capabilities, and diagnostics.
- Scopy/Infrastructure/Search/SearchIndexDiskCache.swift - disk snapshot Adapter for full and short index cache metadata/payload load and persist.
- ScopyTests/SearchPlannerTests.swift - planner Interface tests for exact short/long decisions and other search paths.
- ScopyTests/SearchServiceTests.swift - user-visible search behavior, index health, ordering, and tombstone regression tests.
- ScopyTests/SearchBackendConsistencyTests.swift - ClipboardService-level search invalidation regression test.
- ScopyTests/FullIndexDiskCacheHardeningTests.swift - full-index disk-cache hardening tests for hit/fallback reasons.
- ScopyTests/ShortQueryIndexDiskCacheHardeningTests.swift - short-query disk-cache and tombstone hardening tests discovered during search lifecycle inspection.
- .trellis/tasks/05-07-architecture-quality-deepening/research/backend-stability.md - original backend candidate research that proposed SearchIndexLifecycle as valuable but higher risk.
- .trellis/tasks/05-07-architecture-quality-deepening/research/frontend-hot-paths.md - frontend candidate research used to compare prior Q4 priority.
- .trellis/tasks/05-07-architecture-quality-deepening/research/grill-q4-completion-audit-next-candidate.md - prior audit that deferred SearchIndexLifecycle and identified the exact-query raw-length issue.
- .trellis/spec/backend/search-guidelines.md - search contracts and required gates for search-internal changes.

### SearchIndexLifecycle Evidence

The current SearchEngineImpl Module is still internally broad. One actor owns DB connection state, recent-cache state, full-index state, mutation generation, DEBUG disk-cache reason state, full-index pending mutation events, background build tasks, disk-cache persist tasks, short-query index state, statement cache, sorted fuzzy cache, corpus metrics, scratch arrays, and FTS feature flags (Scopy/Infrastructure/Search/SearchEngineImpl.swift:903, Scopy/Infrastructure/Search/SearchEngineImpl.swift:908, Scopy/Infrastructure/Search/SearchEngineImpl.swift:913, Scopy/Infrastructure/Search/SearchEngineImpl.swift:916, Scopy/Infrastructure/Search/SearchEngineImpl.swift:918, Scopy/Infrastructure/Search/SearchEngineImpl.swift:924, Scopy/Infrastructure/Search/SearchEngineImpl.swift:930, Scopy/Infrastructure/Search/SearchEngineImpl.swift:933, Scopy/Infrastructure/Search/SearchEngineImpl.swift:937, Scopy/Infrastructure/Search/SearchEngineImpl.swift:957, Scopy/Infrastructure/Search/SearchEngineImpl.swift:978, Scopy/Infrastructure/Search/SearchEngineImpl.swift:983, Scopy/Infrastructure/Search/SearchEngineImpl.swift:986, Scopy/Infrastructure/Search/SearchEngineImpl.swift:989).

Lifecycle and execution are interleaved. close() cancels and flushes full/short index tasks and disk-cache persist tasks before resetting caches and connection state (Scopy/Infrastructure/Search/SearchEngineImpl.swift:1003, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1004, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1009, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1013, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1022, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1027). invalidateCache() resets recent cache, full index, short index, corpus metrics, DB token state, and starts short-query build in one method (Scopy/Infrastructure/Search/SearchEngineImpl.swift:1041, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1042, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1043, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1044, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1045, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1046, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1047).

Mutation handling is also lifecycle-heavy. handleUpsertedItem increments the mutation counter, checks external DB changes, resets query caches, updates short-query state, appends pending full-index events while builds are active, mutates the full index, records tombstones, and may trigger rebuild (Scopy/Infrastructure/Search/SearchEngineImpl.swift:1050, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1051, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1052, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1055, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1056, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1060, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1061, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1075, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1080, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1083). Pin/delete/clear reset or mutate the same index structures (Scopy/Infrastructure/Search/SearchEngineImpl.swift:1091, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1118, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1153).

Background build state is tightly coupled to the same Module. startShortQueryIndexBuildIfNeeded captures estimated count, generation, pending arrays, and a detached DB builder task (Scopy/Infrastructure/Search/SearchEngineImpl.swift:1235, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1240, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1242, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1245, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1249). startFullIndexBuildIfNeeded does similar work for full-index warm load, including trigger, reserve size, disk-cache load, DB build fallback, and warm-load metrics (Scopy/Infrastructure/Search/SearchEngineImpl.swift:1312, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1327, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1331, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1341, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1342, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1343, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1349).

On-demand full-index load and disk-cache fallback are also inside search execution. getOrBuildFullIndex loads a disk snapshot, handles tombstone staleness, installs a disk-cache index, or rebuilds from DB and schedules persist (Scopy/Infrastructure/Search/SearchEngineImpl.swift:2574, Scopy/Infrastructure/Search/SearchEngineImpl.swift:2580, Scopy/Infrastructure/Search/SearchEngineImpl.swift:2612, Scopy/Infrastructure/Search/SearchEngineImpl.swift:2617, Scopy/Infrastructure/Search/SearchEngineImpl.swift:2628, Scopy/Infrastructure/Search/SearchEngineImpl.swift:2634, Scopy/Infrastructure/Search/SearchEngineImpl.swift:2650, Scopy/Infrastructure/Search/SearchEngineImpl.swift:2652). DEBUG health methods expose full-index state and load reasons directly from SearchEngineImpl (Scopy/Infrastructure/Search/SearchEngineImpl.swift:5070, Scopy/Infrastructure/Search/SearchEngineImpl.swift:5077, Scopy/Infrastructure/Search/SearchEngineImpl.swift:5081, Scopy/Infrastructure/Search/SearchEngineImpl.swift:5085).

This is genuine Locality friction. A future SearchIndexLifecycle Module could be deep if it hid mutation replay, full/short index readiness, disk-cache load/persist, tombstone decisions, warm-load metrics, and debug health behind a small internal Interface. The existing SearchIndexDiskCache is a concrete Adapter for disk snapshots; builder functions and PerfContext/SearchWarmLoadMetrics could become Adapters at the lifecycle Seam.

### Why SearchIndexLifecycle Should Not Proceed In This Task

SearchIndexLifecycle should not proceed before marking this task complete because the current evidence shows higher risk than remaining necessary Leverage.

First, the search contracts deliberately keep SearchPlanner decision-only. Search guidelines say existing search execution remains responsible for SQL, FTS, cache, full-index, timeout, cancellation, sorting, paging, and coverage behavior, and callers must continue using SearchEngineImpl.search(request:) ( .trellis/spec/backend/search-guidelines.md:13, .trellis/spec/backend/search-guidelines.md:20). They also forbid SearchPlanner from owning SQLite connections, executing SQL, mutating caches, building runner closures, or changing result semantics (.trellis/spec/backend/search-guidelines.md:27). Any lifecycle extraction must therefore stay internal to SearchEngineImpl or a same-actor helper; it cannot reuse the planner Seam as an execution Adapter.

Second, the verification surface is already broad. Disk cache hardening covers disk-cache hit, legacy metadata, fingerprint mismatch, SHM drift, tombstone stale skip, checksum mismatch, and invalid postings fallback (ScopyTests/FullIndexDiskCacheHardeningTests.swift:9, ScopyTests/FullIndexDiskCacheHardeningTests.swift:19, ScopyTests/FullIndexDiskCacheHardeningTests.swift:31, ScopyTests/FullIndexDiskCacheHardeningTests.swift:53, ScopyTests/FullIndexDiskCacheHardeningTests.swift:69, ScopyTests/FullIndexDiskCacheHardeningTests.swift:85, ScopyTests/FullIndexDiskCacheHardeningTests.swift:96). SearchServiceTests cover full-index non-build fallback behavior, forced substring fallback, and short-query tombstone rebuild behavior (ScopyTests/SearchServiceTests.swift:462, ScopyTests/SearchServiceTests.swift:510, ScopyTests/SearchServiceTests.swift:693). SearchBackendConsistencyTests cover pinned-change invalidation through ClipboardService (ScopyTests/SearchBackendConsistencyTests.swift:7, ScopyTests/SearchBackendConsistencyTests.swift:22, ScopyTests/SearchBackendConsistencyTests.swift:25, ScopyTests/SearchBackendConsistencyTests.swift:27). Moving lifecycle state would require preserving all of this, plus snapshot perf and warm-load behavior.

Third, performance risk is high. The product spec requires exact/fuzzy search responsiveness on realistic snapshot databases and keeps heavy indexing off the main thread (doc/current/product-spec.md:76, doc/current/product-spec.md:77, doc/current/product-spec.md:78, doc/current/product-spec.md:111, doc/current/product-spec.md:114, doc/current/product-spec.md:115). A separate actor could add await points or force copies of large FullFuzzyIndex/ShortQueryIndex structures. A same-actor helper avoids that but yields less immediate Depth than the completed Q4 pipeline because SearchEngineImpl would still own the public search Interface and most execution branches.

Fourth, prior local memory for Scopy performance work warns against speculative architecture guesses without measurement: canonical frontend/backend perf gates exist, warm-load evidence matters, and row-level micro-optimizations already failed on real snapshot metrics (/Users/ziyi/.codex/memories/MEMORY.md:177, /Users/ziyi/.codex/memories/MEMORY.md:182, /Users/ziyi/.codex/memories/MEMORY.md:191, /Users/ziyi/.codex/memories/MEMORY.md:192). That lesson applies here: do not start a broad search lifecycle refactor without a fresh search-specific bottleneck or correctness failure.

### Smallest Safe SearchIndexLifecycle Slice If Reopened Later

If a future search-focused task reopens SearchIndexLifecycle, the smallest safe implementation slice is not a new actor. It should be a same-actor internal Module, probably a nested or file-local SearchIndexLifecycleState plus tiny methods, with no public Interface change.

Implementation boundary:

1. Keep SearchEngineImpl.search(request:) as the public Interface.
2. Keep SearchPlanner decision-only.
3. Keep SQL execution, scoring, result ordering, SearchCoverage, timeouts, and paging in SearchEngineImpl execution paths.
4. Move only lifecycle state grouping and pure lifecycle transitions first: full/short readiness state for SearchPlanner.State, reset/invalidate grouping, pending event enqueue/replay helpers, disk-cache reason bookkeeping, and debug health DTO construction.
5. Keep FullFuzzyIndex and ShortQueryIndex actor-isolated in the same actor; do not pass large indexes across actors.
6. Use SearchIndexDiskCache as the existing disk snapshot Adapter; do not create a new filesystem abstraction in the first slice.

Exact regression tests/perf gates for that future slice:

- Focused DEBUG lifecycle tests for full-index health and disk-cache reason behavior: existing FullIndexDiskCacheHardeningTests plus any moved debug DTO tests.
- Focused tombstone/rebuild tests: SearchServiceTests.testShortQueryIndexRebuildsAfterTombstones and full-index tombstone/update tests if touched.
- SearchPlannerTests should remain unchanged unless planner state construction semantics change.
- SearchServiceTests and SearchBackendConsistencyTests for user-visible coverage, ordering, and invalidation.
- make build.
- make test-unit.
- make test-strict.
- make test-snapshot-perf-release, required by backend search guidelines after search internals change (.trellis/spec/backend/search-guidelines.md:53).
- make perf-search-warm-load if warm-load, disk-cache, or first full-index build behavior changes.
- Final quality manifest through scripts/quality/record-gate-result.py.

### Smaller Higher-Priority Correctness Slice: SearchExactQueryNormalization

Q4 noted a smaller correctness issue that is now higher priority than SearchIndexLifecycle if the parent wants one more code slice. Exact search currently branches on raw request.query.count before trimming in both planner and engine. SearchPlanner.planExact returns exactRecentCache when request.query.count <= 2, then trims only after that branch (Scopy/Infrastructure/Search/SearchPlanner.swift:97, Scopy/Infrastructure/Search/SearchPlanner.swift:102, Scopy/Infrastructure/Search/SearchPlanner.swift:113). SearchEngineImpl.searchExact mirrors the same raw-count branch, then trims for FTS afterward (Scopy/Infrastructure/Search/SearchEngineImpl.swift:1904, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1909, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1915).

The product contract is phrased around Exact >= 3 characters complete history and <= 2 characters recent-only (doc/current/product-spec.md:78). Because the current branch uses raw length, whitespace-padded short queries can be treated as long complete-history FTS queries, while whitespace-only queries can fall through to all-items behavior through an FTSQueryBuilder nil path. This creates a narrow Interface mismatch between user-visible normalized query intent and execution. It is a correctness/consistency issue, not a broad architecture Module deepening issue.

Smallest implementation slice:

1. Add a pure helper on SearchPlanner, for example normalizedQueryForLengthDecision(_:) or exactQueryKey(_:) using request.query.trimmingCharacters(in: .whitespacesAndNewlines).
2. Make SearchPlanner.planExact and SearchEngineImpl.searchExact use the same normalized value for empty/short/long length decisions.
3. Preserve existing matching semantics for non-empty exact queries as much as possible; use the normalized query for FTS/substring paths, and be explicit if recent-cache matching should use normalized text.
4. Add tests before implementation to pin intended behavior.

Exact regression tests/perf gates for this smaller slice:

- SearchPlannerTests for whitespace-only exact query -> allWithFilters/emptyQuery, whitespace-padded short exact query -> exactRecentCache/recentOnly, and whitespace-padded long exact query -> exactFTS/complete.
- SearchServiceTests with >2000 rows proving " ab " behaves like "ab" and remains recentOnly, plus " abc " behaves like "abc" and reaches older complete-history matches.
- SearchBackendConsistencyTests only if ClipboardService-level normalization is touched; otherwise not required.
- make build.
- make test-unit.
- make test-strict because search actor behavior and planner/execution parity are touched.
- make test-snapshot-perf-release because .trellis/spec/backend/search-guidelines.md requires snapshot perf after search internals change.

This smaller slice has better immediate Locality than SearchIndexLifecycle: one normalized-query rule sits at the planner/execution Seam, removes a drift point, and tests the Interface directly. Its Depth is modest, but the Leverage is concrete because it aligns planner path identity, coverage, and user-facing exact search behavior without moving large indexes.

### Related Specs

- .trellis/spec/backend/search-guidelines.md:13 keeps existing execution methods responsible for SQL, FTS, cache, full-index, timeout, cancellation, sorting, paging, and coverage behavior.
- .trellis/spec/backend/search-guidelines.md:20 keeps SearchEngineImpl.search(request:) as the public search Interface.
- .trellis/spec/backend/search-guidelines.md:27 forbids SearchPlanner from becoming an execution Adapter or cache owner.
- .trellis/spec/backend/search-guidelines.md:28 allows shared pure predicates/tokenization on SearchPlanner when planner and engine need the same rule.
- .trellis/spec/backend/search-guidelines.md:53 requires build/unit/snapshot perf after search internals change.
- .trellis/spec/backend/quality-guidelines.md:21 forbids blocking the main actor with search work.
- .trellis/spec/backend/quality-guidelines.md:22 forbids search semantics changes without focused tests and benchmark evidence when performance-sensitive.
- doc/current/product-spec.md:78 defines the exact search length coverage contract.

## Caveats / Not Found

- I did not edit product code, tests, scripts, specs, task PRD, release metadata, or git state. The only intended write is this research file under the task research directory.
- I did not run tests or performance gates because this pass is research-only. The gates above are required if either SearchExactQueryNormalization or any future SearchIndexLifecycle slice is implemented.
- I did not find evidence that SearchIndexLifecycle is unnecessary forever. The decision is narrower: it is not necessary before completing this architecture-quality task, and it should be reopened only with a search-specific bottleneck, correctness failure, or focused lifecycle-design task.
- Some line references point to current uncommitted code in a dirty worktree. They are valid for this checkout but should be rechecked if the Q4 implementation diff is rebased or edited.
