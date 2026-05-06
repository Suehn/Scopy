# Component Guidelines

> SwiftUI/AppKit component patterns for Scopy.

---

## Component Structure

Scopy uses SwiftUI for app UI and focused AppKit/WebKit bridges where macOS behavior requires them. Keep view structs small when possible, but do not split stateful interaction flows so aggressively that ownership becomes unclear.

Use Scopy/Design tokens and primitives for repeated styling. Existing primitives include filter button styles, pills, ScopyButton, and ScopyCard (Scopy/Design/ScopyComponents.swift:4-18, Scopy/Design/ScopyComponents.swift:48-117). Colors, spacing, typography, and sizes live in their own design files (Scopy/Design/ScopyColors.swift:5, Scopy/Design/ScopySpacing.swift:5).

---

## History List Components

The history list intentionally uses List with ScrollViewReader for view recycling and large histories, not ScrollView plus LazyVStack (Scopy/Views/HistoryListView.swift:57-60). Preserve this unless a measured profile proves a better path.

History row work is performance-sensitive. Keep expensive preview, markdown, thumbnail, and hover behavior behind existing caches/controllers and profile hooks. The list owns one shared markdown preview controller and enforces one active hover popover at a time (Scopy/Views/HistoryListView.swift:26-42, Scopy/Views/HistoryListView.swift:170-249).

History row presentation and thumbnail lifecycle are separate Modules. Put row-ready text/layout/request data in HistoryItemRowDescriptor under Scopy/Presentation. Keep NSImage state, IconService lookup, SwiftUI .task(id:), and final @State thumbnail commits in the row/thumbnail views. For visible row thumbnails, route shared cache-hit/load-priority/scroll-settle/cancellation sequencing through HistoryRowThumbnailLifecycleScheduler; do not mix preview fallback thumbnails, QuickLook/video sizing, markdown preview routing, or file-existence checks into that row scheduler without a separate decision and tests.

---

## Settings Components

Settings use a transaction model with temporary settings and a baseline. The detail area routes pages through SettingsPage; the bottom action bar owns Reset, Cancel, and Save (Scopy/Views/Settings/SettingsView.swift:89-153, Scopy/Views/Settings/SettingsView.swift:225-263).

Do not convert settings controls to autosave. For visual changes, preserve draft state, dirty calculation, SettingsPatch, Save/Cancel, and hotkey special handling (AGENTS.md:105-107).

---

## Accessibility

Keep accessibility identifiers stable for UI tests. Existing examples:

- History.List for the list (Scopy/Views/HistoryListView.swift:128).
- History.Item.<uuid> for rows (Scopy/Views/HistoryListView.swift:321).
- HistoryItem.ContextMenu.Copy, HistoryItem.ContextMenu.Delete, and related row menu IDs (Scopy/Views/History/HistoryItemView.swift:911-948).
- Settings.SaveButton, Settings.CancelButton, and Settings.ResetButton (Scopy/Views/Settings/SettingsView.swift:235-257).

Changing identifiers requires updating UI tests in the same task.

---

## Common Mistakes

- Do not hard-code colors/spacing if a ScopyColors, ScopySpacing, ScopySize, or typography token exists.
- Do not create a new AppKit bridge when an existing coordinator/controller owns the behavior.
- Do not trigger file IO, search, markdown rendering, or thumbnail generation directly from a body recomputation.
- Do not turn row thumbnail lifecycle helpers into broad asset loaders that own ThumbnailCache, IconService, preview fallback state, or NSImage view state.
- Do not add visible instructional text to explain controls unless product copy already uses that pattern.
