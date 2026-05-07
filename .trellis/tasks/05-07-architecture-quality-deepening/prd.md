# Improve Scopy architecture performance stability maintainability

## Goal

Improve Scopy's performance, stability, and maintainability through evidence-backed architecture deepening. The work must use `grill-me` and `improve-codebase-architecture`, follow Trellis phases, preserve existing behavior, add rigorous tests where useful, and continue until the remaining improvement candidates are either implemented, rejected with evidence, or explicitly out of scope for this task.

## What I Already Know

* User objective explicitly requests `$grill-me` and `$improve-codebase-architecture`.
* During grilling, questions are one-at-a-time. If a question can be answered by exploring the codebase, the agent should explore instead of asking the human.
* The user allows a GPT-5.5 xhigh agent to choose high-quality recommended answers during grilling instead of requiring manual human answers.
* The user requires waiting for agent results unless an agent exceeds one hour without a response.
* Current release metadata points to `v0.7.6` with recent architecture work around `HistoryItemRowDescriptor`, `HistoryRowThumbnailLifecycleScheduler`, and frontend profile isolation.
* Worktree was clean at task creation; local branch was ahead of `origin/main` by 14 commits.
* Active product constraints include macOS 14+, Swift 5.9, Xcode 16, current settings transaction semantics, and documented search/preview/storage contracts.

## Assumptions

* The first pass should not re-open the just-completed `v0.7.6` row descriptor and thumbnail scheduler work unless fresh evidence shows a remaining issue.
* The strongest near-term improvements should come from measured friction in real code paths, not speculative rewrites.
* A candidate is complete only after implementation and verification evidence cover its actual risk surface.

## Open Questions

* Resolved by research/grill-q1-first-candidate.md: implement the Verification Evidence Manifest Module first.

## Requirements

* Use Trellis task artifacts as the source of truth for this work.
* Use `trellis-research` agents for evidence gathering and persist findings under `research/`.
* Use exact Trellis agents for authoritative implementation/check work when dispatching sub-agents.
* Run a `grill-me` loop for the selected candidate and record the question, the GPT-5.5 xhigh recommended answer, and the accepted decision.
* Apply `improve-codebase-architecture` vocabulary consistently: Module, Interface, Implementation, Depth, Seam, Adapter, Leverage, Locality.
* Prefer codebase inspection over asking the human whenever the answer is derivable locally.
* Preserve existing user-facing behavior unless a change is explicitly documented and verified.
* Keep heavy work off the main thread and avoid broad rewrites without measured benefit.
* Add or update tests for any behavior, concurrency, stability, or performance-sensitive change.
* Do not mark the overall goal complete until a completion audit maps each explicit objective requirement to concrete evidence.

## Acceptance Criteria

* [x] At least three architecture deepening candidates are identified from code and evidence.
* [x] Each candidate records files/modules involved, problem, solution, benefits, risks, and verification strategy.
* [x] One candidate is selected through a one-question-at-a-time grilling loop with GPT-5.5 xhigh recommended answers.
* [x] The selected candidate has an `info.md` technical design or equivalent decision record in this task directory.
* [x] Q4 selected follow-up implementation, HistoryHoverPreviewPipeline, is complete and scoped to the selected candidate.
* [x] Relevant unit tests or focused regression tests are added/updated and pass for the Q4 slice.
* [x] Baseline gates pass after Q4: `make build`, `make test-unit`, and `make test-strict`.
* [x] Performance gates are run after Q4 because the selected change affects preview hot paths.
* [x] Documentation/release metadata is updated if the user-visible contract or release-facing evidence changes. Not applicable to release metadata; task-local docs were updated.
* [x] Completion audit shows no explicit requirement from the implemented slices remains missing, weakly verified, or unaddressed.

## Definition Of Done

* Trellis Plan, Execute, and Check artifacts are present and current.
* Agent research/check outputs are available in files or final agent results.
* Implementation diff is reviewable and avoids unrelated refactors.
* Verification commands and outcomes are recorded in this PRD or `info.md`.
* Residual risks and out-of-scope candidates are explicitly documented.

## Out Of Scope

* Cloud sync, semantic search, or major product feature work.
* Raising Swift, Xcode, or macOS deployment baselines.
* Releasing a new version unless the user explicitly asks for release/publish after this improvement work.
* Rewriting the entire app architecture without candidate-specific evidence.

## Research References

* research/frontend-hot-paths.md - frontend candidates; recommends HistoryHoverPreviewPipeline as the strongest direct UI/runtime follow-up.
* research/backend-stability.md - backend candidates; recommends Storage DeletePlan executor as the first product-code stability follow-up.
* research/quality-tooling.md - quality/tooling candidates; recommends Verification Evidence Manifest Module first.
* research/grill-q1-first-candidate.md - grill-me accepted decision selecting the first implementation slice.
* research/grill-q2-next-candidate.md - grill-me accepted decision selecting Storage DeletePlan executor as the next product-code slice.
* research/grill-q3-continue-or-stop.md - grill-me accepted decision to add a hover-specific evidence/profile slice before any wider HistoryHoverPreviewPipeline refactor.
* research/grill-q4-completion-audit-next-candidate.md - completion audit and grill-me accepted decision selecting HistoryHoverPreviewPipeline as the next product-code slice.
* research/grill-q5-search-index-lifecycle.md - completion audit and grill-me accepted decision to keep broad SearchIndexLifecycle out of scope for this task and, if continuing, implement the smaller SearchExactQueryNormalization correctness slice.

