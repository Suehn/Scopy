# Frontend Scroll Performance Hardening

## Goal

Safely reproduce the proven passive-row and lazy-interaction scrolling architecture in the current Scopy worktree, close its known interaction regressions, and then continue trace-backed frontend optimization without changing user-visible clipboard, preview, note, export, image-optimization, popover, selection, or Settings Save/Cancel behavior.

## What I Already Know

- The supplied implementation report is from a different machine and is design evidence, not current-repository truth.
- Its measured direction was material: roughly half the row-body work and roughly one quarter less main-run-loop pressure in a warm, fixed-workload micro A/B.
- The intended architecture separates passive rendering from lazily created per-row interaction state, replaces visible-row scroll observers with one tokenized active slot, removes list-wide scroll-state invalidation, and centralizes bounded presentation/time caching.
- The external implementation still had two P1 interaction risks and did not complete the final current-code quality/performance gate.
- Repository policy requires availability guards for new system APIs, compiler-backed validation, release metadata/docs updates, and the prescribed performance commands.

## Requirements

1. Establish the current worktree and existing tests/scripts as the authoritative baseline; do not blindly copy paths, code, or metrics from the other machine.
2. Keep an idle history row passive: heavyweight preview, hover, note, export, optimization, and popover state must be created only for real interaction and safely released only when all owned work is idle.
3. Preserve stable row identity and correct content-revision boundaries so stale asynchronous work cannot render, export, or save against replaced clipboard content.
4. Make scroll-boundary coordination O(1) with token-safe active/suppressed interaction ownership; no list-wide observable scroll flag may fan out through idle rows.
5. Restore a stationary pointer's suppressed hover after live scrolling ends without reintroducing O(visible rows) observers.
6. Treat pointer interaction as scrollbar interaction only when mouse-down is actually inside a vertical or horizontal scroller; ordinary row/button/context-menu clicks must not tear down hover before their action completes.
7. Centralize bounded, invalidation-correct presentation and relative-time work outside row bodies; time updates must pause during scrolling/hidden-panel intervals and refresh at the correct boundary.
8. Preserve all existing user-facing behavior, including explicit Settings Save/Cancel semantics.
9. Add focused unit/UI/instrumentation coverage for lifecycle, content revision, token races, hover restoration, scrollbar hit testing, and metric correctness.
10. Reproduce the existing fixed-workload baseline/current harness where appropriate, clearly distinguish micro A/B from old-revision comparison, and retain auditable raw outputs.
11. Use current Apple documentation or sample code to verify exact signatures and platform availability before introducing or relying on system performance APIs.
12. After the reproduced architecture is stable, use code-first audit plus current profiling evidence to identify and implement the next highest-impact frontend bottleneck; do not optimize from intuition alone.
13. Update release metadata, release notes/index/CHANGELOG, and the release runbook/performance profile with environment and measured values as required by repository policy.

## Acceptance Criteria

- [x] Idle rows do not instantiate or observe heavyweight interaction models during the fixed warm-scroll scenario.
- [x] Starting/stopping live scroll does not rebuild all visible idle rows.
- [x] At most one active row observer and one tokenized suppressed-hover candidate exist on the passive path.
- [x] Hover resumes after scrolling stops while the pointer remains stationary, after the intended cooldown, and stale tokens cannot revive the wrong row.
- [x] A normal row/button click is never classified as scrollbar pointer interaction; vertical and horizontal scrollbar drags remain correctly observed.
- [x] Same-ID content replacement invalidates preview/note/export work, while an image-optimization task may survive only the revision transition it owns.
- [x] Presentation/time caches are bounded and have explicit invalidation semantics; measurement-phase cache misses meet the harness gate.
- [x] Existing preview, note, Markdown/PNG export, image optimization, popover, selection, pinning, deletion, and context-menu behavior has regression coverage or direct verification.
- [x] `make build` and `make test-unit` pass on final code.
- [x] `make test-strict` passes; `make test-tsan` is run because the change crosses async/observation/task lifecycles.
- [x] `make test-snapshot-perf-release` passes against the required current DB snapshot.
- [x] `make perf-frontend-profile` and `make perf-frontend-profile-standard` complete on final code; causal fixed workloads and composite real-snapshot guards remain explicitly separated.
- [x] The final fixed frontend profiles show repeatable improvement across both AB and BA orderings without correctness-gate regressions; metrics and broader-profile caveats are reported precisely.
- [x] `make perf-unified-table` produces the required backend/frontend comparison artifact from final outputs.
- [x] Release validation and documentation checks pass with the current repository version metadata.
- [x] A final requirement-by-requirement audit links every claim to current code, test output, or performance artifacts.
- [x] The post-reproduction trace-selected Markdown menu predicate no longer rescans up to 4,096 characters in every row body, while exact export-capability semantics remain unchanged.
- [x] A same-binary passive/passive AB/BA proves the menu-signal cache slice with equal work, current cache hits, zero measurement misses, and repeatable row-body improvement.

## Definition of Done

- Implementation is clear, localized, explicitly owned, and extensible rather than a collection of scattered availability or feature-flag branches.
- Tests cover both success and race/teardown paths; no placeholder implementation remains.
- Build, unit, strict-concurrency, thread-sanitizer, backend performance, frontend performance, unified reporting, and documentation gates are complete or an external tool limitation is documented with raw evidence and an equivalent safe check where possible.
- Required release metadata, version document, indexes, CHANGELOG, performance profile, and runbook entries are updated.
- No commit, tag, push, release, or Homebrew mutation is performed unless the user separately authorizes that external state change.

