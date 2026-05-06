# Quality Guidelines

> Backend implementation and verification standards for Scopy.

---

## Required Patterns

- Keep Swift 5.9, macOS 14.0, and Xcode 16.0 baselines from project.yml unless the user explicitly asks to change them (project.yml:29-45).
- Keep backend code inside ScopyKit boundaries. The app target should remain App/UI/Presentation with ScopyKit and ScopyUISupport dependencies (project.yml:52-80).
- Use actors for shared mutable backend state when the existing subsystem does. ClipboardService and SQLiteClipboardRepository are actor-based (Scopy/Application/ClipboardService.swift:4-9, Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:4-17).
- Keep UI/backend contracts protocol-first and DTO-based. UI-facing services should flow through ClipboardServiceProtocol, DTOs, and view models.
- Preserve backpressure and bounded concurrency. Existing code uses AsyncBoundedQueue, AsyncPermitPool, task cancellation, and small concurrency limits in service paths (Scopy/Application/ClipboardService.swift:66-93).

---

## Forbidden Patterns

- Do not add raw SQLite access outside Scopy/Infrastructure/Persistence without a strong reason.
- Do not add direct settings UserDefaults writes outside SettingsStore.
- Do not block the main actor with long-running file, DB, search, thumbnail, or cleanup work.
- Do not change cleanup/search/storage semantics without adding focused tests and, when performance-sensitive, real benchmark evidence.
- Do not introduce new Apple APIs without verifying signatures and wrapping availability/fallbacks (AGENTS.md:5-14).

---

## Testing Requirements

Default gates after backend changes:

1. make build
2. make test-unit

Add gates by risk:

- Actor/concurrency/event-stream changes: make test-strict; consider make test-tsan (AGENTS.md:18-19, Makefile:163, Makefile:186).
- Search, cleanup, storage-size, or large-data performance: make test-snapshot-perf-release; use real snapshot DB flow when requested (AGENTS.md:20-24, AGENTS.md:56-59, Makefile:128, Makefile:295).
- Release/version changes: make release-validate (AGENTS.md:71-80, Makefile:405).

Use existing helper patterns such as TestDataFactory for generated clipboard/search data (ScopyTests/Helpers/TestDataFactory.swift:4-23, ScopyTests/Helpers/TestDataFactory.swift:89-147).

---

## Review Checklist

- Does the change keep DB rows, external files, search indexes, settings state, and UI events consistent?
- Are cancellation and stale async results guarded before mutating state?
- Are logs categorized and privacy-safe?
- Are migrations idempotent and safe for existing user databases?
- Did tests cover the failure mode or boundary touched by the change?
