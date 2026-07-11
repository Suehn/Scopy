# Frontend scroll performance: current harness, gaps, and evidence plan

## Bottom line

The current repository already has a useful real-snapshot frontend profiler, row/presentation metric hooks, backend snapshot gates, a unified report generator, and substantial preview/interaction regression coverage. Those pieces should be reused. They do **not**, however, reproduce the other machine's passive-row result: the current row still eagerly owns three observable interaction objects, every visible row installs a list-interaction observer, live-scroll transitions are broadcast to all such rows, and the list itself reads an observable scroll flag. The two P1 risks described in the external report are also present in current code.

The safest path is therefore not to treat the external numbers as a baseline and not to retrofit the existing real-snapshot script into a causal claim. First harden the measurement contract and add a deterministic Release fixed-workload micro A/B that toggles only the passive-row architecture. Then reconstruct the architecture in independently testable layers, run the repository's real-snapshot smoke/standard gates as regression evidence, and finally use a current Time Profiler/SwiftUI trace to choose the next optimization.

## Authority and inspected state

- Authoritative task: `.trellis/tasks/07-10-frontend-scroll-performance/prd.md`.
- External report: `/Users/hh/.codex/attachments/dd641f0c-7776-4828-bf12-0b322747f99c/pasted-text-1.txt`; it explicitly describes a different-machine tree and calls the current implementation incomplete because two P1 interactions and the final gates were outstanding (`pasted-text-1.txt:1-3`, `pasted-text-1.txt:305-360`).
- Repository baseline is Swift 5.9, macOS 14.0, Xcode project version 16.0; do not change these values (`project.yml:4-6`, `project.yml:29-43`).
- Audit environment on 2026-07-10: Apple M3 Pro, 36 GiB, macOS 15.7.3 (24G419), Xcode 26.1.1 (17B100). Runtime measurements must record these values again rather than inherit them from this research note.
- `HEAD` and `origin/main` both resolve to `db7503a74797`; `HEAD` is tagged `v0.8.8`. The dirty worktree has an uncommitted metadata mirror for `v0.65.0` (`doc/meta/release-current.yml:1-20`). The runbook explains why a pre-tag build still resolves the nearest reachable tag and cannot be cited as target-version evidence (`doc/current/release-runbook.md:35-44`).
- The current repository snapshot is stale relative to the live DB: `perf-db/clipboard.db` was captured at 02:05 with 7,730 items / 97,673,216 bytes; the source DB was modified at 02:56 and has 7,775 items / 97,882,112 bytes. Refresh it immediately before baseline measurement with the existing SQLite online-backup flow (`scripts/snapshot-perf-db.sh:66-95`).
- The task JSONL files currently have no rows with a `file` field; per the TASK_DIR contract, no row was treated as context.

### Dirty-worktree collision map

All of the following are user/parallel-task state and must be preserved; implementation must build on them rather than restore `origin/main`:

1. Hover/safe-triangle product work: modified `HistoryItemView.swift`, `HistoryItemPreviewCoordinator.swift`, `HistoryListInteractionCoordinator.swift`, `HistoryListView.swift`, the history-item harness, corresponding unit/UI tests; untracked `HoverPreviewIntentController.swift`, `HoverPreviewIntentPolicy.swift`, `PopoverWindowObserver.swift`, and `HoverPreviewIntentPolicyTests.swift`.
2. Release/build isolation work: modified `project.yml`, generated `Scopy.xcodeproj/project.pbxproj`, `deploy.sh`, `scripts/build-release.sh`, backend spec index, development guide, runbook, metadata, release index/changelog; untracked `build-release-guidelines.md` and `v0.65.0.md`.
3. Review/task state: modified code-review docs and `.codex/config.toml`; untracked both Trellis task directories plus `.trellis/workspace/--help/`.

The current safe-triangle work is not incidental: the product contract requires bounded directional row-to-popover transfer, stale-token rejection, teardown, and no sampling-frequency SwiftUI invalidation (`doc/current/product-spec.md:55-65`, `doc/current/product-spec.md:117-124`; `doc/current/development-guide.md:111-120`). A lazy interaction session must absorb and preserve that lifecycle rather than replace it with the other machine's older controller shape.

## Current frontend implementation

### What is already sound and reusable