## Decision (ADR-lite, provisional)

**Context**: The proven gains come from reducing observation and interaction-object fan-out, while the known failures come from lifecycle boundaries and hit-testing shortcuts.

**Decision**: Reconstruct the optimization in small, testable layers: first instrumentation/contracts, then passive interaction ownership and revision safety, then O(1) scroll/hover coordination and scrollbar-specific hit testing, then caches/time clock, and finally evidence-led follow-on optimization. Keep a controlled legacy comparison path only where it is needed for fixed-workload measurement.

**Consequences**: Each risky state transition gets an explicit test seam, rollback remains local, and microbenchmark support code stays outside product behavior. The work is necessarily layered because revision ownership, interaction lifetime, pointer routing, and measurement validity are independent correctness boundaries.

## Out of Scope

- Changing clipboard history product semantics, Settings transaction behavior, visual design, or deployment/version baselines.
- Claiming FPS/presented-frame improvements from callback intervals or sampled profiler weight.
- Treating a same-binary micro A/B as an old-commit-versus-new-commit benchmark.
- Shipping, tagging, pushing, publishing a GitHub release, or changing Homebrew state without explicit user authorization.

## Technical Notes

- External report source: `/Users/hh/.codex/attachments/dd641f0c-7776-4828-bf12-0b322747f99c/pasted-text-1.txt`.
- Known P1 #1: suppressed hover must be tokenized and restored after scroll-end cooldown even when SwiftUI does not emit another `hover=true`.
- Known P1 #2: local mouse monitoring must hit-test the actual scrollbars and pair mouse-up only with a scrollbar-originated mouse-down.
- External metrics are hypotheses/targets until reproduced in this repository and on this machine.
- Current baseline is `db7503a74797814d3df2e204370ecdeddcd6eb2c` (`v0.8.8` tag ancestry) on a dirty worktree that already contains safe-triangle and release/build changes. Those changes are authoritative user work and must be integrated, not overwritten.
- Current repository baselines remain Swift 5.9 and macOS 14.0 from `project.yml`. The executing machine is Apple M3 Pro, macOS 15.7.3, Xcode 26.1.1, with XcodeGen 2.45.4 available.
- Pre-change current-dirty-tree correctness checks completed successfully: `make build`, `make test-unit` (535 tests, 1 skipped, 0 failures), and `git diff --check`.
- Current architecture evidence is recorded in `research/current-row-architecture.md`; the row still eagerly creates three interaction objects and each visible row registers for broadcast scroll events.
- Interaction state-machine and hit-testing decisions are recorded in `research/scroll-interaction-risks.md`. The coordinator will own a tokenized active slot, suppressed-hover candidate, scrollbar pointer token, and cooldown generation.
- Measurement limitations and the required fixed-workload/real-snapshot split are recorded in `research/performance-harness-and-gates.md`. Timeline callbacks will not be relabeled as presented FPS.
- Apple API signatures and availability are recorded in `research/apple-api-contracts.md` and compiler-checked by `research/apple-api-probe.swift` against `arm64-apple-macos14.0`.
- `NSScroller.testPart(_:)` receives a window-coordinate point and returns `.noPart` for a non-actionable location. Scroller visibility/window attachment and matching down/up ownership are therefore part of the adapter contract.
- `NSScreen.displayLink(target:selector:) -> CADisplayLink` is available at the project macOS 14 baseline; the deterministic driver encapsulates lifecycle and invalidation in the test/profile adapter.
- The first post-reproduction live sample is recorded in `research/next-bottleneck-markdown-menu-signal.md`: 411 of 457 sampled `HistoryItemView.body` stacks entered the uncached Markdown menu fast-signal predicate.

## Research-backed Implementation Plan

1. Harden the profiler storage and metric semantics, then add a deterministic Release micro-workload contract without changing production behavior.
2. Introduce one deterministic shared content revision and make preview, note, export, optimization, display, and cache boundaries consume it consistently.
3. Replace the three eager row objects with one optional interaction session whose release invariant accounts for every owned task, popover, transfer, editor, and feedback lifetime.
4. Replace row-observer broadcast with tokenized O(1) active/suppressed ownership, including A -> B -> A stale-cancellation protection and stationary-hover restoration after the 250 ms cooldown.
5. Restrict pointer suppression to actual vertical/horizontal scroller parts with paired pointer tokens; ordinary row, button, context-menu, and popover clicks remain transparent.
6. Finish bounded presentation/relative-time caching and list-level clock ownership, including scroll/hidden-panel pause and boundary-correct refresh.
7. Run causal micro A/B and realistic snapshot gates; only then use current traces to choose one additional bottleneck and remeasure it.
8. Implement the trace-selected revision-keyed Markdown menu fast-signal cache, prewarm it off-main, and isolate it with a passive/passive fixed-workload AB/BA axis before making any broader row-graph change.

## Baseline and Evidence Policy

- External measurements are context only. All completion claims must use artifacts produced from this worktree and machine.
- The deterministic micro A/B proves the passive-row causal change; the real-snapshot profile proves realistic regression safety. They are reported separately.
- Raw manifests must record workload, loaded/total rows, pagination, command count, intended/observed path, build configuration, environment, cache counters, and structural ownership counters.
- AB and BA orderings are both required. A summary is invalid if workload or correctness gates differ between sides.
- The current application-support database must be snapshotted and fingerprinted immediately before final backend/frontend performance gates; the ignored snapshot is evidence input, not source.
