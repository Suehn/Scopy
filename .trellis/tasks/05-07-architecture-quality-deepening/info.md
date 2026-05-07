# Technical Design: Verification Evidence Manifest Module

## Accepted Decision

Implement the Verification Evidence Manifest Module first, because it creates the smallest high-leverage verification Seam for Trellis-quality evidence and regression control before higher-risk product-code architecture changes.

This is a tooling-only first slice. It must not change Scopy runtime behavior, test semantics, release semantics, search behavior, storage cleanup, preview behavior, or settings behavior.

## Module Shape

### Module

scripts/quality/record-gate-result.py is the first implementation of the Verification Evidence Manifest Module.

### Interface

The CLI Interface should stay narrow:

- Record one gate result with command, timestamps, duration, exit code, status enum, artifacts, key metrics, environment facts, and skip reason.
- Summarize one or more record files into logs/quality-manifest-<timestamp>.json and logs/quality-manifest-<timestamp>.md.
- Provide focused self-tests or fixture-driven tests without introducing third-party dependencies.

Status enum: passed, failed, skipped, not_run.

### Implementation

- Use Python standard library only.
- Keep existing Makefile gates unchanged.
- Add opt-in Makefile targets only; do not replace make build, make test-unit, make test-strict, or make test-tsan.
- Prefer explicit JSON inputs/outputs over parsing arbitrary terminal prose.
- Artifact existence checks should be structured so a completion audit can distinguish missing artifacts from failed commands.
- A local TSan skip should be representable as skipped with a reason, not as a pass.

### Seam And Adapters

- The Seam is the evidence record format, not a new test runner.
- The first Adapter may be a Makefile target that invokes the script over existing logs or explicit arguments.
- Future Adapters can ingest frontend profile, snapshot perf, and unified perf artifacts after this first slice is stable.

## Smallest Implementation Slice

1. Add scripts/quality/record-gate-result.py.
2. Add focused fixture/self-test support for passed, failed, skipped, and not_run records.
3. Add an opt-in Makefile target such as quality-manifest-demo or quality-manifest-self-test that exercises the Module without replacing current gates.
4. Produce JSON and Markdown manifest artifacts under logs/.
5. Document generated artifacts in this task's verification notes after running the new target.

## Required Verification

- Run the new focused self-test or fixture test.
- Run the new opt-in Makefile target.
- Run make build.
- Run make test-unit.
- Run make test-strict.
- Do not claim product performance improvement from this tooling-only slice.

## Implementation Notes

- Added scripts/quality/record-gate-result.py as the first evidence manifest Module. It records individual gate results and summarizes records into JSON plus Markdown under logs/.
- Added make quality-manifest-self-test as an opt-in Adapter only; existing make build, make test-unit, make test-strict, and related gates are unchanged.
- Fixture self-test coverage includes passed, failed, skipped, and not_run, plus artifact present/missing checks and summary output generation.
- Verification run for this slice: python3 -m py_compile scripts/quality/record-gate-result.py, python3 scripts/quality/record-gate-result.py self-test --output-dir logs/quality-manifest-self-test-direct, and make quality-manifest-self-test all passed. The generated self-test manifest has overall_status=failed because it intentionally includes a synthetic failed fixture.
- Hardening after review: self-test --output-dir now treats the supplied path as a parent and writes into a timestamped child directory, preserving existing files in the parent.
- Hardening after review: default timestamped record and manifest paths add numeric suffixes on collision, avoiding silent same-second evidence overwrites.
- Final baseline gate evidence: logs/quality-main-final/quality-manifest-final.json and logs/quality-main-final/quality-manifest-final.md have overall_status=passed, four passed records, and six present artifacts.
- Product performance gates were intentionally not run for this slice because the implementation is tooling-only and does not touch search, scrolling, thumbnails, preview, cleanup, or other runtime hot paths.

## Follow-Up Candidates

- HistoryHoverPreviewPipeline remains the strongest direct frontend product-code candidate.
- Storage DeletePlan executor remains the lowest-risk product-code stability candidate.
- SearchIndexLifecycle remains a higher-risk performance/maintainability candidate after stronger evidence capture exists.

These follow-ups are not rejected. They are ordered after the Verification Evidence Manifest Module so later runtime work has stronger gate evidence.

## Accepted Q2 Decision: Storage DeletePlan Executor

The next product-code slice is Storage DeletePlan executor, selected by the GPT-5.5 xhigh grill-me Q2 recommendation in research/grill-q2-next-candidate.md.

This slice should deepen the existing StorageService Module by making DeletePlan execution the common internal Seam for cleanup plan execution. SQLiteClipboardRepository remains the SQL Adapter and StorageFileOps remains the file-removal Adapter. The implementation must preserve cleanup policy, pinned semantics, item ordering, cache invalidation intent, and DB-first external-file safety.

