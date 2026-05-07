# Research: grill q4 completion audit next candidate

- Query: After Verification Evidence Manifest Module, Storage DeletePlan executor, and Hover Preview Profile Evidence, is the broad architecture-quality objective complete; if not, what is the single next highest-leverage architecture deepening candidate?
- Scope: internal
- Date: 2026-05-07

## Findings

### Grill-Me Q4 Question

Question: After the completed slices, does the broad objective have enough evidence to be marked complete? If not, what is the single next highest-leverage architecture deepening candidate to implement, and why?

Recommended answer: NEXT_SLICE: HistoryHoverPreviewPipeline, with the smallest implementation slice being extraction of a hover preview request/planning Module plus Adapters for image, file, markdown/text loading, cache lookup, and metric emission. Do not mark the broad objective complete yet.

Accepted decision for this research pass: NEXT_SLICE: HistoryHoverPreviewPipeline.

### Prompt-To-Artifact Completion Audit

The three completed slices are well evidenced and should be treated as completed slices, not as proof that the broad objective is complete:

- Verification Evidence Manifest Module is recorded in the PRD and final manifest, with build/unit/strict and artifact accounting passed (.trellis/tasks/05-07-architecture-quality-deepening/prd.md:87, .trellis/tasks/05-07-architecture-quality-deepening/prd.md:90, logs/quality-main-final/quality-manifest-final.md:3, logs/quality-main-final/quality-manifest-final.md:11).
- Storage DeletePlan executor is recorded with focused routed storage tests, baseline gates, and snapshot release perf passed (.trellis/tasks/05-07-architecture-quality-deepening/prd.md:97, .trellis/tasks/05-07-architecture-quality-deepening/prd.md:102, logs/quality-storage-final-with-snapshot/quality-manifest-final.md:11, logs/quality-storage-final-with-snapshot/quality-manifest-final.md:16).
- Hover Preview Profile Evidence is recorded with focused harness tests, an opt-in profile Adapter, required hover buckets, and a final passed manifest (.trellis/tasks/05-07-architecture-quality-deepening/prd.md:107, .trellis/tasks/05-07-architecture-quality-deepening/prd.md:111, logs/quality-hover-profile-final-2026-05-07_07-47-35/quality-manifest-final.md:12, logs/quality-hover-profile-final-2026-05-07_07-47-35/quality-manifest-final.md:16).

The broad objective should not be marked complete because the PRD's Goal requires continuing until remaining improvement candidates are implemented, rejected with evidence, or explicitly out of scope (.trellis/tasks/05-07-architecture-quality-deepening/prd.md:5). The current task audit still says the full HistoryHoverPreviewPipeline refactor and SearchIndexLifecycle are deferred, not rejected or out of scope (.trellis/tasks/05-07-architecture-quality-deepening/prd.md:127). The task itself remains in_progress (.trellis/tasks/05-07-architecture-quality-deepening/task.json:4, .trellis/tasks/05-07-architecture-quality-deepening/task.json:6).

The grill-me constraint has been followed one question at a time. The skill says to ask questions one at a time and to explore the codebase when the answer is locally derivable (/Users/ziyi/.agents/skills/grill-me/SKILL.md:6, /Users/ziyi/.agents/skills/grill-me/SKILL.md:8, /Users/ziyi/.agents/skills/grill-me/SKILL.md:10). This Q4 answer was derived from PRD, existing research, manifests, current code, and specs rather than asking the human.

The architecture vocabulary requirement is still load-bearing. The improve-codebase-architecture skill defines Module, Interface, Implementation, Depth, Seam, Adapter, Leverage, and Locality and frames the deletion test and test surface around the Interface (/Users/ziyi/.agents/skills/improve-codebase-architecture/SKILL.md:14, /Users/ziyi/.agents/skills/improve-codebase-architecture/SKILL.md:15, /Users/ziyi/.agents/skills/improve-codebase-architecture/SKILL.md:17, /Users/ziyi/.agents/skills/improve-codebase-architecture/SKILL.md:18, /Users/ziyi/.agents/skills/improve-codebase-architecture/SKILL.md:19, /Users/ziyi/.agents/skills/improve-codebase-architecture/SKILL.md:20, /Users/ziyi/.agents/skills/improve-codebase-architecture/SKILL.md:21, /Users/ziyi/.agents/skills/improve-codebase-architecture/SKILL.md:25, /Users/ziyi/.agents/skills/improve-codebase-architecture/SKILL.md:26).

