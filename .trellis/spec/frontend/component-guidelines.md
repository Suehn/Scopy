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

## Scenario: History Row File Actions

### 1. Scope / Trigger

- Trigger: history row context menus expose cross-layer file-system actions through UI, view model, service protocol, storage, and AppKit sharing.

### 2. Signatures

- `ClipboardServiceProtocol.fileURLs(itemID: UUID) async throws -> [URL]`
- `HistoryViewModel.sendViaAirDrop(_ item: ClipboardItemDTO) async`
- `HistoryViewModel.openContainingFolder(_ item: ClipboardItemDTO) async`
- `HistoryViewModel.selectOptimizedForCodex(_ item: ClipboardItemDTO) async`

### 3. Contracts

- AirDrop visibility: show for every `.image` row and for `.file` rows with resolvable real local files.
- AirDrop resolution: use `fileURLs(itemID:)`; file-backed images/files return validated non-directory source URLs, and inline/stored images may return a temporary PNG prepared only for the explicit share action.
- Open Containing Folder visibility: show only when DTO-visible data points to real local files; do not use service-created temporary PNGs for this action.
- Codex optimized paste: copy through `copyToClipboardOptimizedForCodex(itemID:)`, close the panel, then post `Control+V`.

### 4. Validation & Error Matrix

- Missing AirDrop service -> log and leave history state unchanged.
- Missing real file for Open Containing Folder -> do not show the menu item and do not reveal a temporary directory.
- Image payload without original file URL -> generate a temporary PNG for AirDrop, but keep Open Containing Folder hidden unless a real source file exists.
- Non-file text/RTF/HTML rows -> no AirDrop or Open Containing Folder menu entries.

### 5. Good/Base/Bad Cases

- Good: inline image row shows Send via AirDrop, generates a temporary PNG, and hides Open Containing Folder.
- Base: file row with existing paths shows Send via AirDrop and Open Containing Folder.
- Bad: Open Containing Folder reveals `/tmp/Scopy/AirDrop` for an inline image.

### 6. Tests Required

- Unit: service URL resolution covers file payloads, file-backed images, and inline image temporary PNG generation.
- UI: context menu visibility covers storage-backed image, inline image, file, and text-only scenarios.
- App: Codex paste shortcut constants assert `Control+V`.

### 7. Wrong vs Correct

Wrong: decide AirDrop and Open Containing Folder from one temporary-file resolver in the row view.

Correct: keep AirDrop on the service-backed share resolver, keep Open Containing Folder on real file URLs only, and assert both contracts in focused UI tests.

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