Implementation boundary:

- Route cleanupByCount, cleanupImagesOnlyByCount, cleanupByAge, cleanupBySize, and cleanupExternalStorage through applyDeletePlan or a narrow renamed equivalent.
- Keep deleteAllExceptPinned separate unless routing it through a compatible plan is clearer and behavior-preserving.
- Do not change cleanup thresholds, repository SQL planning, search behavior, preview behavior, settings semantics, UI text, or release metadata.
- Keep file deletion detached, bounded, and contextual in logs.

Required verification for this slice:

- Focused StorageService tests for DB-first failure safety, invalid storageRef skipping, and routed cleanup behavior.
- make build.
- make test-unit.
- make test-strict.
- make test-snapshot-perf-release only if repository SQL or cleanup planning semantics change beyond consolidation.

## Q2 Implementation Notes

- Promoted the existing `applyDeletePlan(_:logContext:)` helper into the common cleanup-plan executor Seam for `cleanupByCount`, `cleanupImagesOnlyByCount`, `cleanupByAge`, `cleanupBySize`, `cleanupExternalStorage`, and the existing composite cleanup path.
- Kept `SQLiteClipboardRepository` as the SQL Adapter; no repository SQL planning, cleanup thresholds, retention policy, pinned semantics, or ordering rules were changed.
- Preserved DB-first execution, storageRef validation, contextual log strings, external-size cache invalidation, and detached bounded file deletion inside `StorageService`.
- Kept `deleteAllExceptPinned()` separate because it must atomically capture every unpinned storage ref and delete rows inside one repository transaction without materializing all ids in `StorageService`.
- Added focused StorageService tests for routed count, images-only count, age, size, and external-storage cleanup execution, invalid storageRef skipping after DB deletion, and cleanup DB-failure safety.
- Verification run for this slice: focused new StorageService tests, focused `StorageServiceTests` plus `ResourceCleanupTests`, `git diff --check`, `make build`, `make test-unit`, and `make test-strict` all passed. Trellis check follow-up re-ran the seven routed/safety StorageService tests with isolated DerivedData after avoiding a shared Xcode `build.db` lock; the focused suite passed.
- Extra release snapshot performance also passed on the local snapshot DB: `cmd` p95 = 0.12004375457763672 ms (target 50 ms), `cm` p95 = 5.590915679931641 ms (target 20 ms).
- Final Storage evidence manifest: `logs/quality-storage-final-with-snapshot/quality-manifest-final.json` and `logs/quality-storage-final-with-snapshot/quality-manifest-final.md`, overall_status=passed with six passed records and nine present artifacts.

## Accepted Q3 Decision: Hover Preview Profile Evidence Slice

The next slice is not the full HistoryHoverPreviewPipeline refactor. The GPT-5.5 xhigh grill-me Q3 recommendation in `research/grill-q3-continue-or-stop.md` selected a smaller hover-specific evidence/profile slice first, because the existing frontend profile script summarized hover buckets but did not intentionally exercise hover preview behavior.

This slice deepens the frontend performance evidence Seam without changing normal preview behavior. It uses the existing `HistoryItemHarnessView` as the focused UI Adapter and extends `scripts/perf-frontend-profile.sh --include-hover` so later hover-preview runtime work can be measured through the same profile summary contract.

Implementation boundary:

- Add focused hover profile smoke tests for markdown text preview and image preview buckets.
- Keep the default `perf-frontend-profile.sh` behavior unchanged unless `--include-hover` is passed.
- Do not implement the full HistoryHoverPreviewPipeline refactor in this slice.
- Do not change release metadata or user-facing settings behavior.

Required verification for this slice:

- Focused hover harness UI tests.
- `scripts/perf-frontend-profile.sh --include-hover` smoke with real snapshot scenarios plus hover harness scenarios.
- `git diff --check` and script syntax check.
- `make build`.
- `make test-unit`.
- `make test-strict`.

## Q3 Implementation Notes

