# Current History-Row Architecture Audit

## Scope and authority

This audit is read-only and describes the current `/Users/hh/Documents/code/Scopy` worktree, not the different-machine paths or results in the supplied report. The task contract is `.trellis/tasks/07-10-frontend-scroll-performance/prd.md`; the external report is useful design evidence, but its claimed passive-row implementation and metrics are not present evidence for this repository.

Repository baselines remain Swift 5.9, macOS 14.0, and Xcode 16.0 (`project.yml:4-6`, `project.yml:29-43`). The current product contract requires hover preview, note, export, optimization, selection, pin/delete, and explicit Settings Save/Cancel behavior to survive the refactor (`doc/current/product-spec.md:41-47`, `doc/current/product-spec.md:55-71`, `doc/current/product-spec.md:105-125`). The safe-triangle work already in this dirty worktree is also current behavior to preserve (`doc/current/development-guide.md:111-120`).

## Executive finding

The imported architecture has **not** yet been reproduced in the current worktree. The current row is still eager and fan-out based:

1. Every `HistoryItemView` eagerly creates `HistoryItemRowController`, `HistoryItemPreviewCoordinator`, and `HoverPreviewModel` (`Scopy/Views/History/HistoryItemView.swift:36-40`, `Scopy/Views/History/HistoryItemView.swift:85-87`).
2. Every visible row registers an interaction observer on appearance (`Scopy/Views/History/HistoryItemView.swift:631-638`, `Scopy/Views/History/HistoryItemView.swift:1070-1079`).
3. The list coordinator retains all row callbacks and iterates every observer for scroll/pointer events (`Scopy/Views/History/HistoryListInteractionCoordinator.swift:19-36`, `Scopy/Views/History/HistoryListInteractionCoordinator.swift:85-88`).
4. Each observer publishes `isScrollInteractionActive` and executes scroll teardown/update work (`Scopy/Views/History/HistoryItemView.swift:1082-1097`, `Scopy/Views/History/HistoryItemView.swift:1360-1369`).
5. `HistoryListView.body` also reads observable `HistoryViewModel.isScrolling` for the section header, while start/end mutate that value (`Scopy/Views/HistoryListView.swift:98-104`, `Scopy/Observables/HistoryViewModel.swift:88-91`, `Scopy/Observables/HistoryViewModel.swift:410-420`).

The useful foundations that already exist are the recycled `List`, equatable/id-stable rows, one list-level active popover, one shared Markdown WebView controller, presentation caches, cancellable preview tasks, and the new safe-triangle transfer ownership. These should be migrated, not discarded (`Scopy/Views/HistoryListView.swift:33-42`, `Scopy/Views/HistoryListView.swift:57-60`, `Scopy/Views/HistoryListView.swift:293-350`, `Scopy/Views/History/HistoryItemPreviewCoordinator.swift:112-168`).

## Current request and event flow

```text
HistoryListView List / ForEach
  -> historyRow(item) -> HistoryItemView(...).equatable().id(item.id)
  -> row init reads shared presentation cache
  -> row init eagerly creates 3 ObservableObject graphs
  -> onAppear adds one callback to coordinator.observers

ListLiveScrollObserverView
  -> NSScrollView live-scroll notification or any in-scroll-view leftMouseDown
  -> HistoryListInteractionCoordinator.notify(event)
  -> every visible row callback
  -> @Published scroll flag + preview teardown / relative-time update
```

Stable row identity is partially present through `.id(item.id)` and an equality filter (`Scopy/Views/HistoryListView.swift:293-336`, `Scopy/Views/History/HistoryItemView.swift:90-121`). That same stable identity means its `StateObject`s survive a same-ID item replacement, so a separate content revision is mandatory; identity alone is not a safe async boundary.

## Requirement-by-requirement architecture status