1. **Virtualized list and stable domain identity.** `HistoryListView` uses `List` plus `ScrollViewReader`, and both pinned and unpinned rows use `ForEach` on identifiable DTOs (`Scopy/Views/HistoryListView.swift:57-60`, `Scopy/Views/HistoryListView.swift:71-112`). Each row is also explicitly keyed by `item.id` (`Scopy/Views/HistoryListView.swift:330-336`). Preserve this path; the frontend spec explicitly treats `List` recycling as intentional (`.trellis/spec/frontend/component-guidelines.md:15-22`).
2. **Central presentation seams already exist.** `HistoryItemPresentationCache` owns row descriptors, file preview summaries, Markdown capability, a 4,096-entry ceiling, prewarm, and explicit clearing (`Scopy/Presentation/HistoryItemPresentationCache.swift:5-45`, `Scopy/Presentation/HistoryItemPresentationCache.swift:49-71`, `Scopy/Presentation/HistoryItemPresentationCache.swift:105-165`). `ClipboardItemDisplayText` similarly centralizes title/metadata work, prewarms it off-main, and bounds both dictionaries to 20,000 entries (`Scopy/Presentation/ClipboardItemDisplayText.swift:5-50`, `Scopy/Presentation/ClipboardItemDisplayText.swift:75-138`, `Scopy/Presentation/ClipboardItemDisplayText.swift:148-205`). These are the right extension points for descriptor/content-revision and time-cache work.
3. **Typed preview pipeline and cancellation seams.** The row delegates request planning to `HistoryHoverPreviewPipeline`; current development guidance requires keeping it there (`doc/current/development-guide.md:84-109`, `doc/current/development-guide.md:235-243`). `HistoryItemPreviewCoordinator` already owns preview tokens/tasks and the new safe-triangle controller (`Scopy/Views/History/HistoryItemPreviewCoordinator.swift:4-27`, `Scopy/Views/History/HistoryItemPreviewCoordinator.swift:103-168`).
4. **List-scoped interaction coordinator.** Scroll, pointer suppression, and hover-transfer ownership are already list-local rather than global (`Scopy/Views/History/HistoryListInteractionCoordinator.swift:3-28`, `Scopy/Views/History/HistoryListInteractionCoordinator.swift:63-89`), matching the documented ownership rule (`doc/current/development-guide.md:130-136`). The implementation can be evolved into one active slot without inventing a second coordinator.

### Proven current hot-path problems

1. **Idle rows are not passive.** Every `HistoryItemView` eagerly instantiates `HistoryItemRowController`, `HistoryItemPreviewCoordinator`, and `HoverPreviewModel` as `@StateObject`s (`Scopy/Views/History/HistoryItemView.swift:36-41`); the row controller is created during every row initializer (`Scopy/Views/History/HistoryItemView.swift:43-88`). The controller publishes relative time, optimization, export, note, and per-row scroll state even when none is active (`Scopy/Views/History/HistoryItemRowController.swift:4-20`). This is exactly the fan-out the external design intends to remove.
2. **Scroll coordination is O(visible rows).** Every row registers an observation on appear (`Scopy/Views/History/HistoryItemView.swift:631-638`, `Scopy/Views/History/HistoryItemView.swift:1070-1080`). The coordinator stores a dictionary and synchronously loops over every observer on each event (`Scopy/Views/History/HistoryListInteractionCoordinator.swift:15-20`, `Scopy/Views/History/HistoryListInteractionCoordinator.swift:85-89`). Each row then publishes `isScrollInteractionActive` and performs reset/update work (`Scopy/Views/History/HistoryItemView.swift:1082-1097`, `Scopy/Views/History/HistoryItemView.swift:1360-1369`).
3. **The list also observes scroll state.** `HistoryListView.body` passes `historyViewModel.isScrolling` into the recent header (`Scopy/Views/HistoryListView.swift:98-104`), while scroll callbacks mutate that observable flag (`Scopy/Observables/HistoryViewModel.swift:410-419`). A live-scroll boundary can therefore invalidate both the list and every row observer.
4. **Idle teardown is heavyweight.** `onDisappear` always unregisters the observer, cancels hover/export work, resets preview state, clears the per-row scroll flag, and dismisses note state (`Scopy/Views/History/HistoryItemView.swift:783-791`). There is no `interactionState == nil` fast exit.
5. **Content revision is not an async ownership boundary.** Equatable comparison notices `contentHash`, note, size, and several other fields (`Scopy/Views/History/HistoryItemView.swift:92-120`), and preview requests carry an item ID/hash, but the liveness predicate checks only cancellation/suppression/hover/presentation state (`Scopy/Views/History/HistoryItemView.swift:337-358`; `Scopy/Views/History/HoverPreviewLivenessPolicy.swift:3-38`). Export captures an item/settings snapshot and later applies feedback without checking that the row session still owns the same revision (`Scopy/Views/History/HistoryItemView.swift:983-1023`). Same-ID replacement can therefore leave preview, note, export, or feedback attached to the wrong content.
6. **Relative time remains row-owned.** Each row formats an initial value during init, keeps a published string in its controller, shares only a lock-protected 30-second `Date`, and refreshes on its own scroll-end event (`Scopy/Views/History/HistoryItemView.swift:85-87`, `Scopy/Views/History/HistoryItemView.swift:1319-1369`). There is no list clock, hidden-panel pause, or bounded item/time-bucket cache.