## Technical Notes

* Current release source of truth: `doc/meta/release-current.yml`.
* Active requirements: `doc/current/product-spec.md`.
* Active development guide: `doc/current/development-guide.md`.
* Architecture skill requires reading domain glossary/ADRs if present; no repo `CONTEXT.md` or ADR files were found in the initial scan.
* Memory indicates Scopy performance work should profile first, attribute long frames, then optimize and rerun release-grade evidence. It also warns that row-level micro-optimizations can fail on real snapshot metrics and should not be treated as progress without measurement.

## Verification Evidence

### Quality Evidence Manifest Module

* Implementation slice: Verification Evidence Manifest Module, documented in `info.md`.
* Final manifest: `logs/quality-main-final/quality-manifest-final.json` and `logs/quality-main-final/quality-manifest-final.md`.
* Final manifest overall_status: `passed`.
* Final manifest records: `git-diff-check`, `make-build`, `make-test-unit`, and `make-test-strict` all passed.
* Artifact accounting: 6 present artifacts, 0 missing artifacts.
* Focused hardening checks covered self-test output directory preservation and same-second output path uniqueness.
* No product runtime behavior changed; therefore snapshot/frontend performance gates were not required for this slice.

### Storage DeletePlan Executor

* Implementation slice: Storage DeletePlan executor, documented in `info.md` and research/grill-q2-next-candidate.md.
* Final manifest: `logs/quality-storage-final-with-snapshot/quality-manifest-final.json` and `logs/quality-storage-final-with-snapshot/quality-manifest-final.md`.
* Final manifest overall_status: `passed`.
* Final manifest records: `focused-storage-delete-plan-tests`, `git-diff-check`, `make-build`, `make-test-unit`, `make-test-strict`, and `make-test-snapshot-perf-release` all passed.
* Artifact accounting: 9 present artifacts, 0 missing artifacts.
* Snapshot release performance: `cmd` p95 = 0.12004375457763672 ms (target 50 ms); `cm` p95 = 5.590915679931641 ms (target 20 ms).
* Earlier `logs/quality-storage-final/`, `logs/quality-storage-final-rerun/`, and `logs/quality-storage-final-passed/` manifests are superseded by the final with-snapshot manifest.

### Hover Preview Profile Evidence

* Implementation slice: hover-specific profile evidence gate, selected by research/grill-q3-continue-or-stop.md before attempting a wider HistoryHoverPreviewPipeline refactor.
* Focused harness evidence: `logs/hover-profile-harness-direct-2026-05-07_07-42-50/` passed both `testHoverPreviewMarkdownProfileSmoke` and `testHoverPreviewImageProfileSmoke`.
* Script-level evidence: `logs/perf-frontend-hover-harness-smoke-2026-05-07_07-43-34/` passed `scripts/perf-frontend-profile.sh --skip-setup --repeats 1 --duration 4 --min-samples 80 --include-hover`.
* Hover bucket evidence: baseline/current both produced `hover.markdown_render_ms` for `hover-preview-markdown-text` and `hover.preview_image_decode_ms` for `hover-preview-image`, with no missing required buckets.
* Final manifest: `logs/quality-hover-profile-final-2026-05-07_07-47-35/quality-manifest-final.json` and `logs/quality-hover-profile-final-2026-05-07_07-47-35/quality-manifest-final.md`.
* Final manifest overall_status: `passed`.
* Final manifest records: `hover-harness-ui-tests`, `perf-frontend-profile-include-hover`, `git-diff-check`, `make-build`, `make-test-unit`, and `make-test-strict` all passed.
* Artifact accounting: 11 present artifacts, 0 missing artifacts.

### HistoryHoverPreviewPipeline