| Area | Current state | Evidence and consequence |
| --- | --- | --- |
| Passive idle row | **Missing** | Three heavy objects are eager (`HistoryItemView.swift:36-40`, `HistoryItemView.swift:85-87`). The row also installs three preview popover modifiers, note popover, context-menu action state, and lifecycle hooks on the common path (`HistoryItemView.swift:642-809`). |
| Lazy interaction session | **Missing** | There is no `HistoryItemInteractionState` or optional session. Hover/note/export/optimization state is spread across always-live controllers (`HistoryItemRowController.swift:4-23`, `HistoryItemPreviewCoordinator.swift:4-21`, `HoverPreviewModel.swift:5-21`). |
| Safe release when idle | **Missing** | There is no `canRelease` contract. `onDisappear` performs broad teardown even for an idle row and omits optimization-task/message cancellation (`HistoryItemView.swift:783-791`, `HistoryItemView.swift:1193-1215`). Controllers have task cancellation helpers but no unified session teardown/release invariant (`HistoryItemRowController.swift:26-45`). |
| Stable view identity | **Present, but incomplete for content** | `.id(item.id)` and `Equatable` preserve row identity (`HistoryListView.swift:293-336`). Equality compares `contentHash` but not `plainText`, so empty/same hashes can hide same-ID text replacement (`HistoryItemView.swift:103-120`). |
| Shared content revision | **Missing / correctness risk** | No revision type exists. `HistoryListState` explicitly replaces a DTO in place by ID (`HistoryListState.swift:94-100`, `HistoryListState.swift:114-125`), and `HistoryViewModel` applies same-ID content updates (`HistoryViewModel.swift:246-273`). Persistent row state is not reconciled when this happens. |
| Preview revision safety | **Partial cancellation only** | Preview pipeline calls an `isCurrent` closure (`HistoryHoverPreviewPipeline.swift:258-269`), but row liveness checks only cancellation/suppression/hover/presentation and source equality, not current item revision (`HistoryItemView.swift:337-358`). An old task retained by the stable row session can therefore still apply to the replaced item. |
| Export revision safety | **Missing** | Export snapshots the old item/settings, awaits source load/export, then writes feedback without a state-identity or revision guard (`HistoryItemView.swift:983-1023`). |
| Note revision safety | **Missing** | Note draft lives in the persistent eager controller (`HistoryItemRowController.swift:11-12`, `HistoryItemRowController.swift:66-78`) and has no reconciliation when same-ID content changes. |
| Optimization-owned transition | **Not modeled** | Optimization calls an item-ID action and then updates persistent row feedback (`HistoryItemView.swift:1193-1215`); there is no explicit rule allowing only the revision transition caused by that task while rejecting unrelated replacement. |
| O(1) active observer | **Missing** | Coordinator stores `[UUID: callback]` and broadcasts (`HistoryListInteractionCoordinator.swift:19-36`, `HistoryListInteractionCoordinator.swift:85-88`); each row registers on appearance (`HistoryItemView.swift:1070-1079`). |
| Token-safe observer replacement | **Missing** | Observation tokens safely unregister their own dictionary entry (`HistoryListInteractionObservation.swift:3-18`), but there is no generation/token rule for the required single active slot, so the A -> B -> A delayed-cancel race is not represented or tested. |
| Suppressed-hover candidate and stationary restoration | **Missing; known P1 is live here** | During suppression, `handleHover` clears current hover and returns, discarding `hover=true` (`HistoryItemView.swift:811-818`). Scroll end only updates time (`HistoryItemView.swift:1367-1369`); no candidate/token/cooldown callback can restore a stationary pointer. |
| Scrollbar-only pointer suppression | **Missing; known P1 is live here** | The local monitor treats every left mouse-down inside the scroll view as pointer interaction and ends it on any mouse-up (`ListLiveScrollObserverView.swift:123-155`). It never hit-tests `verticalScroller`/`horizontalScroller` and does not remember whether the corresponding down originated on a scroller. |
| Single active popover / shared WebView | **Present** | List state enforces one active/pending popover and owns one shared Markdown controller (`HistoryListView.swift:33-42`, `HistoryListView.swift:233-290`). Preserve this ownership during lazy-session extraction. |
| Safe-triangle transfer ownership | **Present, currently broadcast-coupled** | Coordinator has one transfer owner (`HistoryListInteractionCoordinator.swift:63-83`) and preview coordinator has token-checked geometry/task teardown (`HistoryItemPreviewCoordinator.swift:69-109`, `HistoryItemPreviewCoordinator.swift:137-168`). This is valuable current work, but transfer-end is still broadcast to every row (`HistoryListInteractionCoordinator.swift:74-88`). |
| Row descriptor/file/Markdown capability cache | **Partial** | `HistoryItemPresentationCache` centrally holds three caches with a nominal 4,096 limit (`HistoryItemPresentationCache.swift:40-45`) and background file-preview prewarm (`HistoryItemPresentationCache.swift:105-135`). |
| Cache invalidation/bounds correctness | **Incomplete** | Cache overflow clears the whole dictionary only after it exceeds the limit (`HistoryItemPresentationCache.swift:202-212`), while the file-preview miss path can insert at the limit (`HistoryItemPresentationCache.swift:73-91`). Empty-hash fallback uses `id + hashValue` in one cache (`HistoryItemPresentationCache.swift:214-219`) but ID alone in display text (`ClipboardItemDisplayText.swift:231-233`) and preview cache keys (`HistoryHoverPreviewPipeline.swift:762-764`), so same-ID replacement semantics disagree across consumers. |
| Relative-time cache | **Missing** | Relative time is row-owned `@Published` state (`HistoryItemRowController.swift:4-14`). Formatting uses a static 30-second `cachedNow`, but the text refreshes only at init, `lastUsedAt` change, or each row's scroll-end callback (`HistoryItemView.swift:1321-1369`). There is no per-item bounded relative-time cache or boundary scheduler. |
| List clock / hidden-panel pause | **Missing** | No list-level clock exists. There is consequently no pause/resume contract for scrolling or hidden panels and no guaranteed refresh at the next semantic relative-time boundary. |
| Structural instrumentation | **Missing** | Current profiler accepts duration metrics only (`ScrollPerformanceProfile.swift:218-243`); it has no counters for session init, observer install, idle reset, cache hit/miss, load-more, or pagination correctness. |
| Fixed warm micro A/B | **Missing / current harness is not equivalent** | Current script compares five feature flags, not `SCOPY_PERF_PASSIVE_ROW` (`scripts/perf-frontend-profile.sh:139-158`), always runs baseline then current (`scripts/perf-frontend-profile.sh:264-273`), and uses the normal scheme whose test action is Debug (`Scopy.xcodeproj/xcshareddata/xcschemes/Scopy.xcscheme:54-59`). The driver is duration-based `Timer` auto-scroll (`ScrollPerformanceProfile.swift:517-554`), not a fixed command count/display-link workload. |
| Metric naming and profiler self-noise | **Incomplete** | The sampler is a `TimelineView(.animation)` callback (`HistoryListView.swift:354-361`), yet output calls it `frame_ms`/drop ratio (`ScrollPerformanceProfile.swift:349-380`). Sample/event buffers use `Array.removeFirst()` at capacity (`ScrollPerformanceProfile.swift:246-279`), adding O(n) measurement work. |

