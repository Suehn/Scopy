# Error Handling

> How backend errors are represented, propagated, logged, and recovered.

---

## Error Types

Use small domain-specific Error or LocalizedError enums near the subsystem that owns the failure. Current examples include ClipboardServiceError.notStarted in the application actor (Scopy/Application/ClipboardService.swift:12-21) and repository errors in the SQLite repository (Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:5-16).

Prefer typed thrown errors over stringly typed return states. Only convert to user-facing text at UI/diagnostic boundaries.

---

## Propagation Rules

- Backend services should throw failures that callers can handle. ClipboardService.start() opens storage/search and cleans up partial startup on failure (Scopy/Application/ClipboardService.swift:123-184).
- UI-facing view models catch recoverable failures, log them, and update user-visible state when appropriate (Scopy/Observables/SettingsViewModel.swift:49-75, Scopy/Observables/HistoryViewModel.swift:363-404).
- Keep cancellation separate from real failures. Long-running tasks should check Task.isCancelled before applying state or logging failure (Scopy/Application/ClipboardService.swift:156-163, Scopy/Observables/HistoryViewModel.swift:430-505).
- Best-effort maintenance may intentionally ignore or downgrade errors only when the user action already succeeded. Document that choice locally, as existing orphan cleanup does during service startup (Scopy/Application/ClipboardService.swift:172-176).

---

## Startup Failures

Startup is explicit state on AppState: idle, starting, running, or startupFailed with diagnostics (Scopy/Observables/AppState.swift:13-24, Scopy/Observables/AppState.swift:156-177). If a backend startup path can fail, preserve diagnostics so the UI can copy them to the pasteboard (Scopy/Observables/AppState.swift:179-184).

Do not crash or silently continue when the database/search service fails to open. Stop partial services and surface startup failure state.

---

## Common Mistakes

- Do not swallow SQLite, search, or storage errors in user-triggered operations unless the operation is explicitly best-effort.
- Do not log private clipboard content, file paths, or query strings at public privacy.
- Do not update HistoryViewModel.items or settings state after a stale/cancelled async search version completes. Use version/cancellation guards like the existing search/load paths (Scopy/Observables/HistoryViewModel.swift:363-404, Scopy/Observables/HistoryViewModel.swift:510-612).
- Do not leave external files written when a DB insert fails; preserve rollback patterns in StorageService.
