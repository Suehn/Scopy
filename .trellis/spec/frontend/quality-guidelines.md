# Quality Guidelines

> UI quality, test, accessibility, and performance standards for Scopy.

---

## Required Patterns

- Preserve native macOS behavior: SwiftUI first, AppKit/WebKit bridges where necessary.
- Preserve Settings Save/Cancel transaction semantics (AGENTS.md:105-107).
- Keep list rendering performance-aware. HistoryListView uses List for recycling and profile hooks for scroll metrics (Scopy/Views/HistoryListView.swift:57-60, Scopy/Views/HistoryListView.swift:128-145, Scopy/Views/HistoryListView.swift:337-341).
- Keep accessibility identifiers stable when UI tests depend on them.
- Keep visible text compact and localized consistently with existing UI copy style. This project currently has Chinese UI strings in settings and some controls; follow nearby files.

---

## Testing Requirements

Default gates after UI changes:

1. make build
2. make test-unit

Add gates by risk:

- User flow or window behavior: focused ScopyUITests.
- Settings save/cancel behavior: settings UI tests and relevant unit tests.
- History row/list/context menu behavior: history UI tests.
- Scroll/render/thumbnail/preview performance: make perf-frontend-profile; use make perf-frontend-profile-standard for stronger evidence (AGENTS.md:20-24, AGENTS.md:57-59, Makefile:318).
- Hotkey behavior: inspect /tmp/scopy_hotkey.log for updateHotKey() and one trigger per press (AGENTS.md:24-25, AGENTS.md:99-103).

---

## Accessibility And UI Tests

UI tests depend on stable identifiers and launch environment. Existing identifiers include History.List, row IDs, history context menu IDs, and settings action buttons (Scopy/Views/HistoryListView.swift:128, Scopy/Views/HistoryListView.swift:321, Scopy/Views/History/HistoryItemView.swift:911-948, Scopy/Views/Settings/SettingsView.swift:235-257).

Use existing UI test helpers and fixtures under ScopyUITests before inventing new harness behavior.

---

## Performance Review

Before claiming UI performance improved:

- Capture profiler output, not only subjective smoothness.
- Use real snapshot DB flows when the change affects large history behavior.
- Include before/after numbers in docs or final notes when requested.
- Watch for hidden costs in row body recomputation, thumbnail loading, markdown rendering, WebView lifecycle, and QuickLook.

For frontend profile runs, keep the app process state isolated. scripts/perf-frontend-profile.sh must quit the com.scopy.app bundle, clear any remaining Scopy executable process before the first xcodebuild run, between baseline/current variants, and on exit. If a profile run fails before summary generation with missing Window/History.List or an XCElementSnapshot automation crash, first check for residual Scopy/XCTest processes and rerun after cleanup; no summary file means there is no performance evidence to cite.

### Scenario: File-Coordination-Safe XCTest Performance Artifacts

1. **Trigger**: Any XCTest or UI-performance run reads a DB/fixture or writes metrics while the repository is under `~/Documents`, iCloud Drive, or another file-provider-managed location.
2. **Interfaces**: `SCOPY_PROFILE_OUTPUT`, `SCOPY_UI_PROFILE_OUTPUT_DIR`, and `SCOPY_UI_PROFILE_DB_PATH` must resolve to `/tmp` or DerivedData while the test process is running. `SCOPY_PROFILE_START_NOTIFICATION` may start app-side scrolling after launch. Unit fixtures use `TestFixture.data(_:)` or `TestFixture.url(_:)` from the test bundle.
3. **Contract**: The test process never opens repository runtime fixtures through `#filePath` and never writes in-progress JSON directly to repository `logs/`. A shell wrapper copies the DB into temporary storage before launch and copies only a complete output back after successful `xcodebuild`. Start notification, scroll-view resolution, display-link invalidation, and output copy each have one owner.
4. **Validation matrix**:

   | Path | Required result |
   | --- | --- |
   | Fixed baseline/current AB and BA | Equal observed work; complete JSON; no manual input |
   | Real-snapshot smoke/standard | All scenarios produce summaries from the temporary DB copy |
   | Unit fixture and renderer asset reads | Resolve from the test bundle in unit, strict, and TSan schemes |
   | Failure before complete output | No partial repository artifact is accepted as evidence |

5. **Examples**: Good: bundle fixture -> XCTest, or repository DB -> `/tmp` copy -> app -> `/tmp` JSON -> completed `logs/` copy. Baseline-only: direct repository reads that happen to work outside a managed folder. Bad: adding mouse movement, activation retries, or watchdogs around a blocked `open()` call.
6. **Tests/evidence**: Run the focused fixture/renderer tests, `make test-unit`, `make test-strict`, `make test-tsan`, fixed AB/BA, and real-snapshot smoke/standard. When diagnosing a stall, sample the runner and distinguish scroll completion from filesystem `open()` blocking.
7. **Wrong/correct**: Wrong: infer that pointer movement starts scrolling because it coincides with output appearing. Correct: verify the runner stack, keep runtime I/O outside the managed repository path, and require unattended repeated completion.

### Scenario: Revision-Keyed Context-Menu Predicates

1. **Scope / trigger**: A history-row context-menu predicate performs stable content analysis, especially when SwiftUI may reevaluate the menu closure during every `HistoryItemView.body` pass.
2. **Signatures**:
   - `HistoryItemPresentationCache.markdownMenuSignal(for:plainText:) -> Bool` consumes the row's existing `ClipboardItemContentRevision`.
   - `HistoryItemPresentationCache.cachedMarkdownExportCapability(for:) -> Bool?` remains the exact capability lookup.
   - `scripts/perf-warm-scroll-ab.sh --axis markdown-menu-cache` compares the same passive-row binary with only `SCOPY_PERF_MARKDOWN_MENU_SIGNAL_CACHE` changed.