### The two external P1 risks are present now

1. **Stationary-pointer hover is lost.** When suppression is active, `handleHover` clears the current hover and returns without retaining a candidate (`Scopy/Views/History/HistoryItemView.swift:811-831`). The coordinator stores only a cooldown timestamp and has no suppressed-hover token/callback (`Scopy/Views/History/HistoryListInteractionCoordinator.swift:13-28`, `Scopy/Views/History/HistoryListInteractionCoordinator.swift:38-61`). If AppKit/SwiftUI sends no later `hover=true`, nothing restores the row.
2. **Any left click inside the scroll view is treated as scrollbar interaction.** The local monitor converts the event into scroll-view coordinates and begins pointer suppression for any in-bounds mouse down; mouse up unconditionally ends it (`Scopy/Views/History/ListLiveScrollObserverView.swift:123-155`). It does not hit-test `verticalScroller` or `horizontalScroller`, and it does not pair mouse-up with a scroller-origin token. A fast row/button/context-menu click can remove hover-owned UI before the action completes.

## Performance and quality harness inventory

### Makefile gates

| Gate | Current contract | Reuse decision |
| --- | --- | --- |
| `make build` | Debug Xcode build after setup (`Makefile:18-31`) | Required baseline/final compiler gate. |
| `make test-unit` | All `ScopyTests`, excluding integration/performance (`Makefile:73-85`) | Required; add focused lifecycle/revision/cache tests here. |
| `make test-strict` | Same unit surface under complete strict concurrency (`Makefile:185-198`) | Required because tasks/observation/session ownership change. |
| `make test-tsan` | Hosted TSan scheme, with one explicit bad-runtime skip (`Makefile:162-183`) | Required attempt; capture whether it ran or skipped and why. |
| `make snapshot-perf-db` | Online SQLite backup to ignored `perf-db` (`Makefile:296-300`; `scripts/snapshot-perf-db.sh:79-114`) | Refresh before baseline and record DB size/count/hash. |
| `make test-snapshot-perf-release` | Release `ScopyBench` on `cmd`/`cm`, 20 warmups + 30 iterations with explicit p95 thresholds (`Makefile:127-147`) | Backend regression gate, not evidence of scroll improvement. |
| frontend smoke/standard/full | 1 x 3s/50, 1 x 6s/120, 3 x 10s/260 respectively (`Makefile:9-13`, `Makefile:321-334`) | Reuse as realistic regression/follow-on profiling; insufficient causal passive-row A/B as written. |
| `make perf-unified-table` | Requires backend baseline/current dirs and a frontend summary (`Makefile:336-341`) | Reuse after both sides have auditable outputs. |
| docs/release validation | Repository validation scripts (`Makefile:410-417`) | Required after metadata/docs are updated. |

`make setup` can install XcodeGen if absent (`Makefile:18-22`); XcodeGen is currently present, but implementation/check agents should still avoid assuming setup is mutation-free.

### Existing real-snapshot frontend profiler

Useful properties:

- It rejects a missing DB, preserves raw JSON by variant, and produces JSON plus Markdown summaries (`scripts/perf-frontend-profile.sh:10-18`, `scripts/perf-frontend-profile.sh:55-59`, `scripts/perf-frontend-profile.sh:113-120`).
- It quits the app before, between, and after runs and retries one missing output (`scripts/perf-frontend-profile.sh:122-135`, `scripts/perf-frontend-profile.sh:222-261`). This process isolation is a documented requirement (`.trellis/spec/frontend/quality-guidelines.md:42-51`).
- It exercises three real-snapshot scenarios and can opt into Markdown/image preview buckets (`scripts/perf-frontend-profile.sh:23-27`, `scripts/perf-frontend-profile.sh:160-179`). The UI test injects the snapshot path and isolates the pasteboard monitor (`ScopyUITests/HistoryListUITests.swift:303-363`).
- Summary generation retains source-file paths, callback/runloop statistics, per-bucket p95, accessibility information, and long-callback correlation (`scripts/perf-frontend-profile.sh:330-382`, `scripts/perf-frontend-profile.sh:503-612`). It validates scenario/run completeness and optional hover buckets (`scripts/perf-frontend-profile.sh:614-652`).

