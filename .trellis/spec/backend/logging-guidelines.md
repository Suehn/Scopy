# Logging Guidelines

> Observability rules for backend services, persistence, search, storage, settings, and diagnostics.

---

## Logger Source Of Truth

Use ScopyLog categories instead of ad hoc print statements. The categories are app, monitor, storage, persistence, search, ui, and hotkey (Scopy/Utilities/ScopyLogger.swift:4-14).

Choose the category by subsystem ownership:

- ScopyLog.storage for external files, cleanup, size accounting, and storage stats.
- ScopyLog.persistence for SQLite schema/repository issues.
- ScopyLog.search for search/index failures.
- ScopyLog.monitor for pasteboard monitoring.
- ScopyLog.app for service startup and app-wide lifecycle.
- ScopyLog.hotkey for hotkey registration/activation.

---

## Privacy

Clipboard content, query strings, file paths, bundle IDs, and raw error payloads can be sensitive. Prefer privacy: .private unless the value is operationally safe and intentionally public. Existing settings and storage failures mostly keep error descriptions private (Scopy/Observables/SettingsViewModel.swift:49-75, Scopy/Services/StorageService.swift:422-449).

Do not log raw clipboard text, image bytes, note contents, or file content. For counts, durations, feature flags, and threshold numbers, public privacy is acceptable.

---

## What To Log

Log:

- Startup/service open failures that affect app availability.
- Cleanup start/end summaries and exceptional cleanup failures.
- Search/index failures that can affect correctness.
- Settings save/load failures.
- Hotkey registration and re-application issues.

Avoid noisy per-item logs inside hot loops unless guarded by a profiler or debug flag.

---

## Hotkey Diagnostics

Hotkey behavior has an extra verification path: after hotkey changes, inspect /tmp/scopy_hotkey.log and confirm updateHotKey() appears and a key press triggers once (AGENTS.md:24-25, AGENTS.md:99-103).

---

## Common Mistakes

- Do not use print or NSLog in production paths when a ScopyLog category exists.
- Do not make private values public just to simplify tests.
- Do not add logs that run for every list row, every search candidate, or every clipboard polling tick without sampling/throttling.
