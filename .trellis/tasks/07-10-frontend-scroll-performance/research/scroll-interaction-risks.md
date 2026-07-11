# Scroll interaction P1 contracts

## Scope and conclusion

This is a read-only audit of the current worktree for PRD requirements 4-6 and the related acceptance criteria. The external machine report is design evidence only; the current repository is authoritative (`prd.md:9-12`, `prd.md:17-22`).

Both P1 risks are present in the current code:

1. A row clears hover at live-scroll start, conditionally removes its hover modifier while scrolling, and does no hover restoration at scroll end. The 250 ms suppression expires only when queried; nothing actively resumes a stationary pointer.
2. The local mouse monitor treats every left mouse-down anywhere in the scroll view as scrollbar interaction, before AppKit dispatches the click. A hover-only button can therefore disappear before its mouse-up/action.

The safe target is one `@MainActor` state machine with at most one active-row slot, one suppressed-hover candidate, one scrollbar pointer session, and one cooldown task. All mutation/release operations must be token-matched.

## Current-state evidence

### Scroll and hover fan-out

- `HistoryListView` owns one `HistoryListInteractionCoordinator` and passes it into every history row (`Scopy/Views/HistoryListView.swift:33-38`, `Scopy/Views/HistoryListView.swift:295-334`).
- Every appearing row registers an observer and every disappearing row cancels it (`Scopy/Views/History/HistoryItemView.swift:631-638`, `Scopy/Views/History/HistoryItemView.swift:783-791`, `Scopy/Views/History/HistoryItemView.swift:1070-1080`).
- The coordinator stores those callbacks in a dictionary and iterates all of them for every boundary event (`Scopy/Views/History/HistoryListInteractionCoordinator.swift:15-35`, `Scopy/Views/History/HistoryListInteractionCoordinator.swift:85-89`). This is O(visible rows), contrary to the PRD's single-slot contract (`prd.md:20-21`, `prd.md:33-36`).
- `HistoryListView` also reads observable `historyViewModel.isScrolling` when building the Recent header (`Scopy/Views/HistoryListView.swift:98-104`) and mutates it at both live-scroll boundaries (`Scopy/Views/HistoryListView.swift:130-139`; `Scopy/Observables/HistoryViewModel.swift:410-420`). That read must not leak into passive row construction in the optimized path.

### P1 #1: stationary hover cannot resume

- The row installs `.onHover` only while its per-row `isScrollInteractionActive` is false (`Scopy/Views/History/HistoryItemView.swift:518-525`).
- On `.scrollStarted`, every row sets that flag, clears hover, cancels hover work, and dismisses preview state (`Scopy/Views/History/HistoryItemView.swift:1082-1089`, `Scopy/Views/History/HistoryItemView.swift:1360-1365`).
- On `.scrollEnded`, the row merely clears the flag and updates relative time (`Scopy/Views/History/HistoryItemView.swift:1087-1089`, `Scopy/Views/History/HistoryItemView.swift:1367-1369`). There is no delayed callback that sets hover or re-enters the normal activation path.
- The coordinator records a wall-clock timestamp and computes a 250 ms suppression window (`Scopy/Views/History/HistoryListInteractionCoordinator.swift:13-28`, `Scopy/Views/History/HistoryListInteractionCoordinator.swift:44-49`). Expiration is passive: no task/event fires when the predicate changes from true to false.
- Normal hover activation includes selection debounce, popover arbitration, and the correct type-specific preview path (`Scopy/Views/History/HistoryItemView.swift:811-859`). Restoration must reuse this path rather than duplicate preview behavior.

Failure trace: pointer enters row A -> live scroll begins -> A is forced to `isHovering = false` and its hover modifier is removed -> live scroll ends -> modifier is rebuilt -> pointer remains stationary -> SwiftUI need not emit a new `hover=true` -> cooldown expires silently -> A remains unhighlighted and its hover-only optimize button remains absent. That button is conditionally present only while hovered/selected (`Scopy/Views/History/HistoryItemView.swift:585-608`).