## Existing coverage worth keeping

- Scroll/pointer event state, cooldown, observation cancellation, and transfer ownership have unit coverage (`ScopyTests/HistoryListInteractionCoordinatorTests.swift:7-53`, `ScopyTests/HistoryListInteractionCoordinatorTests.swift:56-104`).
- Preview token invalidation, stale geometry, transfer cancellation/deinit, and owned-task cancellation are covered (`ScopyTests/HistoryItemPreviewCoordinatorTests.swift:7-40`, `ScopyTests/HistoryItemPreviewCoordinatorTests.swift:42-123`, `ScopyTests/HistoryItemPreviewCoordinatorTests.swift:154-177`).
- Current UI tests cover row selection vs optimization, context-menu actions, preview rendering, and safe-triangle travel (`ScopyUITests/HistoryItemViewUITests.swift:27-104`, `ScopyUITests/HistoryItemViewUITests.swift:106-200`).
- The list UI test verifies preview dismissal on scroll, but not stationary-hover restoration or scrollbar-specific mouse routing (`ScopyUITests/HistoryListUITests.swift:235-301`).
- Cache tests currently prove reuse/prewarm and settings separation, not same-ID replacement, eviction bounds, or invalidation generations (`ScopyTests/HistoryItemRowDescriptorTests.swift:177-257`, `ScopyTests/ClipboardItemDisplayTextTests.swift:63-115`).

