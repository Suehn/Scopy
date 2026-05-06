# Hook Guidelines

> SwiftUI lifecycle callbacks, tasks, handlers, and coordinator rules. This project does not use React hooks.

---

## SwiftUI Lifecycle

Use SwiftUI callbacks narrowly:

- .onAppear should start lightweight setup or launch a cancellable task.
- .onDisappear should cancel view-owned tasks.
- .onChange should react to specific state transitions, not replace view-model logic.

Settings follows this pattern: it loads settings on appear, refreshes stats, and cancels statsTask on disappear (Scopy/Views/Settings/SettingsView.swift:41-53, Scopy/Views/Settings/SettingsView.swift:155-177).

---

## Task Ownership

Long-running async work should be owned by a view model, service, or coordinator, not by repeated body expressions. HistoryViewModel owns search, load-more, refine, and recent-app refresh tasks with cancellation/version guards (Scopy/Observables/HistoryViewModel.swift:160-198, Scopy/Observables/HistoryViewModel.swift:510-612).

When creating a task:

- Store it if it may outlive the immediate action.
- Cancel the previous task when starting a replacement.
- Check Task.isCancelled before applying results.
- Guard against stale search/load versions before mutating visible state.

---

## App And Window Handlers

AppDelegate owns macOS launch contexts, status item, main panel/test windows, service startup, hotkey setup, and local event monitors (Scopy/AppDelegate.swift:31-70). UI state communicates with AppDelegate through handler closures on AppState (Scopy/Observables/AppState.swift:54-64).

Keep window/hotkey handlers explicit. Do not hide lifecycle effects inside arbitrary views.

---

## AppKit And WebKit Bridges

Use coordinator/controller objects for AppKit/WebKit behavior that SwiftUI does not model cleanly. HistoryListView owns MarkdownPreviewWebViewController, HistoryListInteractionCoordinator, and popover coordination state (Scopy/Views/HistoryListView.swift:26-42). Detach shared WebViews before moving them between popovers (Scopy/Views/HistoryListView.swift:170-249).

---

## Common Mistakes

- Do not start a new untracked Task from every render path.
- Do not mutate view-model state from a background actor without returning to @MainActor.
- Do not let SwiftUI popover state drift when sharing one WebView/controller.
- Do not add test-only lifecycle behavior unless it is gated by launch environment or a UITesting harness.
