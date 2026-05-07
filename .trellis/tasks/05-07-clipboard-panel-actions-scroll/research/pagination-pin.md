# Research: pagination-pin

- Query: Investigate the pinned-heavy load-more bug and the required scroll-more increment change from 100 to 500 for task 05-07-clipboard-panel-actions-scroll.
- Scope: internal
- Date: 2026-05-07

## Findings

### Relevant files found

- `Scopy/Observables/HistoryViewModel.swift`: owns initial load, search paging, unfiltered paging, selection actions, and keyboard navigation.
- `Scopy/Observables/HistoryListState.swift`: derives `pinnedItems`/`unpinnedItems`, tracks `loadedCount`, `totalCount`, and `canLoadMore`.
- `Scopy/Views/HistoryListView.swift`: renders pinned + recent sections and places the `LoadMoreTriggerView` at the end of the list.
- `Scopy/Views/History/HistoryItemView.swift`: owns the item context menu, including the existing Codex-optimized action and file-note actions.
- `Scopy/FloatingPanel.swift`: panel show/hide lifecycle, currently with no reopen-age bookkeeping.
- `Scopy/Views/ContentView.swift` and `Scopy/Views/HeaderView.swift`: search-field focus wiring and current keyboard handling.
- `Scopy/Application/ClipboardService.swift` and `Scopy/Domain/Protocols/ClipboardServiceProtocol.swift`: clipboard copy entry points; current Codex path is copy-only.
- `ScopyTests/AppStateTests.swift`: existing paging assertions encode the current 50 + 100 behavior and staged-search paging behavior.
- `ScopyTests/HistoryListStateTests.swift`: verifies pinned/unpinned derived state but not pinned-heavy paging.
- `Scopy/Services/MockClipboardService.swift`: test double for offset/limit behavior.

### Code patterns and concrete evidence

- Initial unfiltered load fetches 50 items:
  - `Scopy/Observables/HistoryViewModel.swift:364`
- Unfiltered load-more appends 100 more items and uses `offset: loadedCount`:
  - `Scopy/Observables/HistoryViewModel.swift:477-480`
- Filtered/search load-more appends 50 items and also uses `offset: loadedCount`:
  - `Scopy/Observables/HistoryViewModel.swift:456-474`
- Staged fuzzy refine on load-more uses `expectedLimit = loadedCount + 50` and restarts from offset 0:
  - `Scopy/Observables/HistoryViewModel.swift:428-453`
- `loadedCount` is the total visible in-memory item count, not just unpinned/recent count:
  - `Scopy/Observables/HistoryListState.swift:27-31`
  - `Scopy/Observables/HistoryListState.swift:39-44`
  - `Scopy/Observables/HistoryListState.swift:137-144`
- The list UI renders pinned and unpinned in separate sections, but the load-more trigger is only after the unpinned section:
  - `Scopy/Views/HistoryListView.swift:73-123`
- Current context menu has:
  - `Copy`
  - image-only `Paste-optimized for Codex`
  - file-note actions for file items
  - no AirDrop / reveal-in-Finder action
  - evidence: `Scopy/Views/History/HistoryItemView.swift:627-667`
- Current Codex-optimized action only copies and closes panel; it does not perform a paste action into the target app:
  - `Scopy/Observables/HistoryViewModel.swift:676-683`
  - `Scopy/Application/ClipboardService.swift:303-309`
  - protocol contract also describes only copy semantics: `Scopy/Domain/Protocols/ClipboardServiceProtocol.swift:41-46`
- Search field focus is currently a standalone `@FocusState` boolean owned by `ContentView`, passed to header/list, but there is no logic that clears list selection when the input regains focus:
  - `Scopy/Views/ContentView.swift:9`
  - `Scopy/Views/ContentView.swift:60-71`
  - `Scopy/Views/HeaderView.swift:22-31`
  - `Scopy/Views/HistoryListView.swift:27`
- Panel close/open lifecycle currently only flips `isPresented`; there is no `lastClosedAt` or reopen-age tracking that could support the 3-minute stale-search reset:
  - `Scopy/FloatingPanel.swift:54-80`
  - `Scopy/FloatingPanel.swift:157-165`

### Likely root cause for requirement 1