## Highest-risk gaps

### P0 correctness boundary: stable ID without content revision

This must be solved before making the interaction graph lazy. The current row identity is intentionally stable, while preview/note/export/optimization state is content-sensitive. A single shared revision value must drive:

- row equality for empty/suspect hashes;
- presentation/display/preview cache keys;
- interaction-session reconciliation;
- preview and Markdown task guards;
- note draft ownership;
- export completion guards;
- the explicit exception for an optimization task's own content transition.

The revision fallback must distinguish same ID, same length, different content. Do not reuse Swift `hashValue` as a correctness identity; use one deterministic shared builder or an equality-complete value.

### P1 interaction regressions

1. **Stationary hover:** the current suppression branch loses the only `hover=true`, and no scroll-end path restores it (`HistoryItemView.swift:811-818`, `HistoryItemView.swift:1367-1369`).
2. **Ordinary click classified as scrollbar:** every in-scroll-view left click begins suppression before the row/button action completes (`ListLiveScrollObserverView.swift:138-151`). This can remove the hover-only optimization button between mouse-down and mouse-up (`HistoryItemView.swift:588-608`).

### P1 performance architecture

Eager objects plus per-row observers are exactly the fan-out described by the supplied plan. Moving only caches or formatter calls will not satisfy the acceptance criteria while `HistoryItemView` still owns three eager `StateObject`s and every visible row handles both scroll boundaries.

## Recommended implementation sequence

### 1. Add proof seams before changing behavior

- Extend `ScrollPerformanceProfile` with true integer counters and measurement-phase hit/miss accounting; keep counters distinct from elapsed-time samples.
- Add counters for interaction-session init/release, active-observer install/remove, suppressed-candidate install/restore/clear, idle-row disappear fast path, descriptor/relative-time cache hit/miss, load-more, and backend pagination requests.
- Add a fixed warm text-only harness contract (50 rows, 4,096 chars, two pinned, no thumbnails, no pagination) and raw metadata that proves loaded/total/canLoadMore and intended/observed path.
- Keep the legacy/passive toggle measurement-only and isolate only the row architecture difference; label it micro A/B rather than old-revision comparison.

### 2. Establish one shared content-revision value

- Introduce a small `Hashable`/`Sendable` presentation revision builder used by row equality, `ClipboardItemDisplayText`, `HistoryItemPresentationCache`, preview request/cache keys, and interaction state.
- Reconcile a live session on every item revision change: cancel/invalidate preview, Markdown, export, and note work before it can commit.
- Model optimization ownership explicitly: only the task that initiated optimization may survive/accept its resulting revision transition; unrelated same-ID replacement invalidates it.
- Add focused same-ID tests, including empty hash and equal-length different text.

### 3. Introduce one optional row interaction session

- Replace the three eager row `StateObject`s with `@State private var interactionState: HistoryItemInteractionState?` (or an equivalent single optional Observation session).
- Keep passive rendering limited to descriptor, icon/thumbnail view, relative-time text, selection, and callbacks.
- Route hover activation, note, export, optimization, and presented popovers through one `ensureInteractionState(for:revision:)` seam.
- Give the session explicit ownership of all tasks/tokens and a testable `canRelease` invariant. Release only when hover, popover/transfer, note editor, preview/Markdown, export, optimization, and transient feedback are all idle.
- Preserve the list-level active-popover/shared-WebView ownership and current safe-triangle controller rather than cloning them into the session.

### 4. Replace observer fan-out with tokenized O(1) ownership