Why it is not the passive-row causal baseline:

1. **Wrong comparison variable.** Baseline disables five unrelated historical flags and current enables all five (`scripts/perf-frontend-profile.sh:146-158`; `Scopy/Runtime/PerfFeatureFlags.swift:3-22`). There is no `SCOPY_PERF_PASSIVE_ROW` flag, so the script cannot isolate the architecture requested by this task.
2. **Debug test build.** It invokes `xcodebuild test` with the normal Scopy scheme and no configuration override (`scripts/perf-frontend-profile.sh:181-209`); the scheme TestAction is Debug (`Scopy.xcodeproj/xcshareddata/xcschemes/Scopy.xcscheme:54-59`). The external fixed-workload claim was explicitly Release (`pasted-text-1.txt:172-198`).
3. **Order bias.** Every repeat is baseline then current (`scripts/perf-frontend-profile.sh:268-273`); there is no AB/BA alternation or paired-order report.
4. **Duration, not fixed work.** Auto-scroll is a main-run-loop `Timer` with a nominal 36 px step (`ScopyUISupport/ScrollPerformanceProfile.swift:517-555`). Completion is elapsed-duration plus minimum callbacks (`ScopyUISupport/ScrollPerformanceProfile.swift:282-297`), so command count and intended path may differ when the run is busy. The summary has no equal-work gate.
5. **Real data is useful but not controlled.** The UI scenarios use the full current snapshot (`ScopyUITests/HistoryListUITests.swift:193-232`, `ScopyUITests/HistoryListUITests.swift:340-353`); item mix, pagination, thumbnail availability, and DB revision can change. There is no fixed 50-text-row, 0-image, 4,096-character, `loaded == total`, `canLoadMore == false` warm scenario.
6. **No environment/commit/DB manifest in the frontend summary.** The summary records generated time, requested repeats, duration, sample minimum, and hover mode only (`scripts/perf-frontend-profile.sh:494-501`). It does not record OS, hardware, Xcode, git revision/diff state, DB hash/count, display refresh range, or exact variant flags.
7. **Metric semantics are too strong.** `ScrollFrameSamplerView` drives `recordFrameTick` from `TimelineView(.animation)` (`Scopy/Views/HistoryListView.swift:354-365`), but the payload and summary call these `frame_ms` and `drop_ratio` (`ScopyUISupport/ScrollPerformanceProfile.swift:349-371`; `scripts/perf-frontend-profile.sh:531-578`). They are callback intervals, not proof of presented FPS or compositor frames.
8. **Instrumentation perturbs long runs.** The default cap is 2,000 samples (`ScopyUISupport/ScrollPerformanceProfile.swift:20-31`); every saturated array uses `removeFirst()` (`ScopyUISupport/ScrollPerformanceProfile.swift:246-280`), and each metric update copies a dictionary bucket into a local array and assigns it back (`ScopyUISupport/ScrollPerformanceProfile.swift:218-235`). The external report's ring buffer/in-place counter work is absent.
9. **Correctness gates are shallow.** The script checks output counts/scenarios and optional hover buckets, but not fixed command/path parity, row-session/observer/reset structural counts, maximum active slots, cache measurement misses, load-more/backend requests, or callback-window ownership (`scripts/perf-frontend-profile.sh:614-652`).

### Backend and unified evidence

- `scripts/perf-audit.sh` records OS/Xcode/Swift/hardware, runs build/unit and optional strict/TSan gates, emits stable release ScopyBench JSONL, and includes full-index warm-load/RSS (`scripts/perf-audit.sh:135-178`, `scripts/perf-audit.sh:180-239`, `scripts/perf-audit.sh:241-288`). It can produce backend baseline/current directories for the unified table.
- The unified generator understands engine/service p95, optional warm-load/RSS, and all current frontend scenarios (`scripts/perf-unified-table.sh:91-141`, `scripts/perf-unified-table.sh:153-223`). It is reusable, but will need new metric mappings if the fixed-workload summary uses new structural/rate keys.
- Current local snapshot release output is a valid prior backend observation, not a final gate: `cmd p95=0.265 ms`, `cm p95=2.310 ms` (`logs/test-snapshot-perf-release.log:1-2`). It predates this task and must be rerun on the refreshed snapshot.