- Added `testHoverPreviewMarkdownProfileSmoke` and `testHoverPreviewImageProfileSmoke` to `HistoryItemViewUITests`, using the existing row harness to trigger true `HistoryItemView` preview work while avoiding full-list popover accessibility instability.
- Added a profile sampler to `HistoryItemHarnessView` so the shared `ScrollPerformanceProfile` report can emit frame/main-runloop metrics outside the full `HistoryListView` list profile.
- Added a harness image file path for the image scenario so `HoverPreviewLoader` exercises the real file-backed decode path and records `hover.preview_image_decode_ms`.
- Extended `scripts/perf-frontend-profile.sh --include-hover` to run two additional harness scenarios: `hover-preview-markdown-text` and `hover-preview-image`.
- Extended the script summary and validation to fail when hover scenarios are missing, preview was not triggered, or required hover buckets are absent.
- Focused harness evidence passed in `logs/hover-profile-harness-direct-2026-05-07_07-42-50/`; both raw JSON files include the required hover bucket and no missing bucket evidence.
- Script-level evidence passed in `logs/perf-frontend-hover-harness-smoke-2026-05-07_07-43-34/`; baseline/current both include the two hover scenarios and required buckets.
- Final hover evidence manifest: `logs/quality-hover-profile-final-2026-05-07_07-47-35/quality-manifest-final.json` and `.md`, overall_status=passed with six passed records and eleven present artifacts.
- Residual risk: macOS popover accessibility identifiers were not stable in the harness profile runs, so the gate records `preview_accessibility_found=false` as evidence and relies on the required hover buckets as the behavioral trigger proof.

## Accepted Q4 Decision: HistoryHoverPreviewPipeline

The broad objective is not complete after Q1-Q3. The GPT-5.5 xhigh grill-me Q4 completion audit in `research/grill-q4-completion-audit-next-candidate.md` selected HistoryHoverPreviewPipeline as the next product-code slice.

This slice should deepen the hover preview Module by moving preview request planning, cache lookup, loading decisions, stale/suppression checks, and metric emission behind a smaller internal pipeline Interface. `HistoryItemView` should keep row rendering, popover presentation, and accessibility identifiers stable while delegating preview work to the pipeline.

Implementation boundary:

- Add an internal HistoryHoverPreviewPipeline Module or equivalent narrow type under the existing History view area.
- Use typed request/result values instead of scattering image/file/text/markdown branch logic across row tasks.
- Reuse existing Adapters: `HoverPreviewLoader`, `FilePreviewSupport`, `MarkdownHTMLRenderer`, `HoverPreviewImageCache`, `MarkdownPreviewCache`, `HoverPreviewScreenMetrics`, `HoverPreviewImageQualityPolicy`, and `ScrollPerformanceProfile`.
- Preserve current user-facing preview behavior, popover identifiers, scroll suppression behavior, shared markdown preview controller use, and UI-test tap-preview behavior.
- Do not change release metadata, settings semantics, search semantics, storage behavior, or the default frontend profile script behavior.

Required verification for this slice:

- Focused tests for the new pipeline Interface where feasible, especially image cache hit/miss, markdown/text planning, stale/suppressed commits, and metric bucket emission.
- Focused hover harness UI tests.
- `scripts/perf-frontend-profile.sh --include-hover` smoke.
- `git diff --check` and script syntax check.
- `make build`.
- `make test-unit`.
- `make test-strict`.

## Q4 Implementation Notes

- Added `HistoryHoverPreviewPipeline` as the internal hover preview pipeline Module under `Scopy/Views/History/`. It exposes typed request, plan, and event values for image, file, markdown-file, and text preview flows.
- Kept `HistoryItemView` responsible for row rendering, popover presentation, preview state application, shared markdown webview coordination, tap-preview behavior, accessibility identifiers, and scroll-suppression ownership.
- Moved image/file/text/markdown planning, cache lookup, loading decisions, stale/suppression gates, markdown render task creation, and metric bucket emission behind the pipeline Interface.
- Reused the existing Adapters: `HoverPreviewLoader`, `FilePreviewSupport`, `MarkdownHTMLRenderer`, `HoverPreviewImageCache`, `MarkdownPreviewCache`, `HoverPreviewScreenMetrics`, `HoverPreviewImageQualityPolicy`, `ScrollPerformanceProfile`, and `HistoryItemPresentationCache`.
- Added focused `HistoryHoverPreviewPipelineTests` coverage for image plan cache keys/fallback, file plan cache/prefetch policy, markdown file cache key shape, cached markdown/text HTML metrics, suppression gating, and image cache-hit emission.
- Verification run for this slice passed: focused pipeline tests, `make build`, `make test-unit`, `make test-strict`, `bash -n scripts/perf-frontend-profile.sh`, `git diff --check`, and `scripts/perf-frontend-profile.sh --skip-setup --repeats 1 --duration 4 --min-samples 80 --include-hover`.
- Hover profile evidence was written to `logs/perf-frontend-profile-2026-05-07_08-31-28/frontend-scroll-profile-summary.json` and `.md`. The run executed three real snapshot scenarios plus markdown/image hover preview smokes; all five selected UI tests passed and required hover buckets were present.
- No product performance improvement is claimed from this refactor. The frontend profile run is smoke/noise evidence for the hot path, not a statistically controlled before/after benchmark.
- Trellis check follow-up kept `SendableCGImage`, `PreviewTaskBudget`, and `runBudgetedDetached` private to `HistoryHoverPreviewPipeline.swift` so the extracted pipeline does not expose implementation-only concurrency helpers at module scope.
- Trellis check follow-up moved markdown capability cache writes behind the post-detection current/suppression guard. This preserves the cache behavior for live hover tasks while avoiding stale or suppressed hover tasks updating `HistoryItemPresentationCache`.
- Final Q4 check evidence passed after the follow-up patch: focused pipeline tests, focused hover profile UI tests with `/tmp/scopy_run_profile_ui_tests`, `git diff --check`, `bash -n scripts/perf-frontend-profile.sh`, `make build`, `make test-unit`, `make test-strict`, and `scripts/perf-frontend-profile.sh --skip-setup --repeats 1 --duration 4 --min-samples 80 --include-hover`.
- Latest hover profile smoke evidence was written to `logs/perf-frontend-profile-2026-05-07_08-50-57/frontend-scroll-profile-summary.json` and `.md`. Required hover buckets were present for baseline/current markdown and image hover scenarios; real snapshot rows showed visible variance, so this run remains smoke/evidence-gate coverage and is not a performance-improvement claim.

