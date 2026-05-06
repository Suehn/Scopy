# Directory Structure

> Where backend-like Scopy code lives and how to place new files.

---

## Actual Layout

ScopyKit is a SwiftPM target rooted at Scopy/ and excludes the app/UI directories (Package.swift:15-32). The Xcode app target also excludes backend directories and depends on ScopyKit instead (project.yml:52-80). Keep that boundary intact.

Directory map:

- Scopy/Domain/Models: DTOs, requests, responses, enums, and durable data contracts.
- Scopy/Domain/Protocols: service protocols consumed by UI or adapters.
- Scopy/Domain/Utilities: domain-level pure helpers.
- Scopy/Application: actor facade that coordinates monitor, storage, search, and settings.
- Scopy/Infrastructure/Persistence: SQLite connection, repository, migrations, and stored rows.
- Scopy/Infrastructure/Search: search engine and FTS query construction.
- Scopy/Infrastructure/Settings: SettingsStore and persistence adapters.
- Scopy/Services: clipboard monitor, storage service, hotkey, exports, profiling, and supporting services.
- Scopy/Utilities: shared backend utilities, logging, async pools, and file ops.
- Tools/ScopyBench: release benchmark executable.
- ScopyTests: unit, integration, concurrency, and performance tests.

---

## Placement Rules

- Put durable data contracts in Scopy/Domain/Models. Examples include SearchRequest, SearchResultPage, SettingsDTO, and clipboard DTOs.
- Put UI-consumed protocols in Scopy/Domain/Protocols; the UI should depend on protocol-facing services rather than concrete persistence/search classes.
- Put orchestration that combines monitor, storage, search, and settings in Scopy/Application. ClipboardService is the current actor facade and owns the event stream (Scopy/Application/ClipboardService.swift:4-9, Scopy/Application/ClipboardService.swift:25-36).
- Put SQLite table access, SQL, migrations, FTS setup, and repository transactions under Scopy/Infrastructure/Persistence.
- Put ranking, FTS query building, exact/fuzzy/regex mode handling, and search index synchronization under Scopy/Infrastructure/Search.
- Put UserDefaults-backed settings persistence in Scopy/Infrastructure/Settings; SettingsStore is the single settings source of truth (Scopy/Infrastructure/Settings/SettingsStore.swift:4-18).
- Put app-facing but backend-heavy services such as StorageService, ClipboardMonitor, export, pngquant, and profiling under Scopy/Services.

---

## Naming Conventions

Use one primary type per file when practical, and match the file name to the type (AGENTS.md:61-65). Keep Swift access explicit when crossing module boundaries: public APIs in ScopyKit should be intentional, while implementation details stay internal/private.

Avoid creating a new abstraction until the existing layer boundary needs it. Search first for similar helpers, thresholds, DTO fields, and test utilities before adding new ones.

---

## Examples

- Scopy/Application/ClipboardService.swift is the application-layer composition point.
- Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift owns raw SQL operations.
- Scopy/Infrastructure/Persistence/SQLiteMigrations.swift owns schema evolution.
- Scopy/Infrastructure/Search/SearchEngineImpl.swift owns search execution and index updates.
- Scopy/Services/StorageService.swift owns storage paths, cleanup policy, external payload files, and repository coordination.