3. **Contracts**:
   - Cache both positive and negative heuristic results by content revision, with a maximum of 4,096 entries.
   - Exact capability always takes precedence over the heuristic, including exact `false`; never store a fast signal in the exact capability cache.
   - Prewarm text/RTF/HTML signals on a detached utility task, deduplicate in-flight revisions, and store only when the captured cache generation still matches.
   - `SCOPY_PERF_MARKDOWN_MENU_SIGNAL_CACHE` defaults to enabled; `0` is measurement-only and must not alter passive-row ownership or product behavior.
4. **Validation & error matrix**:

   | Condition | Required result |
   | --- | --- |
   | Cached exact `true` or `false` | Return exact value without consulting the heuristic |
   | Cache hit for unchanged revision | Return cached signal and increment the hit counter |
   | First miss with capacity | Scan at most 4,096 characters once, cache the result, and record miss timing |
   | Same item ID with changed content revision | Do not reuse the old signal |
   | Duplicate or stale prewarm completion | Do not duplicate work or commit across `clearCaches()` generation changes |
   | Cache at capacity | Remain bounded; correctness falls back to synchronous computation |

5. **Good/base/bad cases**: Good: prewarmed revision -> exact lookup -> heuristic cache hit. Base: first interaction misses once and stores `true` or `false`. Bad: call `MarkdownDetector.hasFastMarkdownSignal` directly from each row body, or treat its heuristic result as exact export capability.
6. **Tests required**: Assert exact `true`/`false` precedence, positive/negative cache hits, same-ID revision replacement, clear/generation rejection, in-flight deduplication, 4,096-entry bounding, feature-flag metrics, and a passive/passive AB/BA with equal work, current hits, zero current measurement misses, and all-pair row-body improvement.
7. **Wrong vs correct**: Wrong: optimize menu construction by removing keyboard/accessibility behavior or lazily enabling the menu only after hover. Correct: preserve the menu surface and remove only repeated stable analysis through a separate revision-keyed presentation cache.

### Scenario: Composite Real-Snapshot Profile Interpretation

1. **Scope / trigger**: Any release, performance, or regression claim that cites `scripts/perf-frontend-profile.sh` or one of the `make perf-frontend-profile*` targets.
2. **Signatures**:
   - `scripts/perf-frontend-profile.sh --repeats <n> --duration <seconds> --min-samples <count>` runs each repeat in baseline-then-current order.
   - Composite baseline sets `SCOPY_PERF_HISTORY_INDEX`, `SCOPY_PERF_SCROLL_RESOLVER_CACHE`, `SCOPY_PERF_MARKDOWN_RESOLVER_CACHE`, `SCOPY_PERF_PREVIEW_TASK_BUDGET`, and `SCOPY_PERF_SHORT_QUERY_DEBOUNCE` to `0`; current sets them to `1`.
   - `SCOPY_PERF_PASSIVE_ROW` and `SCOPY_PERF_MARKDOWN_MENU_SIGNAL_CACHE` keep their production defaults on both sides unless an axis-specific harness explicitly changes them.
3. **Contracts**:
   - The real-snapshot profile is a composite regression guard, not an old-commit-versus-new-commit comparison and not a single-feature causal A/B.
   - A zero exit status proves complete outputs, expected scenarios, and minimum sample counts. It does not prove every metric improved.
   - Review per-repeat pairs as well as independently aggregated medians. Record mixed-direction results as unresolved variance instead of flattening them into a pass/fail percentage.
   - Causal performance claims require an axis-isolated, equal-work AB/BA harness such as `scripts/perf-warm-scroll-ab.sh`; callback intervals remain callback cadence, not presented FPS.
4. **Validation & error matrix**:

   | Condition | Required result |
   | --- | --- |
   | Missing raw JSON or summary | Invalid evidence; do not cite the run |
   | Scenario/sample-count mismatch | Script fails and no performance conclusion is published |
   | Composite medians improve consistently | May be cited as broad regression evidence, with the five-flag definition |
   | Per-repeat directions disagree or major metrics conflict | Record exact pairs and metrics as unresolved variance; do not label green |
   | Need to prove one optimization | Add or reuse a single-axis AB/BA harness with equal observed work |
   | No compositor-backed presented-frame source | Do not call callback intervals FPS |

5. **Good/base/bad cases**: Good: five fixed AB/BA pairs prove one flag while the full composite run is reported separately with every variance. Base: a complete composite smoke/standard run is retained as a broad guard without a causal claim. Bad: call the composite `baseline` an old release, cite only its median, or treat command success as proof of no regression.
6. **Tests/evidence required**: For release-grade frontend work, retain the raw per-repeat JSON, summary JSON/Markdown, variant order, flag definition, loaded/total counts, scenario completion, and minimum samples. Pair it with axis-isolated AB/BA evidence for each claimed optimization and run `make perf-frontend-profile-full` before release.
7. **Wrong vs correct**: Wrong: “full profile passed because the shell exited 0.” Correct: “the full composite profile completed; exact per-scenario/pair variance is recorded, while the fixed equal-work AB/BA supplies the causal claim.”

---

## Review Checklist

- Does the UI still build against macOS 14 with Swift 5.9?
- Are state mutations on the main actor?
- Are view-owned tasks cancelled?
- Are settings changes applied only through Save unless intentionally immediate?
- Are accessibility identifiers and UI tests updated together?
- Did performance-sensitive changes run the right profile/test gate?
- Are XCTest runtime inputs/outputs bundle- or temporary-backed, with completed evidence copied into the repo only after success?
- Do stable row/menu predicates use bounded revision-keyed caches without conflating heuristic and exact semantics?
