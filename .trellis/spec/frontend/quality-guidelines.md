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

---

## Review Checklist

- Does the UI still build against macOS 14 with Swift 5.9?
- Are state mutations on the main actor?
- Are view-owned tasks cancelled?
- Are settings changes applied only through Save unless intentionally immediate?
- Are accessibility identifiers and UI tests updated together?
- Did performance-sensitive changes run the right profile/test gate?
