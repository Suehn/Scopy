# Directory Structure

> How Scopy's native macOS UI code is organized.

---

## Actual Layout

- Scopy/main.swift and Scopy/ScopyApp.swift: app entry.
- Scopy/AppDelegate.swift: macOS lifecycle, menu bar item, windows, hotkeys, and launch contexts.
- Scopy/FloatingPanel.swift: panel window behavior.
- Scopy/Design: colors, typography, spacing, sizes, and reusable UI primitives.
- Scopy/Observables: @Observable @MainActor app and view models.
- Scopy/Presentation: UI-facing formatting and presentation caches.
- Scopy/Views/History: history rows, previews, markdown, hover, thumbnails, and list helpers.
- Scopy/Views/Settings: settings shell and per-page views.
- Scopy/Views/UITesting: harness views for UI tests and export checks.
- ScopyUISupport: IconService, ThumbnailCache, scroll profiler, and WebKit helper.
- ScopyUITests: end-to-end UI tests.

The app target includes UI files and excludes backend directories; backend comes from ScopyKit (project.yml:52-80). ScopyKit excludes UI directories from the library target (Package.swift:15-32).

---

## Placement Rules

- Put global app lifecycle, window creation, hotkey wiring, and UI-test launch-context handling in AppDelegate or focused window coordinators (Scopy/AppDelegate.swift:31-70).
- Put cross-view app state and service-facing UI state in Scopy/Observables.
- Put reusable visual tokens and primitives in Scopy/Design, not duplicated inside feature views.
- Put view-specific rendering and interaction code near the feature under Scopy/Views/History or Scopy/Views/Settings.
- Put pure display formatting and row presentation caches in Scopy/Presentation.
- Put UI-test-only harnesses in Scopy/Views/UITesting and UI-support utilities that compile as a SwiftPM target in ScopyUISupport.

---

## Naming Conventions

Use SwiftUI view names ending in View, coordinators ending in Coordinator, controller-like AppKit/WebKit wrappers ending in Controller, and model/view-model objects ending in Model or ViewModel according to existing usage.

Keep file names matched to their primary type. Avoid generic files like Helpers.swift unless the directory already has that pattern.

---

## Examples

- Scopy/Views/HistoryListView.swift owns list composition, scroll observation, and preview popover coordination.
- Scopy/Views/History/HistoryItemView.swift owns row interaction, context menus, preview triggers, and row-level accessibility identifiers.
- Scopy/Views/Settings/SettingsView.swift owns settings navigation, draft settings, Save/Cancel, and page routing.
- Scopy/Design/ScopyComponents.swift owns reusable buttons/cards/filter chips.
- ScopyUISupport/ScrollPerformanceProfile.swift supports frontend performance profiling.
