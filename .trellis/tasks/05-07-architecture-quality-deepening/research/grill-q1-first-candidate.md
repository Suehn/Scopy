# Research: grill q1 first candidate

- Query: Which architecture deepening candidate should this task implement first across frontend, backend, quality tooling, and search lifecycle options?
- Scope: internal
- Date: 2026-05-07

## Findings

### Decision

Implement the Verification Evidence Manifest Module first.

This is the right first Module because the task's hardest constraint is not merely finding one worthwhile refactor; it is improving Scopy while avoiding regressions, following Trellis, and continuing until remaining improvements are genuinely exhausted or explicitly rejected. Today the verification Interface is scattered across Makefile targets, shell/Python scripts, logs, release notes, and human prose. A manifest Module creates a deep Seam around gate evidence before touching higher-risk runtime paths. Its first Interface can be small: record gate command, timestamps, status, exit code, artifacts, key metrics, environment facts, and skip reason; then emit a machine-readable JSON manifest plus a Markdown summary.

The accepted first step is therefore tooling architecture, not product behavior. That matters: it gives high Leverage with near-zero runtime regression risk, and it improves Locality for every subsequent product-code candidate. Once this exists, later work on hover preview, storage cleanup, or search lifecycle can point to one evidence artifact instead of relying on manually reconstructed logs.

### Candidate Comparison

Verification Evidence Manifest Module - selected first. The current quality-tooling research identifies that Scopy's gates are useful but shallow: each command owns its own stdout/log shape and skip semantics, making quality closure vulnerable to weak claims like ran tests without structured command, status, artifact, threshold, and skip evidence (.trellis/tasks/05-07-architecture-quality-deepening/research/quality-tooling.md:52). Its proposed Interface is narrow and concrete: record one gate result, emit a combined manifest, and validate a required gate set (.trellis/tasks/05-07-architecture-quality-deepening/research/quality-tooling.md:58). The benefit is direct Depth around verification evidence, better Locality for skip policy, and Leverage for Trellis completion audits (.trellis/tasks/05-07-architecture-quality-deepening/research/quality-tooling.md:66). Because it keeps existing targets and adds an opt-in or aggregate Adapter first, it avoids product behavior risk (.trellis/tasks/05-07-architecture-quality-deepening/research/quality-tooling.md:73). The quality-tooling research already recommends it first because it supports future candidates as manifest inputs (.trellis/tasks/05-07-architecture-quality-deepening/research/quality-tooling.md:257).

HistoryHoverPreviewPipeline - not first. This is the strongest direct frontend product-code candidate. The current hover preview Implementation is spread through HistoryItemView: image preview delay/cache/downsampling, file image/video/QuickLook branches, markdown file TTL/stale fallback/rendering/metrics, and text markdown detection/rendering (.trellis/tasks/05-07-architecture-quality-deepening/research/frontend-hot-paths.md:52). A deeper pipeline Module would provide excellent Depth, Leverage, and Locality (.trellis/tasks/05-07-architecture-quality-deepening/research/frontend-hot-paths.md:60). It is not first because its Seam is fragile: hover delay, scroll suppression, popover reopen behavior, shared WebView attachment, and UI-test tap-preview mode must stay unchanged (.trellis/tasks/05-07-architecture-quality-deepening/research/frontend-hot-paths.md:64). The standard frontend profile also does not exercise hover preview rendering buckets, so evidence must be strengthened before making performance claims (.trellis/tasks/05-07-architecture-quality-deepening/research/frontend-hot-paths.md:145). It should follow once the manifest can record focused preview tests and profile artifacts.

Storage DeletePlan executor - not first. This is the best low-risk product-code stability candidate. Storage cleanup repeats a safety-critical sequence: repository plan, DB-first deletion, storageRef validation, bounded off-main file deletion, cache invalidation, and privacy-safe logging (.trellis/tasks/05-07-architecture-quality-deepening/research/backend-stability.md:119). Promoting applyDeletePlan into the common delete execution Seam would improve Locality for file safety rules and use existing StorageFileOps as a test Adapter (.trellis/tasks/05-07-architecture-quality-deepening/research/backend-stability.md:125). It is not first because its Leverage is narrower than the manifest: it improves one backend deletion path, while the manifest improves the reliability of evidence for all later backend, frontend, and performance work. It should be the first product-code backend candidate after verification structure exists.

SearchIndexLifecycle - not first. This has the largest long-term performance and warm-load maintainability Leverage. SearchEngineImpl currently interleaves execution with index lifecycle, disk-cache lifecycle, generation invalidation, pending event replay, tombstone decisions, and diagnostics, while SearchPlanner must remain decision-only (.trellis/tasks/05-07-architecture-quality-deepening/research/backend-stability.md:105). A SearchIndexLifecycle Module could deepen the internal Seam while preserving SearchEngineImpl.search(request:) as the public Interface (.trellis/tasks/05-07-architecture-quality-deepening/research/backend-stability.md:111). It is not first because it touches hot search paths, actor state, disk-cache behavior, debug helpers, and benchmark-sensitive code; the research explicitly warns about cross-actor copies and concurrency risk (.trellis/tasks/05-07-architecture-quality-deepening/research/backend-stability.md:115). It should wait until lower-risk evidence and storage work reduce the chance of misattributed regressions.

### Smallest Implementation Slice

Create the first manifest Module as a tooling-only slice:

