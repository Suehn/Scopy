# Research: paste-focus-panel

- Query: Research code paths for requirement 5, requirement 6, and requirement 7 in task `05-07-clipboard-panel-actions-scroll`: Codex action should copy then paste, panel hidden for more than 3 minutes should clear input on hotkey show, and input focus should clear candidate/list focus.
- Scope: internal
- Date: 2026-05-07

## Findings

### Task and spec context

- Task requirements are defined in [.trellis/tasks/05-07-clipboard-panel-actions-scroll/prd.md](/Users/ziyi/Documents/code/Scopy/.trellis/tasks/05-07-clipboard-panel-actions-scroll/prd.md:1), especially requirements 5-7 at lines 40-42 and acceptance criteria at lines 55-58.
- Frontend guidance points the relevant UI surface to `HistoryViewModel`, `HistoryListView`, and `AppDelegate` ([.trellis/spec/frontend/index.md](/Users/ziyi/Documents/code/Scopy/.trellis/spec/frontend/index.md:24), [.trellis/spec/frontend/index.md](/Users/ziyi/Documents/code/Scopy/.trellis/spec/frontend/index.md:37)).
- Backend guidance confirms normal verification for this task should at least include `make build` and `make test-unit`, with stricter gates only if new concurrency/event-stream behavior is introduced ([.trellis/spec/backend/index.md](/Users/ziyi/Documents/code/Scopy/.trellis/spec/backend/index.md:26)).

### Requirement 5: Codex action currently only copies; paste is not implemented

- The context menu entry is mounted in [Scopy/Views/History/HistoryItemView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemView.swift:627). For image items only, the menu exposes `Paste-optimized for Codex` and invokes `onSelectOptimizedForCodex()` at lines 632-636.
- `HistoryListView` wires that callback to `historyViewModel.selectOptimizedForCodex(item)` in [Scopy/Views/HistoryListView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/HistoryListView.swift:283).
- `HistoryViewModel.selectOptimizedForCodex(_:)` currently performs clipboard copy and then closes the panel; it does not trigger a paste action. See [Scopy/Observables/HistoryViewModel.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Observables/HistoryViewModel.swift:676).
- The service stack below that method is copy-only:
- protocol contract in [Scopy/Domain/Protocols/ClipboardServiceProtocol.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Domain/Protocols/ClipboardServiceProtocol.swift:41)
- app-layer implementation in [Scopy/Application/ClipboardService.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Application/ClipboardService.swift:307)
- adapter forwarder in [Scopy/Services/RealClipboardService.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Services/RealClipboardService.swift:80)
- The clipboard write path for file payloads already exists in [Scopy/Services/ClipboardMonitor.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Services/ClipboardMonitor.swift:594), but no existing synthesized paste path (`NSApp.sendAction`, CGEvent, or similar) was found in the searched UI/app code.
- Conclusion: requirement 5 should be implemented above the service layer, most likely in `HistoryViewModel.selectOptimizedForCodex(_:)` or an app-level helper it can call after copy completes and before/after panel close. The lower clipboard service should remain responsible only for preparing the correct pasteboard payload.

### Requirement 6: no existing hidden-duration tracking for panel reopen reset

- The hotkey path ends in `AppDelegate.togglePanelAtMousePosition()` -> `FloatingPanel.toggle(positionMode:)` in [Scopy/AppDelegate.swift](/Users/ziyi/Documents/code/Scopy/Scopy/AppDelegate.swift:262) and [Scopy/FloatingPanel.swift](/Users/ziyi/Documents/code/Scopy/Scopy/FloatingPanel.swift:54).
- `FloatingPanel` currently tracks only `isPresented`; `open()` and `close()` update visibility/highlight state, but no timestamp is recorded for hide/close events ([Scopy/FloatingPanel.swift](/Users/ziyi/Documents/code/Scopy/Scopy/FloatingPanel.swift:62), [Scopy/FloatingPanel.swift](/Users/ziyi/Documents/code/Scopy/Scopy/FloatingPanel.swift:157)).
- `ContentView` focuses the search field on first appearance and clears `searchQuery` only on `Escape` or explicit clear-button actions, not on panel reopen ([Scopy/Views/ContentView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/ContentView.swift:35), [Scopy/Views/ContentView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/ContentView.swift:100), [Scopy/Views/HeaderView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/HeaderView.swift:38)).
- `HistoryViewModel.loadIfStale(minIntervalSeconds:)` uses a 0.5 second freshness window for data reloads, but this is unrelated to panel hidden time or search reset ([Scopy/Observables/HistoryViewModel.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Observables/HistoryViewModel.swift:397)).
- Conclusion: requirement 6 needs a new visibility-lifecycle hook. The least invasive seam is `AppDelegate` or `FloatingPanel`, because those already own open/close transitions. That hook can decide whether elapsed hidden time exceeds 180 seconds, then clear `historyViewModel.searchQuery` and likely re-focus the input before or immediately after showing the panel.

### Requirement 7: search focus exists, but there is no explicit selection clear on focus gain

