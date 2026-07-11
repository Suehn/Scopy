# Lazy History-Row Interaction Session Design

## Purpose

This design is the bridge between the already-audited current row and the tokenized coordinator/content-revision foundations. It keeps the idle render path passive while retaining the existing preview, safe-triangle, note, export, optimization, popover, and accessibility behavior.

## Ownership

`HistoryItemView` owns one optional reference in SwiftUI state:

```swift
@State private var interactionState: HistoryItemInteractionState?
```

`HistoryItemInteractionState` is main-actor isolated and owns the existing interaction graph:

- `HistoryItemRowController`
- `HistoryItemPreviewCoordinator`
- `HoverPreviewModel`
- the current `ClipboardItemContentRevision`
- the tokenized active-row observation
- content-bound async tasks and their captured revision/state identity

The controller/model types use Swift Observation so a non-`nil` state is tracked without installing three eager `StateObject`s. The optional state assignment is the only idle-to-active transition. Preview subviews and the UI-test export harness must be migrated consistently from Combine wrappers.

The list continues to own the single active popover and shared Markdown WebView. The interaction session references those capabilities through callbacks; it must not clone or retain a second list-level owner.

## Passive path

An idle row may read only value inputs and shared presentation output:

- item ID/content revision and descriptor;
- cached title/metadata/file capability/relative time;
- selection and pin state;
- static action closures and accessibility identifiers;
- a lightweight suppressed-hover token only while global suppression is active.

It must not create a row controller, preview coordinator, preview model, preview/export task, per-row scroll observer, or relative-time publisher. Context-menu construction may use descriptor values; opening a note/export/optimization action calls `ensureInteractionState` at action time.

## Activation

`ensureInteractionState(for:)` is the sole constructor. It:

1. computes the current deterministic revision;
2. reconciles and returns the existing state when identity/revision are valid;
3. otherwise creates the three interaction components once;
4. records `interaction.session_init` only as a structural counter;
5. installs/replaces the one active-row callback only when the interaction needs scroll-boundary ownership.

Production activation causes are hover restoration/entry, preview, note, PNG export, image optimization, and a presented interaction popover. Ordinary primary selection, pin/delete, and static display do not require a session.

The measurement-only legacy variant may eagerly construct the same session and register its legacy observer on appearance. No product behavior branches are permitted outside the narrow row-ownership adapter.

## Revision reconciliation

Every content-bound async operation captures both:

- the interaction-state object identity; and
- `ClipboardItemContentRevision` at start.

Its completion may mutate UI only when the current optional state is the same object and the captured revision still equals the state's revision.

On a revision change:

- cancel/invalidate preview debounce, image/file/text load, Markdown render, PNG export, export feedback, hover-exit intent, and popover tokens;
- dismiss an old note editor and discard its draft before it can save against new content;
- clear content-derived preview model state;
- preserve selection/pin/list identity because those are item-lifecycle state;
- preserve the image-optimization task only as a pending operation, while rejecting its feedback unless the resulting revision is proven to be that operation's result.

The optimization completion contract should carry or otherwise prove the resulting content hash/revision. Merely allowing the first same-ID transition while a task is active is not sufficient to distinguish an unrelated replacement.

## Suppressed stationary hover

The passive `.onHover` handler remains installed during scrolling.

- `hover=true` while suppressed registers/replaces the coordinator's one lightweight candidate without constructing the interaction state.
- `hover=false`, revision change, or disappearance clears only the row's own candidate token.
- scroll/pointer start converts an already-active hovered row into the candidate before preview teardown.
- after scrolling and pointer suppression are both inactive and the 250 ms generation is current, the candidate callback revalidates appearance, item ID, revision, token, and pointer containment; only then does it call `ensureInteractionState` and resume hover behavior.

No global Boolean is published through rows.

## Release invariant

`releaseInteractionStateIfIdle(expected:)` first checks object identity, then releases only when all of the following are false/empty:

- row hover and optimize-button hover;
- row-to-popover safe-triangle intent/transfer;
- active image/text/file popover and popover hover;
- note editor/draft transaction;
- preview debounce/load/Markdown/exit tasks;
- preview image/text/Markdown/export state;
- PNG export task/feedback timer/message;
- image optimization task/feedback timer/message;
- any other session-owned transient work.

Release cancels the matching active-row token, performs idempotent teardown, records `interaction.session_release`, and sets the optional state to `nil`. A stale task or delayed teardown holding an old state identity cannot release a newer session.

On disappearance, a `nil` state takes a zero-work fast path and records `interaction.idle_disappear_fast_path`. A non-`nil` state is reconciled and released only if the same invariant permits; active work is not silently converted into a completed action.

## List invalidation and time

The parent `HistoryListView.body` must stop reading `HistoryViewModel.isScrolling`. A small section-header subview may observe that property so only the header retains its current collapse guard.

One list-owned `HistoryRelativeTimeClock` publishes a 30-second bucket boundary. It:

- pauses while the coordinator reports live scrolling;
- cancels publication while the hosting window is not visible/occlusion-visible;
- publishes once immediately on scroll end or panel visibility restoration;
- schedules the next aligned bucket boundary instead of drifting from repeated sleeps.

The presentation cache stores at most one relative-time generation per item ID, keyed by last-used date, revision, and current bucket. Rows read the cache result as a value and do not own a formatter or timer.

## Required tests before performance claims

1. Passive construction creates no controller/model/observer and disappearance performs no reset.
2. Every real activation cause creates exactly one session and repeated activation reuses it.
3. Release is blocked independently by each owned task/editor/popover/feedback condition; stale release cannot clear a replacement session.
4. Same-ID empty-hash and equal-length replacements invalidate preview/note/export results.
5. Optimization feedback is accepted only for its proven resulting revision.
6. A -> B -> A active-token cancellation and candidate-token cancellation preserve the newest owner.
7. Stationary hover restores after suppression without another hover event; disappear/revision/new suppression cancels it.
8. Parent list rows do not rebuild on scroll start/end, while the section header retains its interaction guard.
9. Relative-time cache is bounded to one generation per item and the clock pauses/resumes at scroll and window visibility boundaries.
10. Legacy/passive feature switching changes only ownership, and structural counters prove the intended path.