- Change coordinator storage from an observer dictionary to one tokenized active-row slot plus one tokenized suppressed-hover candidate.
- Activating A -> B -> A must issue a new generation; cancellation from either old A or B must be unable to clear the current A slot.
- A suppressed `hover=true` should register only the lightweight candidate, not instantiate the heavy interaction session. Matching `hover=false` and `onDisappear` clear only their own token.
- On scroll end, schedule the 250ms cooldown once at coordinator/list scope, then restore the still-current candidate; restoration may then create the session and resume hover/preview. New scroll, pointer suppression, candidate replacement, or disappearance cancels the scheduled restore.
- Remove row-published `isScrollInteractionActive`; idle rows must neither observe scroll state nor rebuild at start/end. Ensure `HistoryListView.body` no longer reads `HistoryViewModel.isScrolling` on the production list path unless the header is isolated from the rows.

### 5. Make pointer suppression scroller-specific

- Extract a pure/testable hit-test that converts the event into each visible/enabled `verticalScroller`/`horizontalScroller` coordinate space and checks its bounds.
- On left mouse-down, begin pointer suppression only for a scroller hit and store a down-generation/boolean owned by that monitor.
- End only the matching scroller-originated down on mouse-up/detach. Ordinary row, button, popover, and context-menu clicks must be transparent to the coordinator.
- Add vertical, horizontal, hidden/overlay scroller, outside-window, ordinary row, optimization-button, and unmatched mouse-up tests.

### 6. Finish bounded presentation and time ownership

- Give each cache explicit capacity behavior (bounded LRU/generational eviction is preferable to whole-cache cliff clearing) and one revision-key policy.
- Add a per-item one-generation relative-time entry keyed by item ID + `lastUsedAt` + current boundary/bucket; prevent historical buckets accumulating.
- Own one list/panel clock. Suspend publication while live scrolling or the panel is hidden, refresh once on scroll end/panel reopen, and schedule the next semantically correct relative-time boundary rather than relying on row reconstruction.
- Make async prewarm commits generation-aware if `clearCaches` is intended to be a strong invalidation boundary.

### 7. Close correctness and measurement gates before further optimization

- Unit: lifecycle/release, revision races, optimization-owned transition, A -> B -> A active-slot race, suppressed-hover token race, scroller hit testing, cache bounds/invalidation, time boundary/pause-resume, and counter correctness.
- UI: stationary pointer hover restoration after scroll, fast optimization-button click, normal row/context-menu clicks, vertical/horizontal scrollbar drags, plus existing preview/note/export/selection/pin/delete behavior.
- Harness: Release configuration, warm top-bottom-top preconditioning, fixed commands/path, AB and BA orderings, equal-work correctness gates, raw outputs, and structural zero-count assertions for passive rows.
- Run repository gates in the PRD order (`make build`, `make test-unit`, strict/TSan, snapshot backend perf, frontend smoke/standard, unified table, docs/release validation).

### 8. Only then select the next frontend bottleneck from evidence

After the reproduced passive architecture passes both correctness and fixed-workload gates, run code-first SwiftUI audit plus current Time Profiler evidence. Rank candidates by paired main-thread sampled weight and verified call counts; do not preselect thumbnail, layout, accessibility, or instrumentation work from intuition. Implement one next bottleneck at a time and rerun both AB and BA with the same correctness gates.

## Files expected to be central in implementation

- `Scopy/Views/History/HistoryItemView.swift`
- new focused `Scopy/Views/History/HistoryItemInteractionState.swift`
- `Scopy/Views/History/HistoryListInteractionCoordinator.swift`
- `Scopy/Views/History/ListLiveScrollObserverView.swift`
- `Scopy/Views/HistoryListView.swift`
- `Scopy/Presentation/ClipboardItemDisplayText.swift`
- `Scopy/Presentation/HistoryItemPresentationCache.swift`
- `Scopy/Presentation/HistoryItemRowDescriptor.swift`
- `Scopy/Views/History/HistoryHoverPreviewPipeline.swift`
- `ScopyUISupport/ScrollPerformanceProfile.swift`
- focused unit/UI tests and `scripts/perf-frontend-profile.sh`

The current safe-triangle files and their tests are overlapping uncommitted user work. Implementation should integrate with them in place and must not reset or replace them wholesale.