### Existing tests and coverage gaps

Existing useful regression seams:

- Scroll notification coalescing, detach end, reattachment, presentation prewarm, and long-callback attribution (`ScopyTests/ScrollPerformanceTests.swift:45-174`, `ScopyTests/ScrollPerformanceTests.swift:176-298`).
- Coordinator lifecycle/cooldown, pointer suppression, observation cancellation/deinit, and transfer ownership (`ScopyTests/HistoryListInteractionCoordinatorTests.swift:7-105`).
- Row export/note/task cancellation (`ScopyTests/HistoryItemRowControllerTests.swift:7-83`) and preview token/task/intent teardown (`ScopyTests/HistoryItemPreviewCoordinatorTests.swift:7-168`).
- Row descriptor cache reuse/settings separation (`ScopyTests/HistoryItemRowDescriptorTests.swift:177-262`) and display/prewarm cache behavior (`ScopyTests/ClipboardItemDisplayTextTests.swift:63-110`).
- UI coverage for primary/optimize action separation, export, preview rendering, safe-triangle crossing, outside dismissal, and popover-to-row reuse (`ScopyUITests/HistoryItemViewUITests.swift:27-141`, `ScopyUITests/HistoryItemViewUITests.swift:144-235`).
- A list UI regression confirms an open preview dismisses during scrolling (`ScopyUITests/HistoryListUITests.swift:235-301`).

Missing proof required by the PRD:

1. Idle-row construction and release counts; no test can assert that heavyweight interaction state stays `nil` during warm scroll.
2. Same-ID content-revision replacement for preview, note, export, and optimization-owned revision transitions.
3. Active-slot and suppressed-hover token replacement/race/deinit cases.
4. Stationary-pointer restoration after the 250 ms scroll cooldown without another hover event.
5. Vertical/horizontal scroller hit testing, ordinary row/button/context-menu non-classification, and mouse-down/up pairing.
6. List-wide body/init fan-out at scroll start/end.
7. Cache bound, deterministic fallback revision, explicit invalidation, relative-time boundary behavior, scrolling pause, and hidden-panel pause/resume.
8. Profiler ring-buffer order, async original-endedAt window attribution, counter-vs-timing semantics, fixed command/path equality, AB/BA pairing, and correctness-gate failure cases.

## What from the external report exists here

| External component | Current repository status | Decision |
| --- | --- | --- |
| `List` virtualization and stable ID | Present (`HistoryListView.swift:57-60`, `HistoryListView.swift:92-112`, `HistoryListView.swift:330-336`) | Preserve. |
| Central display/file/row caches and prewarm | Partially present (`HistoryItemPresentationCache.swift:40-71`, `ClipboardItemDisplayText.swift:47-50`, `ClipboardItemDisplayText.swift:89-138`) | Extend; fix revision keys/invalidation and add time cache/metrics. |
| Lazy `HistoryItemInteractionState?` | Missing; three eager `@StateObject`s remain (`HistoryItemView.swift:36-41`) | Implement as the main architecture seam. |
| Content-revision reconciliation | Missing; current liveness is hover-only (`HistoryItemView.swift:337-358`) | Implement before trusting async behavior. |
| One active observer/row slot | Missing; dictionary broadcast remains (`HistoryListInteractionCoordinator.swift:19-35`, `HistoryListInteractionCoordinator.swift:85-89`) | Replace with tokenized O(1) ownership. |
| No list-wide scroll observation | Missing; header reads the observable flag (`HistoryListView.swift:98-104`) | Remove that dependency or feed the header through a non-row-fan-out seam. |
| Tokenized suppressed-hover restoration | Missing | Implement with fake-clock/token unit seams and UI proof. |
| Scroller-only pointer interaction | Missing (`ListLiveScrollObserverView.swift:138-155`) | Implement in the AppKit adapter and unit-test hit testing. |
| Bounded relative-time cache/list clock | Missing; per-row formatter/state remains (`HistoryItemView.swift:1319-1369`) | Centralize with explicit invalidation and visibility/scroll pause. |
| Safe popover intent controller | Present only in this dirty worktree (`HistoryItemPreviewCoordinator.swift:17-27`, `HistoryItemPreviewCoordinator.swift:103-168`) | Integrate into lazy session without regression. |
| Real-snapshot frontend harness | Present (`scripts/perf-frontend-profile.sh:1-59`) | Keep as realistic regression and follow-on hotspot harness. |
| Fixed 50-row Release warm micro A/B | Missing; no warm scheme or fixed scenario exists | Add separately; do not overload the real-snapshot gate. |
| Ring-buffer/counter-hardened profiler | Missing (`ScrollPerformanceProfile.swift:218-280`) | Harden before measuring the architecture. |
| Time Profiler capture/analyzer | Missing (`scripts/perf-warm-scroll-xctrace.sh` and `scripts/analyze-warm-xctrace.py` do not exist) | Add only after deterministic measurement contract works. |
| Auditable AB/BA five-pair outputs | Missing; current script is AB-only (`scripts/perf-frontend-profile.sh:268-273`) | Add paired raw/summary artifacts and order-stratified results. |

