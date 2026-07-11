# Final Verification

## Requirement Evidence

| Requirement | Current evidence |
| --- | --- |
| 1. Current worktree is authoritative | Baseline recorded in `prd.md`; existing dirty changes were preserved; all final evidence was generated from this worktree rather than copied from the external report. |
| 2. Passive row and lazy owned interaction | `Scopy/Views/History/HistoryItemView.swift`, `HistoryItemInteractionState.swift`, and fixed-profile structural counters; passive runs report zero idle sessions. |
| 3. Stable identity and revision safety | `Scopy/Presentation/ClipboardItemContentRevision.swift` plus focused preview, note, export, optimization, cache, and same-ID replacement tests. |
| 4. O(1) scroll ownership | `HistoryListInteractionCoordinator.swift`; passive fixed runs report zero row scroll observers and one tokenized active/suppressed owner. |
| 5. Stationary-hover restoration | Coordinator stale-token/cooldown tests and history-list UI coverage restore the valid row without a new mouse-move event. |
| 6. Scroller-only pointer suppression | `ListLiveScrollObserverView.swift` plus vertical, horizontal, hidden/no-part, other-window, ordinary-click, and paired down/up tests. |
| 7. Bounded presentation/time work | `HistoryItemPresentationCache.swift`, `HistoryRelativeTimeClock.swift`, capacity/generation tests, scroll/hidden clock tests, and zero measurement-phase menu misses. |
| 8. User-visible behavior preserved | Existing preview, note, export, optimization, popover, selection, pin/delete, context-menu, and Settings transaction tests passed in unit/strict/TSan suites. |
| 9. Focused lifecycle/instrumentation coverage | New lifecycle, revision, coordinator, hit-test, cache, metric, and UI cases; final full suites and TSan passed. |
| 10. Auditable fixed workload | `scripts/perf-warm-scroll-ab.sh` validates Release, equal work, complete outputs, exact AB/BA ordering, axis isolation, counters, and all-pair gates; raw JSON/logs are retained. |
| 11. Apple API verification | `research/apple-api-contracts.md` and compiler probe verify `NSScroller.testPart(_:)` and `NSScreen.displayLink(target:selector:)` at the macOS 14 baseline; final compiler/build gates passed. |
| 12. Trace-backed follow-on | `research/next-bottleneck-markdown-menu-signal.md`, live `sample` output, separate revision-keyed heuristic/exact caches, and the formal passive/passive menu-cache A/B. |
| 13. Release evidence and metadata | `v0.65.0` release note, CHANGELOG, release index, product/development specs, runbook, release profile, and metadata; docs/release validation passed. |

## Quality Gates

- `make build`: passed.
- `make test-unit`: 701 executed, 1 skipped, 0 failures.
- `make test-strict`: 701 executed, 1 skipped, 0 failures.
- `make test-tsan`: 681 executed, 1 skipped, 0 failures; no race reports.
- `make snapshot-perf-db`: 7,807 rows, 98,922,496 bytes, SHA-256 `3ec03a0ccd6b486e9f36f26c6597245828cf93fe23f5582908e0cfa260145ddd`.
- `make test-snapshot-perf-release`: `cmd p95 0.092983ms`, `cm p95 1.811981ms`, passed.
- Both fixed Release AB/BA axes: five pairs and ten unattended runs per axis, equal observed work, passed.
- `make perf-frontend-profile` and `make perf-frontend-profile-standard`: passed on the final code.
- Backend control audit and `make perf-unified-table`: passed.

## Performance Artifacts

- Final fixed suite: `logs/perf-warm-scroll-2026-07-11-formal`
- Passive-row causal A/B: `logs/perf-warm-scroll-2026-07-11-formal/passive-row/warm-scroll-ab-summary.md`
- Live post-reproduction sample: `logs/perf-next-bottleneck-2026-07-11_04-40/scopy-live.sample.txt`
- Markdown menu-cache causal A/B: `logs/perf-warm-scroll-2026-07-11-formal/markdown-menu-cache/warm-scroll-ab-summary.md`
- Final real-snapshot smoke: `logs/perf-frontend-profile-2026-07-11_15-26-55/frontend-scroll-profile-summary.md`
- Final real-snapshot standard: `logs/perf-frontend-profile-2026-07-11_15-29-18/frontend-scroll-profile-summary.md`
- Earlier three-repeat real-snapshot full guard: `logs/perf-frontend-profile-2026-07-11_09-51-16/frontend-scroll-profile-summary.md`
- Backend control: `logs/perf-audit-2026-07-11_15-31-final-current`
- Unified table: `logs/perf-unified-2026-07-11_15-32-45.md`

The final fixed suite used one Release build and byte-identical source, executable, build-artifact, environment, and suite manifests across both axes. Each of the twenty raw runs completed 1,440 commands, two warm rounds, and the same 51,270px observed path. On the passive-row axis, median row-body count fell `66.49%`, row-body total time fell `61.07%`, and main-run-loop total time fell `3.77%`; all five pairs improved those three metrics. Main-run-loop p95 improved `4.94%` at the medians, with one pair at `+0.38%`, within the `+10%` guard.

In the menu-cache axis, both variants remained passive. Median row-body total fell `92.09%`, main-run-loop total time fell `9.61%`, and main-run-loop p95 fell `12.93%`; all five pairs improved row-body and run-loop totals. Current had zero measurement misses/uncached scans. The real-snapshot standard profile is a composite single-repeat regression guard with visible scenario noise, not causal evidence; display-link callback cadence is not FPS.

The earlier three-repeat full composite guard completed with complete output but retained a contradictory text-biased signal: main-run-loop p95 improved in two pairwise repeats and regressed in one, aggregate long-frame count improved `326 -> 258`, and callback over-threshold ratio worsened at the medians. It used the 7,794-row snapshot before the final clock/tooling commits. The product path is applicable, but the artifact is retained only as a broader historical guard. This composite comparison disables five older feature flags together and leaves passive rows/menu caching enabled on both sides, so it is not causal evidence for this task. The variance is documented for follow-up rather than silently labeled green.