The pinned-heavy bug is most likely an offset-accounting mismatch.

Evidence chain:
- The UI splits the combined loaded page into `pinnedItems` and `unpinnedItems` after fetch, but paging offset is still computed from total `loadedCount` (`HistoryViewModel.swift:477`, `HistoryListState.swift:39-44`).
- The load-more trigger is visually anchored after only the unpinned/recent section (`HistoryListView.swift:114-123`).
- If backend recent/history fetch or search result composition includes pinned items in early pages while the UI permanently hoists them into the pinned section, a large pinned population can consume page slots without increasing the visible recent tail enough. Subsequent `offset: loadedCount` can then skip over unpinned items that were never shown in the recent section, or produce an apparently empty/ineffective load-more even while more unpinned items still exist.

This is consistent with the user symptom “pin 太多的时候，会导致没法加载 scroll more”.

### Increment constants that must move together for requirement 2

Current hard-coded page sizes are inconsistent across paths:

- Initial load: 50
- Unfiltered load-more: 100
- Filtered load-more: 50
- Staged-refine load-more expansion: `loadedCount + 50`

If the requirement is “每次 scroll more 从多加载 100 变成多加载 500”, then at minimum these call sites need review:

- `HistoryViewModel.loadMore()` unfiltered branch: `fetchRecent(limit: 100, offset: loadedCount)` at `HistoryViewModel.swift:477`
- Search paging branch: `SearchRequest(limit: 50, offset: loadedCount)` at `HistoryViewModel.swift:456-465`
- Staged-refine branch: `expectedLimit = loadedCount + 50` at `HistoryViewModel.swift:432`

If only the unfiltered path changes to 500 while the filtered paths stay at 50, the behavior will become inconsistent and likely surprise users.

### Tests to update or add

Update existing tests:
- `ScopyTests/AppStateTests.swift:53-63`
  - currently asserts load-more appends 100 and `loadedCount == 150`; this will need to become 500-based or whatever the final contract is.
- `ScopyTests/AppStateTests.swift:225-232`
  - staged-refine paging currently expects `loadedCount + 50`; if filtered load-more also changes, this expectation must change too.

Add new tests:
- A pinned-heavy paging regression test in `ScopyTests/AppStateTests.swift` or a dedicated history-view-model test:
  - seed many pinned items plus additional unpinned items,
  - assert `loadMore()` still increases visible recent/unpinned items and does not skip remaining unpinned records.
- A lower-level list-state or mock-service-backed test that proves offset calculation is based on the correct count once pinned items are separated.
- A focus-behavior test for “search field focus clears list selection” if the implementation is placed in `ContentView`/`HistoryListView`.
- A reopen-after-3-minutes test around panel/search reset, likely easier at coordinator/view-model level than raw NSPanel level.
- Context-menu action presence tests for file items if there are existing SwiftUI harness tests for `HistoryItemView`; otherwise add view-level assertions around accessibility identifiers.

### Implementation implications beyond requirements 1 and 2

These showed up during the same research pass because they share the same affected surfaces:

- Requirement 3/4 will land in `HistoryItemView.swift` context menu. File-item guards already exist there, so AirDrop / reveal-in-Finder should slot into the `item.type == .file` branch.
- Requirement 5 needs a new “copy then paste” path above the service layer; current service/protocol abstraction stops at populating NSPasteboard and does not synthesize a paste keystroke.
- Requirement 6 needs explicit panel-visibility timestamp tracking; no existing state object currently records close time.
- Requirement 7 likely belongs in the `searchFocused` change path in `ContentView` or `HistoryListView`, because current keyboard navigation depends on `selectedID` and that state is not automatically cleared.

## Caveats / Not Found

- I did not find an existing dedicated panel visibility coordinator; the relevant lifecycle is in `Scopy/FloatingPanel.swift`.
- I did not find existing file-item context actions for AirDrop or reveal-in-Finder; those would be net-new UI actions.
- I did not find a current direct paste-synthesis service or helper in the scanned files; implementation will likely need a new AppKit event path or an existing utility discovered during implementation.
- The precise paging root cause depends on how backend `fetchRecent` / search results interleave pinned items, but the frontend offset mismatch is already a high-confidence risk and matches the user-reported symptom.