1. Add scripts/quality/record-gate-result.py as the Module Implementation.
2. Give it a small CLI Interface with two operations: record one result and summarize one or more result files.
3. Add an opt-in Makefile Adapter such as quality-manifest or quality-record-* that does not replace existing make build, make test-unit, make test-strict, or make test-tsan.
4. Record at least command, started/ended timestamps, duration, exit status, status enum passed|failed|skipped|not_run, log/artifact paths, environment facts, key metrics if supplied, and skip reason.
5. Emit logs/quality-manifest-<timestamp>.json plus logs/quality-manifest-<timestamp>.md.
6. Keep perf artifacts as future inputs unless the first slice can ingest them without touching current perf gates.

The deletion test passes: deleting this Module would push command-status parsing, skip semantics, artifact existence checks, and completion-audit evidence back into each task's prose, release notes, and manual review. Keeping it gives Depth because many verification concerns sit behind a small evidence Interface.

### Required Tests And Gates

- Add focused tests for manifest writing and summarizing using fixture records/log paths.
- Cover passed, failed, skipped, and not_run statuses.
- Cover artifact existence checks and explicit skip reasons, especially the local test-tsan skip shape from Makefile:162.
- Run make build, make test-unit, and make test-strict.
- Run the new manifest command over at least one real passing gate record and one synthetic skip fixture.
- Do not claim product performance improvement from this slice. When later candidates touch hover preview, cleanup, search, scrolling, thumbnails, or profiling, record the required perf gates in the manifest.

## Files Found

- .trellis/tasks/05-07-architecture-quality-deepening/prd.md - Task objective, requirements, acceptance criteria, and completion audit expectations.
- .trellis/tasks/05-07-architecture-quality-deepening/research/frontend-hot-paths.md - Frontend candidates and recommendation for HistoryHoverPreviewPipeline.
- .trellis/tasks/05-07-architecture-quality-deepening/research/backend-stability.md - Backend candidates and recommendation for Storage DeletePlan executor before SearchIndexLifecycle.
- .trellis/tasks/05-07-architecture-quality-deepening/research/quality-tooling.md - Quality/tooling candidates and recommendation for Verification Evidence Manifest Module.
- Makefile - Existing gate targets, log paths, skip behavior, snapshot perf threshold checks, and frontend profile targets.
- scripts/perf-frontend-profile.sh - Existing frontend profile artifact aggregation and informal metric schema.
- scripts/perf-unified-table.sh - Existing performance artifact merge Adapter.
- Scopy/Views/History/HistoryItemView.swift - Current broad hover preview Implementation container.
- Scopy/Services/StorageService.swift - Current repeated delete-plan execution pattern and existing applyDeletePlan helper.
- Scopy/Infrastructure/Search/SearchEngineImpl.swift - Current broad search execution and index lifecycle Implementation.

## Code Patterns

- Existing test gates already write logs with bash -o pipefail and tee, which is the right base for a manifest Adapter rather than replacing gate behavior (Makefile:77, Makefile:189).
- test-snapshot-perf-release already enforces numeric p95 thresholds by parsing JSONL and failing when targets are exceeded, so manifest work should record that evidence rather than weakening it (Makefile:142).
- Frontend profile summaries already produce JSON and Markdown, but metric bucket definitions currently live inside an embedded Python list, showing why typed evidence should be centralized gradually (scripts/perf-frontend-profile.sh:198).
- applyDeletePlan already encodes DB-first deletion, validated external file URLs, bounded deletion, and cache invalidation, but only one cleanup path uses it today (Scopy/Services/StorageService.swift:941).
- HistoryItemView remains a broad Implementation container for preview workflows even though token/task bookkeeping has a coordinator (Scopy/Views/History/HistoryItemView.swift:1037, Scopy/Views/History/HistoryItemPreviewCoordinator.swift:13).
- SearchEngineImpl owns many full-index lifecycle fields and tasks in one actor, making SearchIndexLifecycle valuable but too risky as the first slice (Scopy/Infrastructure/Search/SearchEngineImpl.swift:913).

## Related Specs

- .trellis/spec/backend/quality-guidelines.md - Baseline backend gate matrix and risk-based perf/concurrency gates.
- .trellis/spec/frontend/quality-guidelines.md - UI/profile gate matrix and warning that missing profile summaries are not evidence.
- .trellis/spec/backend/logging-guidelines.md - Privacy-safe diagnostics and no noisy hot-loop logging.
- .trellis/spec/frontend/component-guidelines.md - History row/list performance constraints and existing preview/thumbnail seams.
- .trellis/workflow.md - Trellis requirement to persist research, decisions, and completion evidence.

## Caveats / Not Found

- No code was implemented in this research/grilling step.
- No live gate or profile was run; this decision is based on persisted PRD, research files, specs, and targeted source inspection.
- The selected first candidate does not directly change Scopy runtime behavior. That is intentional for the first slice: it reduces regression risk and improves evidence quality before product-code candidates.
- HistoryHoverPreviewPipeline, Storage DeletePlan executor, and SearchIndexLifecycle remain valid follow-up candidates. This decision only orders them; it does not reject their value.

## Accepted Answer

Accepted: Implement the Verification Evidence Manifest Module first, because it creates the smallest high-leverage verification Seam for Trellis-quality evidence and regression control before higher-risk product-code architecture changes.
