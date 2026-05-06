# Backend Development Guidelines

> Project-specific rules for ScopyKit, persistence, search, settings, storage, clipboard monitoring, and backend-facing utilities.

---

## Overview

In this Trellis setup, "backend" means the SwiftPM library target ScopyKit plus backend-like code under Scopy/Domain, Scopy/Application, Scopy/Infrastructure, Scopy/Services, and Scopy/Utilities. This is not a web service. It is a native macOS Swift 5.9 codebase with SQLite, actors, SwiftPM, XcodeGen, and AppKit/SwiftUI boundaries.

Use project.yml as the single source of truth for Swift and deployment baselines: SWIFT_VERSION is 5.9, MACOSX_DEPLOYMENT_TARGET is 14.0, and Xcode is 16.0 (project.yml:29-45). The SwiftPM package exposes ScopyKit, ScopyUISupport, and ScopyBench (Package.swift:4-13).

---

## Pre-Development Checklist

Before changing backend code, read:

| Guide | When to read |
| --- | --- |
| [Directory Structure](./directory-structure.md) | Any backend file placement, module, or target change |
| [Database Guidelines](./database-guidelines.md) | SQLite, repository, migrations, search indexes, settings persistence, cleanup, storage size |
| [Error Handling](./error-handling.md) | New thrown errors, startup failures, recovery paths, async task failures |
| [Logging Guidelines](./logging-guidelines.md) | Any logging, diagnostics, privacy, or hotkey/storage/search observability |
| [Search Guidelines](./search-guidelines.md) | Search planner, path selection, FTS/full-index/short-query fallback behavior, search performance |
| [Quality Guidelines](./quality-guidelines.md) | Always before implementation and before final handoff |

If a backend change affects UI state, user flows, settings pages, previews, or performance presentation, also read ../frontend/index.md.

---

## Quality Check

For normal backend changes, run make build and make test-unit (AGENTS.md:16-26, Makefile:29, Makefile:74). For actor, concurrency, or event-stream changes, also run make test-strict and consider make test-tsan (AGENTS.md:18-19, Makefile:163, Makefile:186). For search, cleanup, storage, or large-list performance, run make test-snapshot-perf-release and capture real numbers when performance claims are made (AGENTS.md:20-24, Makefile:128).

Do not invent Apple or Swift API signatures from memory. For new system APIs, verify official docs and keep if #available fallback paths inside adapters/components (AGENTS.md:5-14).

---

## Primary References

- Package.swift:15-32 defines which Scopy/ paths compile into ScopyKit.
- project.yml:52-80 keeps the app target as App/UI/Presentation while backend code is supplied by ScopyKit.
- Scopy/Application/ClipboardService.swift:4-9 documents the application-layer actor boundary.
- Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:4-84 shows the SQLite actor and open/migration flow.
- Scopy/Utilities/ScopyLogger.swift:4-14 defines logging categories.