* Implementation slice: HistoryHoverPreviewPipeline, selected by research/grill-q4-completion-audit-next-candidate.md after the Q4 completion audit concluded the broad objective was not complete.
* Product-code change: added `Scopy/Views/History/HistoryHoverPreviewPipeline.swift` as the internal preview pipeline Module and routed `HistoryItemView` image/file/text/markdown preview work through typed request/event values while preserving row rendering, popover presentation, accessibility identifiers, tap-preview behavior, shared markdown WebView coordination, and scroll suppression ownership.
* Focused tests: `ScopyTests/HistoryHoverPreviewPipelineTests.swift` adds seven tests for cache key planning, file plan policy, markdown-file cache key shape, cached markdown/text metrics, suppression gating, and image cache-hit emission.
* Trellis check fixes: kept `SendableCGImage`, `PreviewTaskBudget`, and `runBudgetedDetached` private to the pipeline file; moved markdown capability cache writes behind the post-detection current/suppression guard.
* Final manifest: `logs/quality-q4-final-2026-05-07_08-58-23/quality-manifest-final.json` and `logs/quality-q4-final-2026-05-07_08-58-23/quality-manifest-final.md`.
* Final manifest overall_status: `passed`.
* Final manifest records: `diff-and-script-check`, `focused-history-hover-preview-pipeline-tests`, `make-build`, `make-test-unit`, `make-test-strict`, and `perf-frontend-profile-include-hover` all passed.
* Artifact accounting: 9 present artifacts, 0 missing artifacts.
* Hover profile smoke: `logs/perf-frontend-profile-2026-05-07_08-50-57/frontend-scroll-profile-summary.md` includes baseline/current markdown and image hover preview scenarios with required hover buckets present. This is smoke/evidence-gate coverage only, not a performance-improvement claim; real snapshot rows showed visible variance.

### SearchExactQueryNormalization

* Implementation slice: SearchExactQueryNormalization, selected by research/grill-q5-search-index-lifecycle.md after the Q5 completion audit kept broad SearchIndexLifecycle out of scope for this task.
* Product-code change: added `SearchPlanner.normalizedExactQuery(_:)` as the shared exact-query normalization helper and routed `SearchPlanner.planExact` plus `SearchEngineImpl.searchExact` through the same trimmed query rule.
* Focused tests: `SearchPlannerTests` covers whitespace-only exact, whitespace-padded short exact, and whitespace-padded long exact planning; `SearchServiceTests` covers whitespace-only all-items behavior, padded short recent-only behavior, and padded long complete-history matching.
* Final manifest: `logs/quality-q5-final-2026-05-07_09-31-30/quality-manifest-final.json` and `logs/quality-q5-final-2026-05-07_09-31-30/quality-manifest-final.md`.
* Final manifest overall_status: `passed`.
* Final manifest records: `diff-check`, `focused-search-exact-normalization-tests`, `make-build`, `make-test-unit`, `make-test-strict`, and `make-test-snapshot-perf-release` all passed.
* Artifact accounting: 6 present artifacts, 0 missing artifacts.
* Focused final test evidence: selected SearchPlanner/SearchService tests executed 16 tests with 0 failures.
* Snapshot release performance: `cmd` p95 = 0.11801719665527344 ms (target 50 ms); `cm` p95 = 5.377054214477539 ms (target 20 ms).

## Completion Audit

* Trellis artifacts: created PRD, `info.md`, research files, and validated implement/check context entries.
* Architecture candidates: frontend hover preview pipeline, storage delete-plan executor, quality evidence manifest, and search index lifecycle/search exact normalization were researched.
* Grill decision: GPT-5.5 xhigh recommended the quality evidence manifest first because it gives later runtime changes a stronger verification Seam.
* Grill decision: GPT-5.5 xhigh recommended Storage DeletePlan executor as the next product-code slice because it has the clearest safety Seam, existing SQL/file Adapters, and smaller verification surface than hover preview.
* Grill decision: GPT-5.5 xhigh recommended adding hover-specific evidence before any full HistoryHoverPreviewPipeline refactor because the existing frontend profile harness did not intentionally exercise hover preview buckets.
* Implementation: added the opt-in manifest Module and Makefile Adapter without replacing existing gates; consolidated Storage cleanup plan execution behind `applyDeletePlan`; added a focused hover-preview harness/profile gate and `--include-hover` script Adapter; extracted HistoryHoverPreviewPipeline as the hover-preview runtime Module; aligned exact-search planning/execution around shared query normalization.
* Verification: py_compile, direct self-test, Makefile self-test, focused routed storage tests, focused hover harness UI tests, focused pipeline tests, frontend profile script with hover included, git diff checks, make build, make test-unit, make test-strict, make test-snapshot-perf-release, and final manifest summarization passed.
* Q4 completion audit: the broad objective was not complete yet. The full HistoryHoverPreviewPipeline refactor and SearchIndexLifecycle were still deferred, not rejected or out of scope.
* Grill decision: GPT-5.5 xhigh recommended HistoryHoverPreviewPipeline as the next product-code slice because Q3 created the missing hover profile evidence Seam and the row still owns too much preview planning/loading/cache/metric Implementation.
* Q4 implementation is complete and verified.
* Q5 completion audit: broad SearchIndexLifecycle is explicitly out of scope for this task. It remains a future search-focused candidate only with a fresh bottleneck/correctness failure and same-actor lifecycle design.
* Grill decision: GPT-5.5 xhigh recommended SearchExactQueryNormalization as the smaller next code slice if continuing, because exact search currently has a planner/execution normalization drift around raw query length vs trimmed query intent.
* Q5 implementation is complete and verified. No remaining explicit requirement from this task remains missing, weakly verified, or unaddressed.
