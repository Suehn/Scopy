# Database Guidelines

> SQLite, repository, migrations, settings persistence, search indexes, and file-backed storage rules.

---

## Storage Model

Scopy uses SQLite plus external files. Small clipboard content is stored in the database; large payloads use external storage under the app support directory, with metadata and storage_ref kept in SQLite. StorageService owns the threshold and external path setup (Scopy/Services/StorageService.swift:51-55, Scopy/Services/StorageService.swift:87-135).

Do not bypass StorageService or SQLiteClipboardRepository for clipboard item persistence. StorageService coordinates external files, cleanup, cache invalidation, and DB operations; direct file or SQL changes can desynchronize the two stores.

---

## SQLite Access

SQLiteClipboardRepository is an actor and owns repository-level SQL (Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:4-17). SQLiteConnection and SQLiteStatement wrap raw SQLite handles, prepare, bind, finalize, close, and WAL checkpoint behavior (Scopy/Infrastructure/Persistence/SQLiteConnection.swift:4-92, Scopy/Infrastructure/Persistence/SQLiteConnection.swift:98-159).

Required patterns:

- Use prepared statements and typed bind helpers; do not interpolate user/content values into SQL.
- Keep writes inside repository transaction helpers; existing insert/update paths call performWriteTransaction (Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:127-167).
- Keep repository methods actor-isolated. Do not share raw sqlite3 handles across actors or the main actor.
- On open, preserve the current WAL/cache/temp/mmap pragmas and schema verification flow (Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:63-84).

---

## Migrations

Schema changes belong in SQLiteMigrations. Current schema version is tracked by currentUserVersion and PRAGMA user_version (Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:4-39). Migrations must be idempotent and safe for existing user databases.

Required patterns:

- Bump currentUserVersion when schema changes require migration.
- Add columns with addColumnIfNeeded rather than assuming a fresh database (Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:347-362).
- Keep FTS and trigram FTS setup in migrations/search infrastructure, not scattered across repository callers (Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:250-334).
- Preserve metadata counters and triggers when changing item count, size, pin, or external-size semantics (Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:80-215).

---

## Search Indexes

Search behavior is backed by SQLite FTS and repository/search coordination. SearchEngineImpl owns SearchRequest execution and reacts to item updates from the application service (Scopy/Application/ClipboardService.swift:237-249, Scopy/Application/ClipboardService.swift:252-280).

When changing search:

- Keep SearchRequest, SearchMode, SearchSortMode, and SearchCoverage semantics aligned across domain models, search engine, history view model, and tests.
- Update FTS trigger/migration logic when indexed fields change.
- Run search consistency and performance tests; for release-grade backend performance, use make test-snapshot-perf-release.

---

## Deletion And Cleanup

External file deletion is DB-first. Existing delete paths capture/delete DB rows before deleting files and validate storageRef before touching disk (Scopy/Services/StorageService.swift:422-449, Scopy/Services/StorageService.swift:455-486). Preserve this ordering.

Cleanup logic is performance-sensitive and has feature-flagged fast paths. If changing cleanup count, age, size, external size, or image-only behavior, run unit tests plus snapshot performance tests.

---

## Settings Persistence

SettingsStore is the settings source of truth. It is an actor backed by UserDefaults, caches loaded settings, broadcasts an AsyncStream, and clamps decoded values (Scopy/Infrastructure/Settings/SettingsStore.swift:4-18, Scopy/Infrastructure/Settings/SettingsStore.swift:20-56, Scopy/Infrastructure/Settings/SettingsStore.swift:64-120).

Do not add new direct UserDefaults reads/writes for settings in unrelated files. Add fields to SettingsDTO, SettingsDTO+Patch, SettingsPatch, SettingsStore.encode, SettingsStore.decode, settings UI, and tests together.
