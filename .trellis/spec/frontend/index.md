# Frontend Development Guidelines

> Project-specific rules for Scopy's native macOS UI layer.

---

## Overview

In this Trellis setup, "frontend" means the native macOS app target: ScopyApp, AppDelegate, FloatingPanel, SwiftUI views, AppKit bridges, observable view models, design tokens, presentation caches, UI harnesses, and ScopyUISupport. This is not a web/React frontend.

The app target keeps App/UI/Presentation code and depends on ScopyKit for backend functionality (project.yml:52-80). ScopyUISupport is a separate SwiftPM target for UI support utilities (Package.swift:9-12, Package.swift:34-37).

---

## Pre-Development Checklist

Before changing UI code, read:

| Guide | When to read |
| --- | --- |
| [Directory Structure](./directory-structure.md) | Any view, observable, design, presentation, harness, or support-file placement |
| [Component Guidelines](./component-guidelines.md) | SwiftUI/AppKit components, settings pages, history rows, preview UI |
| [Hook Guidelines](./hook-guidelines.md) | SwiftUI lifecycle callbacks, tasks, AppKit coordinators, event handlers |
| [State Management](./state-management.md) | @Observable, @MainActor, view models, settings transactions, async search/load state |
| [Type Safety](./type-safety.md) | Swift typing, DTOs, availability, Observation, bindings, enum-driven state |
| [Quality Guidelines](./quality-guidelines.md) | UI tests, accessibility identifiers, performance gates, hotkey/settings checks |

If UI changes affect service contracts, storage/search/settings semantics, or performance backend paths, also read ../backend/index.md.

---

## Quality Check

For normal UI changes, run make build and make test-unit. For UI behavior, run focused UI tests when possible. For scroll/render/list/thumbnail/preview performance, run make perf-frontend-profile at minimum and make perf-frontend-profile-standard before commit-level confidence (AGENTS.md:20-24, AGENTS.md:57-59, Makefile:318).

Settings UI must preserve explicit Save/Cancel semantics; visual rearrangements must not become autosave (AGENTS.md:105-107).

---

## Primary References

- Scopy/AppDelegate.swift:31-70 wires launch contexts, windows, app handlers, service startup, hotkeys, and UI test harnesses.
- Scopy/Observables/AppState.swift:26-67 is the main app state container.
- Scopy/Observables/HistoryViewModel.swift:6-17 shows the @Observable @MainActor view-model pattern and timing configuration.
- Scopy/Views/HistoryListView.swift:26-42 coordinates the history list, preview controller, and interaction coordinator.
- Scopy/Views/Settings/SettingsView.swift:89-153 implements the settings transaction shell.