## Accepted Q5 Decision: SearchExactQueryNormalization

The broad SearchIndexLifecycle extraction is out of scope for this task. The GPT-5.5 xhigh grill-me Q5 completion audit in `research/grill-q5-search-index-lifecycle.md` found real Locality friction in `SearchEngineImpl`, but judged the remaining risk/verification surface too broad for this architecture-quality task without a search-specific bottleneck or correctness failure.

If one more code slice is implemented before the final completion audit, it should be the smaller SearchExactQueryNormalization correctness slice. This slice should align the SearchPlanner and SearchEngineImpl exact-query length decision around a shared normalized query rule.

Implementation boundary:

- Add or reuse a pure SearchPlanner helper for exact-query normalization/length decisions.
- Make `SearchPlanner.planExact` and `SearchEngineImpl.searchExact` use the same normalized query for empty/short/long decisions.
- Preserve existing exact-search result semantics except for whitespace-only and whitespace-padded query normalization.
- Do not move SearchIndexLifecycle state, create a new actor, alter fuzzy/regex behavior, or change public search interfaces.

Required verification for this slice:

- Focused SearchPlannerTests for whitespace-only exact, whitespace-padded short exact, and whitespace-padded long exact decisions.
- Focused SearchServiceTests proving whitespace-padded short exact remains recent-only while whitespace-padded long exact reaches complete-history matches.
- `git diff --check`.
- `make build`.
- `make test-unit`.
- `make test-strict`.
- `make test-snapshot-perf-release` because backend search internals are touched.

## Q5 Implementation Notes

- Added `SearchPlanner.normalizedExactQuery(_:)` as the shared pure normalization helper for exact-query decisions. It trims leading/trailing whitespace and newlines without changing the public `SearchRequest` Interface.
- Routed `SearchPlanner.planExact` through the normalized query for empty, short, and FTS-capable long decisions so whitespace-only exact queries plan as `allWithFilters`, padded short exact queries plan as recent-only, and padded long exact queries plan as complete FTS.
- Routed `SearchEngineImpl.searchExact` through the same helper and used the normalized query for recent-cache matching, FTS query building, and the existing non-ASCII substring fallback.
- Preserved broad search architecture boundaries: no SearchIndexLifecycle extraction, no new actor, no public search Interface changes, no fuzzy/regex behavior changes.
- Added focused `SearchPlannerTests` for whitespace-only exact, whitespace-padded short exact, and whitespace-padded long exact path decisions.
- Added focused `SearchServiceTests` for whitespace-only exact all-items behavior, whitespace-padded short exact recent-only behavior beyond 2,000 rows, and whitespace-padded long exact complete-history older match behavior.
- Verification passed: focused xcodebuild suite for all `SearchPlannerTests` plus the three new `SearchServiceTests` cases executed 16 tests with 0 failures; `make build` passed; `make test-unit` passed with 433 tests, 1 skipped, 0 failures; `make test-strict` passed with 433 tests, 1 skipped, 0 failures.
- Snapshot release performance passed on `perf-db/clipboard.db`: `cmd` p95 = 0.11897087097167969 ms (target 50 ms), `cm` p95 = 5.738019943237305 ms (target 20 ms).
- Final Q5 main-thread evidence passed in `logs/quality-q5-final-2026-05-07_09-31-30/quality-manifest-final.json` and `logs/quality-q5-final-2026-05-07_09-31-30/quality-manifest-final.md`: six passed records, six present artifacts, and overall_status=passed.
- Final Q5 snapshot release performance from the main-thread gate: `cmd` p95 = 0.11801719665527344 ms (target 50 ms), `cm` p95 = 5.377054214477539 ms (target 20 ms).