### Candidate 1: Full HistoryHoverPreviewPipeline Refactor

Files / Modules:

- Scopy/Views/History/HistoryItemView.swift - currently owns row hover task scheduling, preview routing, popover request timing, cache usage, markdown file preview, image/file/video/QuickLook preview, and model commits.
- Scopy/Views/History/HistoryItemPreviewCoordinator.swift - currently owns task tokens, popover tokens, hover bookkeeping, and cancellation helpers.
- Scopy/Views/History/HoverPreviewLoader.swift - ImageIO Adapter for image preview decoding and metric emission.
- Scopy/Views/History/HoverPreviewModel.swift, HoverPreviewImageCache.swift, HoverPreviewImageQualityPolicy.swift, HoverPreviewTextSizing.swift, HoverPreviewScreenMetrics.swift - existing support Modules that should become Adapters or policy inputs behind the pipeline Seam.
- ScopyUITests/HistoryItemViewUITests.swift, scripts/perf-frontend-profile.sh, Scopy/Views/UITesting/HistoryItemHarnessView.swift - now provide the evidence Seam for hover profile validation.

Current friction:

HistoryItemView still carries too much preview Implementation behind the row Interface. It directly stores preview coordinator/model state and exposes popover state/control from the list caller (Scopy/Views/History/HistoryItemView.swift:81, Scopy/Views/History/HistoryItemView.swift:83, Scopy/Views/History/HistoryItemView.swift:85, Scopy/Views/History/HistoryItemView.swift:74, Scopy/Views/History/HistoryItemView.swift:77). The current coordinator is a lifecycle helper, not the preview pipeline: it handles tokens and task cancellation, but not preview request planning, loading, cache policy, or result commits (Scopy/Views/History/HistoryItemPreviewCoordinator.swift:22, Scopy/Views/History/HistoryItemPreviewCoordinator.swift:29, Scopy/Views/History/HistoryItemPreviewCoordinator.swift:91).

The row still owns markdown file preview TTL/caching, metric-stable sizing, file reads, markdown HTML rendering, cache updates, and state commits (Scopy/Views/History/HistoryItemView.swift:347, Scopy/Views/History/HistoryItemView.swift:349, Scopy/Views/History/HistoryItemView.swift:360, Scopy/Views/History/HistoryItemView.swift:396, Scopy/Views/History/HistoryItemView.swift:433, Scopy/Views/History/HistoryItemView.swift:468, Scopy/Views/History/HistoryItemView.swift:503, Scopy/Views/History/HistoryItemView.swift:511, Scopy/Views/History/HistoryItemView.swift:521). It also owns image/file preview prefetch, cache keys, ImageIO/video/QuickLook branch selection, suppression checks, popover request timing, and CGImage commits (Scopy/Views/History/HistoryItemView.swift:1080, Scopy/Views/History/HistoryItemView.swift:1093, Scopy/Views/History/HistoryItemView.swift:1109, Scopy/Views/History/HistoryItemView.swift:1122, Scopy/Views/History/HistoryItemView.swift:1142, Scopy/Views/History/HistoryItemView.swift:1161, Scopy/Views/History/HistoryItemView.swift:1198, Scopy/Views/History/HistoryItemView.swift:1200). Text preview still embeds markdown detection and presentation-cache writes in the row task (Scopy/Views/History/HistoryItemView.swift:1483, Scopy/Views/History/HistoryItemView.swift:1502, Scopy/Views/History/HistoryItemView.swift:1516, Scopy/Views/History/HistoryItemView.swift:1519).

Proposed Module / Interface / Seam / Adapters:

Create an internal HistoryHoverPreviewPipeline Module. Its Interface should be smaller than the current row Implementation:

- Input: a value-style HoverPreviewRequest containing item identity/type, storageRef/thumbnailPath/plainText/contentHash, preview kind, settings delay, screen metrics, suppression predicate, and cache key policy.
- Output: typed HoverPreviewEvent or HoverPreviewResult values such as present(kind), image(CGImage), text(raw/isMarkdown/html/metrics), file(kind/path/image/text), and noPreview(reason).
- Seam: the row asks the pipeline to run one request and applies returned events to HoverPreviewModel/requestPopover. The pipeline owns loading/caching/metric emission decisions, while HistoryItemView keeps popover rendering and accessibility identifiers unchanged for the first slice.
- Adapters: HoverPreviewLoader for ImageIO decode, FilePreviewSupport for video/QuickLook/text file preview, MarkdownHTMLRenderer and MarkdownDetector for markdown, HoverPreviewImageCache and MarkdownPreviewCache for caches, HoverPreviewScreenMetrics and HoverPreviewImageQualityPolicy for sizing, ScrollPerformanceProfile for metric emission.