### P1 #2: ordinary clicks are classified as scrollbar interaction

- `ObserverView` installs one app-local monitor for left mouse-down/up (`Scopy/Views/History/ListLiveScrollObserverView.swift:123-129`).
- On down it converts to scroll-view coordinates, tests the entire `scrollView.bounds`, and calls `beginPointerInteraction()` for any point inside (`Scopy/Views/History/ListLiveScrollObserverView.swift:138-151`). It never examines `verticalScroller` or `horizontalScroller`.
- A pointer-start event is broadcast to every row and runs the same hover/preview teardown as live scroll (`Scopy/Views/History/HistoryListInteractionCoordinator.swift:51-60`; `Scopy/Views/History/HistoryItemView.swift:1082-1093`). Because a local monitor runs before normal dispatch, this teardown can precede a button's mouse-up/action.
- Detach correctly tries to clean up pointer and live-scroll state, but cleanup is unowned/untokenized (`Scopy/Views/History/ListLiveScrollObserverView.swift:87-109`). A stale cleanup can therefore end a newer session after reattachment.

Apple's documented AppKit contracts support precise classification:

- [`NSEvent.addLocalMonitorForEvents(matching:handler:)`](https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents%28matching%3Ahandler%3A%29) observes app events before dispatch, but may not receive events consumed by nested control/menu tracking loops.
- [`NSEvent.locationInWindow`](https://developer.apple.com/documentation/appkit/nsevent/locationinwindow) is in the associated window's base coordinates and is intended to be converted into a view's coordinates.
- [`NSScrollView.verticalScroller`](https://developer.apple.com/documentation/appkit/nsscrollview/verticalscroller) may exist even when not currently displayed; non-nil alone is not a visibility/hit guarantee.
- [`NSScroller.testPart(_:)`](https://developer.apple.com/documentation/appkit/nsscroller/testpart%28_%3A%29) accepts a window-coordinate point and returns the scroller part that a mouse-down would hit; `.noPart` means no actionable scroller part.
- AppKit posts `willStartLiveScroll` / `didEndLiveScroll` for user-initiated live tracking, including scroller tracking ([`NSScrollView`](https://developer.apple.com/documentation/appkit/nsscrollview)).

## Contract A: O(1), token-safe hover restoration

### Owned state

All state stays on `@MainActor` in `HistoryListInteractionCoordinator`:

```text
activeRow:              (rowToken, eventSink)?          // count <= 1
suppressedCandidate:    (rowToken, restoreSink)?        // count <= 1
scrollEpoch:            opaque token?                   // one live scroll
scrollbarPointer:       opaque token?                   // one left-button session
cooldownGeneration:     opaque token
cooldownTask:           Task?                           // count <= 1
lastScrollEndDeadline:  monotonic instant?
```

`rowToken` must be a fresh opaque identity for a particular row instance/content revision, not merely `item.id`. The row owns the revision check; the coordinator only compares opaque tokens. This prevents an old A instance or old same-ID revision from clearing/restoring a new A.

### Transitions and invariants

1. **Claim active row:** a real, unsuppressed hover/interaction installs or replaces the single active slot. `releaseActive(rowToken)` succeeds only on exact token equality. A delayed release from A must not remove B, and an old A token must not remove a later A token.
2. **Begin suppression:** live-scroll start or scrollbar pointer-down cancels any pending cooldown and increments a generation. Only `activeRow` receives the teardown event. Idle rows receive no boundary notification and instantiate no interaction state.
3. **Track hover while suppressed:** keep the lightweight row hover callback installed; do not conditionally add/remove it from a list-wide scroll flag. `hover=true` records/replaces the sole candidate without creating heavyweight row interaction state. `hover=false`, row disappearance, content-revision change, and row reuse clear the candidate only when their token matches.
4. **Preserve the initially stationary row:** when suppression begins, the active row supplies its lightweight restoration candidate before its hover state is cleared. This covers the case where SwiftUI emits no further hover event at all.
5. **End live scroll:** record a monotonic deadline of scroll end + 250 ms and schedule exactly one tokenized task. Ending live scroll does not restore while a scrollbar pointer session is still active.
6. **Restore:** the task may restore only if its generation is current, no suppression reason remains, the same candidate token is still current, and the deadline has elapsed. Consume the candidate atomically before invoking its sink so reentrancy cannot restore twice.
7. **Row-side validation:** the restoration sink must verify that the row is still appeared, its token and content revision are current, its local pointer-inside claim has not been cleared, and no incompatible editor/transfer owns the interaction. It then creates interaction state lazily, sets row hover, and enters the one existing activation path (selection debounce and preview delays remain intact).
8. **Overlapping reasons:** if `didEndLiveScroll` occurs while the scrollbar mouse is still down, restoration waits. When pointer ownership ends, restore immediately if the scroll deadline already passed, otherwise wait only the remaining duration.
9. **Invalidation:** a new scroll, new pointer session, candidate replacement, disappearance, revision change, coordinator detach, or coordinator deinit cancels/invalidates the old task by token. Task cancellation alone is not the correctness guard; token comparison is.
10. **Boundedness:** instrumentation should expose slot counts/generations for tests and the performance harness. The passive path must always report active observers <= 1, candidates <= 1, cooldown tasks <= 1.

Important edge sequences:

- `A true -> scroll -> A false -> B true -> late A false`: B remains the candidate.
- `A(old) true -> A(new) true -> old onDisappear`: new A remains the candidate.
- `scroll end -> 100 ms -> new scroll`: the first task cannot restore anything.
- `scroll end -> candidate disappears -> 250 ms`: no restoration.
- `scroll end -> pointer session still active -> pointer up`: restore at the later of the scroll deadline and pointer-up.
- `popover safe-corridor transfer active`: do not resurrect/reopen via a separate path; defer to the existing transfer arbitration.

## Contract B: actual-scrollbar hit testing and paired mouse ownership

### Hit-test rule

For a `.leftMouseDown`, begin pointer suppression only when all are true:

1. `event.window === observedScrollView.window`.
2. The actual AppKit hit target is the observed scroll view's `verticalScroller` or `horizontalScroller` (or a descendant), not merely a point inside the scroll view/document/clip view.
3. The matched scroller is attached to that window, is not hidden through an ancestor, is visibly hittable (important for faded overlay scrollers), and `testPart(event.locationInWindow) != .noPart`.

Resolve the real window hit target first, then identity-match it to the two scrollers; use `testPart` as the actionable-part check. This handles legacy and overlay styles, scroll insets, flipped coordinates, both axes, and the blank corner without hard-coded edge widths. Merely checking a non-nil scroller is insufficient because Apple documents that a scroller remains accessible while not displayed.

### Pointer-session state machine

```text
idle + ordinary down          -> idle; no coordinator event
idle + vertical/horizontal down -> active(pointerToken, axis)
active(token) + paired up     -> idle; end exactly token
idle + any up                 -> idle; no-op
active(old) + new down        -> end old; classify/start fresh token
active(token) + detach/reattach/window loss -> end exactly token
stale cleanup/up(old)         -> cannot end active(new)
```

The observer stores the token returned by `beginPointerInteraction`; `endPointerInteraction(token:)` succeeds only for the matching active token. A mouse-up ends the stored session even if the cursor has left the scroller, but an up with no scrollbar-originated down is a no-op. Return every monitored event unchanged.

Because Apple warns that a local monitor may miss mouse-up inside nested control tracking, add token-safe fallback cleanup: end on the matching `didEndLiveScroll` when appropriate, reconcile `NSEvent.pressedMouseButtons` after the mouse-down dispatch returns, and always end the owned token on detach/window replacement. These fallbacks must never call an untokenized global `end`.

Ordinary main-row, optimize-button, note/export controls, right-click/context-menu opening, and menu-item clicks must leave pointer suppression untouched. The existing optimize UI test proves only action separation (`ScopyUITests/HistoryItemViewUITests.swift:27-45`); its harness embeds a bare row with a coordinator but no `ListLiveScrollObserverView` (`Scopy/Views/UITesting/HistoryItemHarnessView.swift:48-87`), so it does not cover this P1.

## Required focused tests

### Coordinator unit tests

- Stationary A restores exactly once after 250 ms without any post-scroll `hover=true`.
- No restore before the deadline; use an injected monotonic clock/scheduler rather than a 300 ms wall-clock sleep. The current test only sleeps and rereads the suppression predicate (`ScopyTests/HistoryListInteractionCoordinatorTests.swift:7-31`).
- A/B/late-A-clear and old-A/new-A/old-disappear token races.
- Candidate exit/disappearance/revision invalidation before deadline.
- New scroll invalidates the previous cooldown generation.
- Scroll/pointer overlap restores only after both suppression reasons clear.
- Active-slot replacement and stale observer cancellation cannot remove the current slot.
- Counts never exceed one active slot, one candidate, and one cooldown task.

### AppKit observer tests

Extend the existing `ObserverView` seam (already constructed directly in `ScopyTests/ScrollPerformanceTests.swift:68-174`, `ScopyTests/ScrollPerformanceTests.swift:300-305`) with a testable hit-test/session reducer:

- document/row/button point -> no begin; following mouse-up -> no end;
- visible vertical knob/slot -> one begin and matching end;
- visible horizontal knob/slot -> one begin and matching end;
- hidden/faded overlay scroller, `.noPart`, blank corner, outside window, other window -> no begin;
- drag release outside scroller -> matching end;
- missing monitored mouse-up -> `didEndLiveScroll`/post-dispatch/detach fallback ends once;
- stale end from scroll view A cannot end the session created after reattachment to B.

### UI/instrumentation tests

- In the real list (not the single-row harness), hover an image row, fast-click its hover-only Optimize button, and assert optimize=1/primary selection=0 with no pointer-suppression event.
- Ordinary row click and context-menu action complete without hover teardown.
- Hover a row, live-scroll while keeping the pointer stationary, stop over a row, and assert highlight/Optimize button (and then normal delayed preview) resumes after cooldown without moving the mouse.
- Repeat with a row recycled or same-ID content replaced during scroll; no wrong row may highlight or preview.
- Exercise vertical and horizontal scrollers in an AppKit fixture; assert genuine drag suppression and cleanup.

The current scroll UI coverage only checks that a list survives a swipe and that an open preview eventually dismisses (`ScopyUITests/HistoryListUITests.swift:87-100`, `ScopyUITests/HistoryListUITests.swift:240-301`); it does not prove restoration or scrollbar discrimination.

## Recommended implementation boundary

- `HistoryListInteractionCoordinator.swift`: own tokens, the single active slot/candidate, combined suppression state, and injectable cooldown scheduling.
- `HistoryItemView.swift` (or the new lazy interaction-state adapter): maintain one lightweight per-instance row token, report suppressed enter/exit/disappear, and route a valid restoration through the existing hover activation path. Remove per-row boundary observation from the passive path.
- `ListLiveScrollObserverView.swift`: isolate actual-scroller hit testing and the owned pointer-session reducer from attachment/notification plumbing.
- Tests: keep deterministic state-machine tests separate from AppKit geometry/hit-test tests and real-list UI behavior.

This split keeps AppKit-specific hit testing local, keeps row behavior on the main actor, and satisfies the O(1) ownership requirement without publishing a list-wide scroll flag through idle rows.
