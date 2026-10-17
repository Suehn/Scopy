# History list with explicit row updates

Status: proposal, not scheduled. Evidence: [history-list-depth-baseline-2026-10-18.md](../perf/studies/history-list-depth-baseline-2026-10-18.md).

## Problem

Every change to the history projection costs the main thread time proportional to the loaded rows, not to the
rows that changed. With 3,380 rows loaded (perf-db, Release), one capture costs about 69 ms of main-thread work
inside SwiftUI's transaction flush; with 80 rows it costs a few. The split per capture:

- `OutlineListCoordinator.diffRows` and the view-list walk (`ForEachList.applyNodes`, `ViewListTree.getIDs`):
  about two thirds. SwiftUI rebuilds the identifier list of every row and diffs it against the previous one.
- `HistoryLiveRow.body` for every loaded row: about a fifth. The row wrapper takes a content closure, which SwiftUI
  cannot compare, so each update re-runs every row's body and initializer (`row.init` grows by the loaded row
  count per `list.body`). The wrapped `HistoryItemView` is `.equatable()`, so only its own body is skipped.
- `HistoryListState` and `HistoryViewModel` do not reach a single sample.

The same applies to every upsert, removal and appended chunk once a user has paged deep, and the cost is paid
whether or not the panel is on screen.

## Step 1: comparable row wrappers (inside SwiftUI)

Give `HistoryLiveRow` the inputs its content depends on as values (`item`, the row context, the identity of the
shared Markdown controller) and compare those, ignoring the closure, through `.equatable()`. Unchanged rows then
skip their body and the `HistoryItemView` initializer. Expected: the per-row share above, about a fifth of the
per-capture cost; diffing stays. Risks: a missed input leaves a row stale. Every value the closure reads at build
time must be in the comparison; callbacks that read state when they run are safe.

Evidence: a hosted `HistoryListView` test counting row constructions per update (DEBUG `…ForTesting` counter), and
an interleaved A/B of AX-free `sample` main-thread busy samples and process CPU over the deep capture workload.

## Step 2: an AppKit table fed by the projection's own diff

Replace the SwiftUI `List` with an `NSTableView` (`NSViewRepresentable`) whose updates come from
`HistoryListState`, which already knows each change exactly:

| Projection change | Table update |
| --- | --- |
| `appendRecentPage` / `appendPage` chunk | `insertRows(at: tail range)` |
| `upsertRecentItem` (remove at i, insert at j) | `moveRow(at:to:)` plus `reloadData(forRowIndexes:)`, or remove + insert |
| `removeItem` / `removeItems` | `removeRows(at:)` |
| `setItemIfChanged` | `reloadData(forRowIndexes:columnIndexes:)` |
| `replacePage` / `replaceRecentPage` (new query, clear) | `reloadData()` |

`HistoryListState` would publish a change record (or the view would compare generations and request a typed
diff) instead of only `projectionGeneration`. Rows stay SwiftUI: each reusable cell hosts `HistoryItemView` in an
`NSHostingView`, created through `makeView(withIdentifier:owner:)` and reconfigured on reuse.

Behaviour to preserve, each with its own evidence on the local UI path:

- Row heights and scroll anchoring (the reason for `.id(item.id)` today): `usesAutomaticRowHeights` with hosting
  views, or cached measured heights keyed by row identity; no jump when a page lands or a fast scroll ends.
- Selection, keyboard navigation, `ScrollViewReader`-style programmatic scrolling, quick slots.
- Hover previews, popover anchoring and the pinned-preview hand-off.
- Accessibility (rows exposed only as today), the scroll profiler's `NSScrollView` attachment and live-scroll
  notifications, and the load-more trigger (`rowDidAppear` from `tableView(_:willDisplay…)` or visible-rect
  changes).

Expected: per-update cost proportional to the changed rows. Evidence: the deep capture workload above (AX-free
`sample` and CPU, interleaved A/B with an A/A floor), the wheel scroll profile for parity, and memory readings
(`footprint`, idle and after a deep scroll).

## Alternatives considered

- **Bound the loaded rows** (drop rows far above the viewport and reload them on the way back): keeps SwiftUI but
  changes paging, selection and scroll-position semantics, and still pays O(rows kept) per update.
- **`ScrollView` + `LazyVStack`**: rejected before; it kept every shown row alive (~500 MB for 10k items against
  ~50 MB with `List`).
- **Narrowing `HistoryListState` work** (binary-search insert, partial index updates): measured below sampling
  resolution; it does not touch the cost.