Expected Depth / Leverage / Locality:

- Depth: a small request/result Interface would hide hover delay, cache keys, branch selection, off-main preview work, metric buckets, and stale-result checks.
- Leverage: existing row code, harness UI tests, and future file/text/image preview fixes all use one Interface; tests can target pipeline behavior without full SwiftUI popovers.
- Locality: preview bugs concentrate in the pipeline instead of being split between row body modifiers, coordinator token helpers, cache calls, and detached tasks.

Regression risks:

- User-facing preview behavior is fragile: image/text/file popovers, scroll suppression, hover exit cleanup, UI test tap-preview mode, shared markdown WebView use, and accessibility identifiers must not change.
- Async regressions are plausible: cancellation before commit, stale hover state, cache hit commits after suppression, and off-main decoding must stay guarded.
- macOS popover accessibility remains imperfect in the hover profile gate; the current Q3 notes explicitly record preview_accessibility_found=false and rely on required hover buckets as trigger proof (.trellis/tasks/05-07-architecture-quality-deepening/info.md:140).

Exact verification gates:

- Focused unit tests for the new pipeline Interface covering image cache hit/miss, file image/video/QuickLook branch selection, markdown file stale-cache fallback, text markdown detection/cache use, cancellation before commit, suppression before commit, and metric emission through injected Adapters.
- Focused existing behavior gates in ScopyUITests/HistoryItemViewUITests.swift and/or HistoryListUITests hover dismissal; keep identifiers stable.
- Existing hover evidence gate: scripts/perf-frontend-profile.sh --include-hover, validating non-empty hover.markdown_render_ms and hover.preview_image_decode_ms buckets.
- Baseline gates: git diff --check, make build, make test-unit, make test-strict.
- Frontend profile smoke: make perf-frontend-profile or equivalent short script run. Use make perf-frontend-profile-standard before claiming broad frontend performance improvement.
- Record final outputs through scripts/quality/record-gate-result.py into a passed quality manifest.

Why this is the next slice:

The previous Q3 slice created the missing evidence Seam for hover preview before the runtime refactor (.trellis/tasks/05-07-architecture-quality-deepening/info.md:108, .trellis/tasks/05-07-architecture-quality-deepening/info.md:112, .trellis/tasks/05-07-architecture-quality-deepening/info.md:132, .trellis/tasks/05-07-architecture-quality-deepening/info.md:135, .trellis/tasks/05-07-architecture-quality-deepening/info.md:136). That precondition is now satisfied. The hover profile summary has explicit hover scenarios and non-empty hover buckets: image decode p95 is reported for hover-preview-image and markdown render p95 is reported for hover-preview-markdown-text (logs/perf-frontend-hover-harness-smoke-2026-05-07_07-43-34/frontend-scroll-profile-summary.md:7, logs/perf-frontend-hover-harness-smoke-2026-05-07_07-43-34/frontend-scroll-profile-summary.md:35, logs/perf-frontend-hover-harness-smoke-2026-05-07_07-43-34/frontend-scroll-profile-summary.md:59, logs/perf-frontend-hover-harness-smoke-2026-05-07_07-43-34/frontend-scroll-profile-summary.md:152, logs/perf-frontend-hover-harness-smoke-2026-05-07_07-43-34/frontend-scroll-profile-summary.md:156, logs/perf-frontend-hover-harness-smoke-2026-05-07_07-43-34/frontend-scroll-profile-summary.md:158).

### Candidate 2: SearchIndexLifecycle / Search Index Invalidation Lifecycle

Files / Modules:

- Scopy/Infrastructure/Search/SearchEngineImpl.swift - owns search execution plus full/short index lifecycle, disk cache lifecycle, mutation handling, background builds, tombstone stale decisions, warm-load metrics, debug health, and query caches.
- Scopy/Infrastructure/Search/SearchIndexDiskCache.swift - disk snapshot Adapter.
- Scopy/Infrastructure/Search/SearchPlanner.swift - decision-only planner Seam; should remain decision-only.
- ScopyTests/FullIndexDiskCacheHardeningTests.swift, FullIndexTombstoneUpsertStaleTests.swift, SearchServiceTests.swift, SearchBackendConsistencyTests.swift, scripts/perf-search-warm-load.sh - verification surfaces.

Current friction:

SearchEngineImpl is deep for callers but internally broad. It holds DB connection state, recent cache state, full-index state, mutation counters, full-index pending events, disk-cache persist tasks, short-query index state, short-query pending events, statement cache, sorted fuzzy cache, corpus metrics, scratch arrays, and FTS feature flags in one actor (Scopy/Infrastructure/Search/SearchEngineImpl.swift:903, Scopy/Infrastructure/Search/SearchEngineImpl.swift:908, Scopy/Infrastructure/Search/SearchEngineImpl.swift:913, Scopy/Infrastructure/Search/SearchEngineImpl.swift:916, Scopy/Infrastructure/Search/SearchEngineImpl.swift:930, Scopy/Infrastructure/Search/SearchEngineImpl.swift:932, Scopy/Infrastructure/Search/SearchEngineImpl.swift:933, Scopy/Infrastructure/Search/SearchEngineImpl.swift:937, Scopy/Infrastructure/Search/SearchEngineImpl.swift:940, Scopy/Infrastructure/Search/SearchEngineImpl.swift:957, Scopy/Infrastructure/Search/SearchEngineImpl.swift:978, Scopy/Infrastructure/Search/SearchEngineImpl.swift:983, Scopy/Infrastructure/Search/SearchEngineImpl.swift:986, Scopy/Infrastructure/Search/SearchEngineImpl.swift:989).

Index lifecycle and search execution are interleaved. close(), invalidateCache(), upsert, pin, deletion, clear-all, recent-cache reset, full-index reset, short-index reset, background short-index build, interactive full-index warmup, full-index build, on-demand disk-cache load/rebuild, and debug health all sit in the same Module (Scopy/Infrastructure/Search/SearchEngineImpl.swift:1003, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1041, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1050, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1091, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1118, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1153, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1158, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1168, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1179, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1235, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1291, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1312, Scopy/Infrastructure/Search/SearchEngineImpl.swift:2574, Scopy/Infrastructure/Search/SearchEngineImpl.swift:5069).

Proposed Module / Interface / Seam / Adapters:

Create an internal SearchIndexLifecycle Module, probably first as an actor-isolated helper/struct inside the same actor rather than a separate actor. Interface: accept mutation events, expose index readiness/state for SearchPlanner.State, provide getOrBuildFullIndex(perf:), start/cancel warmup, reset/invalidate, flush/persist on close, and debug health. Seam: SearchEngineImpl keeps the public search(request:) Interface and delegates lifecycle decisions to the internal Module. Adapters: SearchIndexDiskCache for snapshots, FullIndexBuilder/ShortQueryIndex builder functions for DB reads, PerfContext/SearchWarmLoadMetrics for observability.

Expected Depth / Leverage / Locality:

- Depth: hides disk-cache preflight/load/rebuild, tombstone stale decisions, pending mutation replay, generation counters, and warm-load metrics behind one internal Interface.
- Leverage: future disk-cache and invalidation fixes can test lifecycle behavior without scanning unrelated search execution branches.
- Locality: keeps search path semantics in SearchEngineImpl/SearchPlanner while concentrating index lifecycle state.

Regression risks:

- High risk because full and short indexes are performance-critical and large. A separate actor could copy large indexes or add await points that hurt latency.
- Semantics risk: SearchPlanner is explicitly decision-only and must not own SQL, mutate caches, or become public execution API (.trellis/spec/backend/search-guidelines.md:13, .trellis/spec/backend/search-guidelines.md:20, .trellis/spec/backend/search-guidelines.md:27).
- Verification surface is wider than hover: search correctness, disk cache hardening, tombstone staleness, warm-load, snapshot performance, and strict concurrency all matter.

Exact verification gates:

- FullIndexDiskCacheHardeningTests for moved disk-cache reason/debug behavior.
- FullIndexTombstoneUpsertStaleTests for tombstone stale and rebuild behavior.
- SearchServiceTests and SearchBackendConsistencyTests for user-visible search coverage and cache invalidation behavior.
- make build, make test-unit, make test-strict, make test-snapshot-perf-release.
- make perf-search-warm-load if warm-load or disk-cache behavior changes.
- Final quality manifest through scripts/quality/record-gate-result.py.

Why not next:

SearchIndexLifecycle is real and valuable, but it is not the next smallest highest-leverage slice. It touches a larger correctness/performance surface than hover, while the just-created hover evidence Seam is specifically ready to support the hover runtime refactor. Search should follow after the hover pipeline or after a smaller search-specific grill question narrows it to a non-copying internal lifecycle helper.

### Candidate 3: Stronger Candidate Surfaced By Current Code Or Evidence

I checked known review-risk areas instead of relying on prior memory alone.

HistoryViewModel.load() stale-state risk from older review memory is not stronger in current code: current load() now captures searchVersion, guards before and after fetchRecent, guards before/after metrics and stats, and uses shouldApplyLoadResult() with Task.isCancelled, version equality, and isUnfilteredList (Scopy/Observables/HistoryViewModel.swift:350, Scopy/Observables/HistoryViewModel.swift:365, Scopy/Observables/HistoryViewModel.swift:375, Scopy/Observables/HistoryViewModel.swift:381, Scopy/Observables/HistoryViewModel.swift:393). That makes it unsuitable as the next architecture-deepening candidate.

SearchExact raw-length normalization remains a possible narrow correctness fix: searchExact branches on request.query.count before trimming, while the planner state trims first (Scopy/Infrastructure/Search/SearchEngineImpl.swift:1894, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1909, Scopy/Infrastructure/Search/SearchEngineImpl.swift:1915). This is a real small candidate for a focused bug fix, but it is not a stronger architecture-deepening slice than HistoryHoverPreviewPipeline because it does not create a deeper Module or broader Leverage/Locality improvement.

Clipboard ingest spool remains a valid backend candidate from prior backend research, but it has higher concurrency/event-stream risk than the hover pipeline and was not one of the next two residual candidates called out by the PRD completion audit (.trellis/tasks/05-07-architecture-quality-deepening/research/backend-stability.md:134, .trellis/tasks/05-07-architecture-quality-deepening/research/backend-stability.md:143, .trellis/tasks/05-07-architecture-quality-deepening/research/backend-stability.md:145).

### Related Specs

- Frontend component guidance says expensive preview, markdown, thumbnail, and hover behavior should stay behind caches/controllers/profile hooks (.trellis/spec/frontend/component-guidelines.md:19).
- Frontend quality requires focused UI gates for history row/list/context menu behavior and profile gates for scroll/render/thumbnail/preview performance (.trellis/spec/frontend/quality-guidelines.md:26, .trellis/spec/frontend/quality-guidelines.md:29).
- Frontend quality says performance claims require profiler output and should watch markdown rendering, WebView lifecycle, QuickLook, thumbnails, and row recomputation (.trellis/spec/frontend/quality-guidelines.md:44, .trellis/spec/frontend/quality-guidelines.md:49).
- Product spec requires hover preview for text/images/files and heavy preview preparation to stay off the main thread while remaining usable on realistic snapshot DBs (doc/current/product-spec.md:57, doc/current/product-spec.md:114, doc/current/product-spec.md:115).
- Architecture docs require preview/export flows to treat stored content as source-of-truth and keep heavy work backgrounded and bounded (doc/current/architecture.md:41, doc/current/architecture.md:47).
- Search guidelines keep SearchPlanner decision-only and require build/unit/snapshot perf after search internals change (.trellis/spec/backend/search-guidelines.md:13, .trellis/spec/backend/search-guidelines.md:27, .trellis/spec/backend/search-guidelines.md:53).

## Caveats / Not Found

- I did not run new tests or profiles for this Q4 research pass; the audit relies on current manifests, logs, and static code inspection.
- I did not edit product code, tests, scripts, specs, task PRD, or release docs. The only write was this research file under the task research directory.
- macOS popover accessibility in the hover harness still records preview_accessibility_found=false, so the next hover runtime slice should keep using bucket evidence plus behavior UI tests rather than treating accessibility lookup as the only proof.
- There are live agents in the root tree because this is itself the running trellis-research agent; I found no separate completed-but-unread agent result needed for this Q4 audit before writing this file.
