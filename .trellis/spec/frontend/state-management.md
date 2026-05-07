# State Management

> How UI state, app state, settings state, and async search/list state are managed.

---

## App State

Scopy uses Swift Observation. Main UI state objects are @Observable and @MainActor. AppState is the main composition root, with a singleton compatibility layer, injected service support, SettingsViewModel, HistoryViewModel, startup phase, and handler closures (Scopy/Observables/AppState.swift:26-67, Scopy/Observables/AppState.swift:128-152).

Use @ObservationIgnored for dependencies, tasks, handlers, and caches that should not trigger view invalidation. Existing view models use this for service references and task handles (Scopy/Observables/SettingsViewModel.swift:6-15, Scopy/Observables/HistoryViewModel.swift:160-163).

---

## Service Boundary

UI should talk to backend services through ClipboardServiceProtocol and DTOs. AppState chooses an injected, mock, or real service based on init/environment (Scopy/Observables/AppState.swift:120-152). Do not make views call persistence/search classes directly.

For tests and harnesses, prefer injected services or launch environment flags such as USE_MOCK_SERVICE, SCOPY_SERVICE_DB_PATH, and monitor pasteboard settings (Scopy/Observables/AppState.swift:68-126).

---

## History State

HistoryViewModel owns visible items, pinned/unpinned derivation, filters, search mode, pagination, selection, and performance summaries. Search uses a searchVersion plus cancellation to prevent stale async results from overwriting newer state (Scopy/Observables/HistoryViewModel.swift:40-107, Scopy/Observables/HistoryViewModel.swift:98-163, Scopy/Observables/HistoryViewModel.swift:363-612).

When changing history state:

- Update item arrays and presentation caches together.
- Keep pinned and recent pagination separate: `initialPageSize` applies only to recent unpinned rows, and load-more offsets must use `unpinnedItems.count` rather than total visible items.
- Preserve SelectionSource semantics so keyboard navigation can scroll while mouse/programmatic selection does not (Scopy/Observables/AppState.swift:6-11, Scopy/Views/HistoryListView.swift:146-153).
- Search-field focus should clear visible selection and suppress hover-driven reselection while typing, so text entry does not accidentally act on a stale row.
- Preserve pagination and load-more guards for large histories.

---

## Settings State

Settings use SettingsDTO, SettingsPatch, SettingsViewModel, and SettingsStore. The settings window holds tempSettings and baselineSettings, computes a patch, and only writes on Save (Scopy/Views/Settings/SettingsView.swift:7-13, Scopy/Views/Settings/SettingsView.swift:89-153, Scopy/Views/Settings/SettingsView.swift:179-222).

When adding settings:

- Add the DTO field, patch semantics, store encode/decode, page UI, default value, and tests in one coherent change.
- Keep hotkey handling special: the settings view drops hotkey changes from the normal Save patch and routes hotkey behavior through dedicated handlers (Scopy/Views/Settings/SettingsView.swift:89-93, Scopy/Views/Settings/SettingsView.swift:187-201).

---

## Common Mistakes

- Do not store service objects in observable state without @ObservationIgnored.
- Do not mutate settings immediately from page controls unless the page is explicitly designed for immediate action.
- Do not skip stale-version guards in search/refine/load-more paths.
- Do not make backend actors depend on SwiftUI view state.