- `ContentView` owns `@FocusState private var searchFocused` and passes it both to `HeaderView` and `HistoryListView` ([Scopy/Views/ContentView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/ContentView.swift:9), [Scopy/Views/ContentView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/ContentView.swift:60), [Scopy/Views/ContentView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/ContentView.swift:68)).
- `HeaderView` binds the `TextField` to that focus state, but the only current behavior on query change is `historyViewModel.search()`; there is no `.onChange(of: searchFocused)` or callback to clear list selection ([Scopy/Views/HeaderView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/HeaderView.swift:22)).
- `HistoryListView` receives the same focus binding, but it currently uses selection only through `historyViewModel.selectedID`; there is no code that reacts to `searchFocused == true` by clearing `selectedID` or suppressing keyboard-selected styling ([Scopy/Views/HistoryListView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/HistoryListView.swift:27), [Scopy/Views/HistoryListView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/HistoryListView.swift:279)).
- Keyboard navigation is entirely selection-driven: `downArrow` / `upArrow` call `highlightNext()` / `highlightPrevious()` in [Scopy/Views/ContentView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/ContentView.swift:90), and the view model mutates `selectedID` directly in [Scopy/Observables/HistoryViewModel.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Observables/HistoryViewModel.swift:744).
- Conclusion: requirement 7 should be implemented in the shared focus owner (`ContentView`) or a small focused hook in `HeaderView`, with the actual selection clear landing in `HistoryViewModel.selectedID = nil`. That keeps keyboard navigation intact because arrow keys already repopulate selection when it is nil.

### Nearby load-more behavior that intersects the same task

- `HistoryListView` always renders pinned rows first, unpinned rows second, and the load-more trigger at the end of the list ([Scopy/Views/HistoryListView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/HistoryListView.swift:73), [Scopy/Views/HistoryListView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/HistoryListView.swift:109), [Scopy/Views/HistoryListView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/HistoryListView.swift:115)).
- `HistoryViewModel.load()` currently fetches 50 recent items initially ([Scopy/Observables/HistoryViewModel.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Observables/HistoryViewModel.swift:364)).
- `HistoryViewModel.loadMore()` currently grows filtered pages by 50 and unfiltered recent pages by 100, with hard-coded values at lines 432, 463, and 477 in [Scopy/Observables/HistoryViewModel.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Observables/HistoryViewModel.swift:415).
- Existing tests still encode the old page-size expectations, for example:
- initial load 50 in [ScopyTests/AppStateTests.swift](/Users/ziyi/Documents/code/Scopy/ScopyTests/AppStateTests.swift:43)
- unfiltered load-more appends 100 in [ScopyTests/AppStateTests.swift](/Users/ziyi/Documents/code/Scopy/ScopyTests/AppStateTests.swift:53)
- staged refine paging uses `loadedCount + 50` in [ScopyTests/AppStateTests.swift](/Users/ziyi/Documents/code/Scopy/ScopyTests/AppStateTests.swift:208)
- search state machine expects `limit == 50` for recent-only paging in [ScopyTests/SearchStateMachineTests.swift](/Users/ziyi/Documents/code/Scopy/ScopyTests/SearchStateMachineTests.swift:206) and [ScopyTests/SearchStateMachineTests.swift](/Users/ziyi/Documents/code/Scopy/ScopyTests/SearchStateMachineTests.swift:228)
- This is not the main query for this research file, but these constants are part of the same task and will need coordinated updates if the implementation changes page growth from 100 to 500.

### Tests to update or add

- Update service/UI-flow tests that currently only assert copy semantics for Codex: [ScopyTests/ClipboardServiceCopyToClipboardTests.swift](/Users/ziyi/Documents/code/Scopy/ScopyTests/ClipboardServiceCopyToClipboardTests.swift:334) should stay focused on payload generation, while a new app/view-model level test is needed for `copy then immediate paste` because no existing service test covers synthesized paste behavior.
- Add a panel lifecycle test around the hotkey/show path, likely at an `AppDelegate` seam or a small extracted helper, because current unit tests do not cover panel reopen timing. Acceptance cases: hidden <= 180 seconds preserves query; hidden > 180 seconds clears query.
- Add a focus-state test at the SwiftUI/view-model boundary: when search input gains focus, `selectedID` becomes nil; after that, `highlightNext()` / `highlightPrevious()` should still restore keyboard navigation correctly.
- Update page-size tests if requirement 2 is implemented together with this task: [ScopyTests/AppStateTests.swift](/Users/ziyi/Documents/code/Scopy/ScopyTests/AppStateTests.swift:53), [ScopyTests/AppStateTests.swift](/Users/ziyi/Documents/code/Scopy/ScopyTests/AppStateTests.swift:208), [ScopyTests/SearchStateMachineTests.swift](/Users/ziyi/Documents/code/Scopy/ScopyTests/SearchStateMachineTests.swift:206), [ScopyTests/SearchStateMachineTests.swift](/Users/ziyi/Documents/code/Scopy/ScopyTests/SearchStateMachineTests.swift:228).

## Caveats / Not Found

- No existing synthesized paste implementation was found in the app/UI code searched for `paste:`, `NSApp.sendAction`, or similar. Requirement 5 therefore needs a new integration point rather than a small parameter tweak.
- No existing `panel hidden since` timestamp or reopen callback was found; requirement 6 needs new state, not just wiring an existing method.
- The current `Paste-optimized for Codex` menu item is shown only for `.image` items in [Scopy/Views/History/HistoryItemView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemView.swift:632). If the product intent is broader than image items, the PRD should be clarified before implementation.