The other machine's saved raw artifacts are not in this repository. The historical `v0.8.8` profile names off-machine paths and a different Mac/Xcode environment (`doc/perf/release-profiles/v0.8.8-profile.md:7-25`). Its results can identify prior hypotheses—especially remaining thumbnail work (`doc/perf/release-profiles/v0.8.8-profile.md:49-66`)—but cannot serve as a current baseline.

## Safest implementation and evidence sequence

### Phase 0 — freeze truth before code changes

1. Preserve the current dirty diff; record `HEAD`, tag, `git status --short`, relevant diff stats, and generated-project state in the task evidence directory. Do not reset or regenerate away the safe-triangle/release-build work.
2. Refresh `perf-db/clipboard.db`; record source/snapshot byte size, SQLite item count, schema/user version, and SHA-256. Keep the DB ignored (`.gitignore:29-53`).
3. Capture one environment manifest: UTC/local time, hardware, memory, OS/build, Xcode/build, SDK, screen maximum FPS/refresh range, current tag/HEAD/dirty flag, and version args.
4. Run a pre-change correctness baseline against the **current dirty tree**: `make build`, focused coordinator/row/preview/cache/scroll tests, `make test-unit`, `make test-strict`, and an explicit `make test-tsan` attempt. Do not cite the current unfinished `logs/test-unit.log` as a pass.
5. Run one real-snapshot smoke only as a harness health check; label it "legacy five-flag real-snapshot comparison," not passive-row baseline.

### Phase 1 — measurement contract before product architecture

1. Harden `ScrollPerformanceProfile` with bounded O(1) storage, in-place bucket updates, separate structural counters/gauges from elapsed-time events, preserved original completion timestamps, and explicit measurement phase/window IDs.
2. Rename TimelineView-derived values to callback interval/rate. Do not claim FPS or presented-frame rate. Continue using run-loop busy duration/rate as a main-thread pressure proxy, with that limitation stated.
3. Add a dedicated Release test/profile scheme or an explicit `-configuration Release` path whose test host still receives `--uitesting` and environment flags. The normal scheme's test action is Debug (`Scopy.xcodeproj/xcshareddata/xcschemes/Scopy.xcscheme:54-59`).
4. Add a deterministic warm scenario matching the external contract only where it is defensible on current code: 50 text rows, 0 images, 4,096 characters, first two pinned, thumbnails off, all rows loaded, no load-more, production `FloatingPanel`/material, two full top-bottom-top warmups, then a fixed number of display-synchronized 36 px commands and fixed intended path. Persist observed path and completed command count.
5. Keep the micro A/B switch narrow: `SCOPY_PERF_PASSIVE_ROW=0/1` must change only row interaction ownership. Older performance flags must stay identical across both sides.
6. Alternate five complete pairs across AB and BA order, terminate app/test processes between runs, and fail summary generation if workload, environment, correctness counters, output count, or cache-miss gates disagree.

Apple API check for the proposed driver:

- Official signatures are `NSView.displayLink(target:selector:) -> CADisplayLink` and `NSScreen.displayLink(target:selector:) -> CADisplayLink`. Both installed SDK categories are macOS 14.0. The final deterministic driver uses the window screen because a view-owned link may suspend when UI automation temporarily considers the view hidden/off-display (`.../AppKit.framework/Headers/NSView.h:606-611`, `.../AppKit.framework/Headers/NSScreen.h:127-132`; [NSScreen documentation](https://developer.apple.com/documentation/appkit/nsscreen/displaylink(target:selector:))).
- `NSScreen.maximumFramesPerSecond` is available from macOS 12.0 (`.../AppKit.framework/Headers/NSScreen.h:95-100`; [Apple documentation](https://developer.apple.com/documentation/appkit/nsscreen/maximumframespersecond)).
- The display-link and maximum-refresh APIs are compatible with the repository's macOS 14 baseline, but the compiler remains authoritative and the adapter owns lifecycle/invalidation. No macOS 26-only API is needed.

### Phase 2 — reconstruct in rollback-safe layers

1. **Revision/session contract:** introduce one lazy interaction-session abstraction that owns the existing row/preview/hover model/controller state, safe-triangle controller, tasks, popover tokens, and content revision. Define `canRelease` from owned work, not arbitrary delay. Add revision and release tests before wiring all UI actions.
2. **Passive row:** make idle rendering consume only item/settings/descriptor/selection inputs. Create the session on hover, preview, note, export, optimization, popover, or a keyboard-selected interaction that truly needs it. Ensure context-menu capabilities that are static remain descriptor/cache work, not session creation.
3. **O(1) coordinator:** replace the observer dictionary with tokenized single active interaction ownership plus one suppressed-hover candidate. Stale cancellation, repeated A→B→A activation, disappear, content revision, and coordinator teardown must not clear a newer token.
4. **Hover restoration:** on live-scroll end, schedule the candidate through the existing 250 ms suppression boundary; revalidate row/session/token/revision/pointer containment before restoring. Do not make rows observe a global scroll Boolean.
5. **Scroller hit testing:** have the AppKit observer convert the event into each nonhidden scroller's coordinates and require a hit in `verticalScroller` or `horizontalScroller`; retain a mouse-down generation so only the corresponding mouse-up ends suppression. Ordinary row/button/menu clicks must bypass it.
6. **Time/presentation work:** introduce a list clock that pauses during live scroll and when the panel is hidden, resumes with an immediate correct-boundary refresh, and feeds a bounded relative-time cache keyed by item/revision/time boundary. Make every cache's key, limit, eviction/clear behavior, and content/settings invalidation explicit.
7. Keep the safe-triangle contract, preview/export pipeline ownership, stable accessibility identifiers, all item actions, and Settings Save/Cancel behavior unchanged (`doc/current/product-spec.md:55-72`, `doc/current/product-spec.md:107-125`).

Run focused build/tests after each layer. Do not wait until all ownership changes are combined; lifecycle bugs are easier to localize when revision, active-slot, hover-restoration, and scroller-hit-test changes have separate test sets.

### Phase 3 — causal and realistic validation

1. Focused unit suites: session lifecycle/release, revision races, active/suppressed token races, scroller hit tests, relative-time/cache boundaries, and profiler math/gates.
2. Focused UI suites: existing primary/optimize/export/context-menu/preview/safe-triangle tests plus new stationary-pointer post-scroll restore, normal optimize click during pointer monitoring, and vertical/horizontal scroller drag cases.
3. Repository gates: `make build`, `make test-unit`, `make test-strict`, `make test-tsan`, `make test-snapshot-perf-release` (`CLAUDE.md:19-29`).
4. Deterministic micro A/B: five complete pairs, AB/BA split, fixed command/path equality, all structural/correctness gates, raw JSON retained. Report medians and each pair; do not hide an opposite-order regression in one aggregate.
5. Real-snapshot regression: `make perf-frontend-profile`, then `make perf-frontend-profile-standard`. Use refreshed DB metadata. Run `--include-hover` because the session absorbs preview lifecycles (`doc/current/development-guide.md:195-204`, `doc/current/development-guide.md:235-243`).
6. Time Profiler after the deterministic gate is stable. Align the trace window to explicit measurement timestamps; analyze Scopy/Main Thread/Running and label results as sampled running weight. Keep inclusive categories non-additive. The current toolchain exposes Time Profiler and SwiftUI templates. Apple's recommended feedback loop is measure, identify cause, change, and remeasure; it specifically calls out dependencies and list identity ([Demystify SwiftUI performance](https://developer.apple.com/videos/play/wwdc2023/10160/)).
7. Generate backend baseline/current audit directories and `make perf-unified-table`. For a frontend-only change, backend parity is a regression check; do not imply backend speedup.

### Phase 4 — choose and implement the next bottleneck from current traces

Only after Phase 3 proves the reconstructed architecture should the next optimization be selected. Current code-first candidates are:

- thumbnail queue/decode/main-thread commit buckets already instrumented (`ScopyUISupport/ThumbnailCache.swift:23-46`, `ScopyUISupport/ThumbnailCache.swift:124-147`);
- remaining row body/equality/display-model work (`Scopy/Views/History/HistoryItemView.swift:92-120`, `Scopy/Views/History/HistoryItemView.swift:503-516`);
- accessibility tree/query cost already captured by the real-snapshot summary (`scripts/perf-frontend-profile.sh:349-376`, `scripts/perf-frontend-profile.sh:597-603`);
- unattributed main-thread sampled stacks from current Time Profiler.

The historical v0.8.8 profile points to thumbnail decode/load as a prior remaining cost (`doc/perf/release-profiles/v0.8.8-profile.md:59-66`), but that is a hypothesis only. Select the highest current repeated cost that appears in both AB and BA/current real-snapshot traces, implement one narrow change, and rerun the same capture. If code buckets do not explain hitches, request/retain SwiftUI and Time Profiler evidence rather than guessing.

## Acceptance-evidence map

| Requirement | Minimum authoritative evidence |
| --- | --- |
| Idle row stays passive | Unit construction/release tests plus fixed-workload structural counters showing zero session/controller/model creation on current passive measurement path. |
| No visible-row rebuild fan-out | Start/end-only instrumentation around an otherwise stationary list plus row init/body counts; current side must not scale with visible-row count. |
| One active observer/candidate | Coordinator unit race matrix and runtime max gauges `active_slot_max <= 1`, `suppressed_candidate_max <= 1`. |
| Stationary hover restoration | Fake-clock/token unit tests and an XCUI/Core Graphics test that leaves the pointer still through scroll end + cooldown and observes highlight/preview/button recovery. |
| Scroller-only pointer classification | Pure vertical/horizontal/row/button/outside hit tests plus UI action and real scroller drag tests. |
| Revision safety | Same-ID replacement tests for preview/note/export, stale completion rejection, and the one optimization-owned revision transition exception. |
| Cache correctness | Bound/eviction/clear/settings/content/time-boundary tests and zero descriptor/relative-time measurement misses after warmup. |
| Behavior preservation | Existing history-item/list UI suites covering copy, pin/delete, note, export, optimization, preview, safe corridor, selection, and context menus; targeted Settings Save/Cancel regression if shared state changes. |
| Micro A/B correctness | Raw per-run manifest + fixed command/intended path/observed path + no pagination/load-more + equal dataset/config + both AB/BA directions. |
| Trace-backed follow-on | Before/after Time Profiler/SwiftUI artifacts aligned to the same fixed measurement window and repeated real-snapshot confirmation. |
| Final repository quality | Successful current-tree build/unit/strict/TSan/backend/frontend/unified/docs/release gates with raw logs. |

## Release/documentation obligations

- Completion requires metadata, a version note, release index, changelog, and the release runbook; performance/deployment changes must include environment and actual numbers (`CLAUDE.md:40-49`, `CLAUDE.md:70-90`).
- The runbook requires build/unit, strict/TSan as applicable, snapshot performance, frontend standard/full, and unified comparison (`doc/current/release-runbook.md:66-89`).
- A dedicated performance profile is justified here because the task adds evidence beyond a release note. Link it from `profile_doc` rather than leaving `null`; release-profile rules require comparison and regression detail (`doc/perf/release-profiles/README.md:9-20`; `CLAUDE.md:81-90`).
- Current `v0.65.0` metadata/release docs are uncommitted parallel-task state. Do not overwrite them. After that state is reconciled, use the next valid `v0.65.x` version because Homebrew numeric ordering makes `v0.8.9` invalid (`doc/current/release-runbook.md:40-44`).
- Run `make docs-validate` and `make release-validate` after docs are updated (`Makefile:410-417`). Do not commit, tag, push, publish, or mutate Homebrew without separate user authorization.

## Research conclusion

The external direction is compatible with the current architecture, but only the list/caches/coordinator/profile scaffolding exists. The causal passive-row implementation and its proof machinery are missing, while current safe-triangle work adds a lifecycle contract that the other-machine report did not include. Treat the current dirty tree as the starting truth; make instrumentation honest and deterministic first; implement lazy revision-owned interaction plus O(1) coordination in layers; prove it with fixed Release AB/BA and real-snapshot gates; then let current traces, not the historical report, choose the next optimization.
