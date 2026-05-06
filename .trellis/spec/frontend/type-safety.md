# Type Safety

> Swift type, Observation, DTO, binding, and availability rules for the UI layer.

---

## Baseline

Use Swift 5.9 and macOS 14.0 as configured in project.yml and Package.swift (project.yml:29-45, Package.swift:1-8). Do not silently raise the language version or deployment target.

If using newer Apple APIs, verify the exact signature in official docs, add if #available, and keep fallback behavior local to the component or adapter (AGENTS.md:5-14).

---

## DTOs And Enums

UI state should use typed DTOs and enums from ScopyKit: ClipboardItemDTO, SearchRequest, SearchMode, SearchSortMode, SearchCoverage, SettingsDTO, SettingsPatch, and related models. Avoid stringly typed state when a domain enum exists.

Settings pages should bind to SettingsDTO through Binding<SettingsDTO> and patch calculation, as SettingsView does (Scopy/Views/Settings/SettingsView.swift:89-153). Search UI should update HistoryViewModel typed fields rather than passing loose dictionaries or string mode names.

---

## Observation And Main Actor

UI-facing view models are @Observable @MainActor (Scopy/Observables/AppState.swift:26-29, Scopy/Observables/HistoryViewModel.swift:6-7, Scopy/Observables/SettingsViewModel.swift:6-7). Keep UI mutation on the main actor. Use @ObservationIgnored for services, tasks, caches, and handlers.

Do not mark backend actors @MainActor to make UI calls easier. Cross the boundary with async functions, DTOs, and explicit MainActor.run only when required by AppKit.

---

## Bindings

Prefer explicit Binding(get:set:) when optional local draft state needs a non-optional binding. SettingsView unwraps tempSettings before building page bindings (Scopy/Views/Settings/SettingsView.swift:33-40, Scopy/Views/Settings/SettingsView.swift:89-153).

Avoid force unwraps in bindings unless there is a nearby guarded invariant.

---

## Common Mistakes

- Do not use Any, [String: Any], or raw strings for UI state unless crossing an existing API boundary such as UserDefaults encoding in SettingsStore.
- Do not convert strongly typed settings/search fields to dictionaries for convenience.
- Do not skip Sendable/actor concerns in code touched by strict concurrency tests.
- Do not introduce untyped notification names or magic environment keys without centralizing or documenting them.
