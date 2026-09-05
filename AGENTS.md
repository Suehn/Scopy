# Repository Guidelines

## Working Agreement

- Choose the simplest implementation that fully meets current requirements. Remove obsolete paths instead of adding compatibility layers, speculative abstractions, or temporary replacements. Keep concerns modular and each increment working end to end.
- Use existing dependencies before reimplementing common functionality; verify their capabilities rather than guessing. Prefer maintained libraries when they reduce total complexity.
- Preserve user changes. Inspect the worktree before editing; use an isolated checkout when other work is active. Search with `rg`; avoid destructive Git commands.
- Small tasks need inspection, implementation, and verification. Cross-module or risky tasks need a short plan. Create a proposal only for decisions requiring durable review; no mandatory Trellis task, PRD, journal, or sub-agent ceremony.
- Report actual results and limitations. Compilation, an unstarted test host, archived evidence, and diagnostic simplifications are not proof of runtime behavior or performance gains.

## Sources Of Truth

- Read [release-current.yml](doc/meta/release-current.yml) for canonical document entrypoints, then only the current documents relevant to the task. Historical notes, proposals, and archives are evidence, not active requirements.
- [product-spec.md](doc/current/product-spec.md) owns product behavior; [architecture.md](doc/current/architecture.md) owns module boundaries and data-safety invariants; [development-guide.md](doc/current/development-guide.md) maps changes to runtime entrypoints.
- `project.yml` owns Swift, deployment-target, and Xcode baselines. Do not change them without an explicit requirement. Newer system APIs need availability handling encapsulated at the component boundary.
- Before adding Apple/Swift API calls, verify exact signatures and availability using Cupertino documentation/sample lookup. Compile immediately; the compiler adjudicates discrepancies.
- Ordinary development updates only affected canonical docs. Release metadata, notes, indexes, and changelog change only for a release, a changed release fact, or an explicit request.

## Product Boundaries That Must Survive Refactoring

- Views use state and backend protocols, not direct persistence access. Heavy capture, search, cleanup, and media work remains bounded and off the UI thread.
- Settings use explicit Save/Cancel transactions. Hotkey application goes through `AppDelegate.applyHotKey` for registration and persistence, with `.settingsChanged` reapplication; only `kEventHotKeyPressed` triggers actions, with repeat throttling.
- Before renderer work, read [markdown-chatgpt-wacz-style-contract.md](doc/current/markdown-chatgpt-wacz-style-contract.md). It alone owns syntax, safe HTML, typography, layout, navigation, and rendering evidence requirements.
- Keep one `MarkdownHTMLRenderer -> MarkdownHTMLDocumentBuilder` chain: preview and PNG share the parse result, HTML, base CSS, and local assets. Do not introduce a second parser, selector, or shadow renderer.
- Preserve current-owner/render-ID readiness, logical-viewport layout, local overflow, and atomic renderer/KaTeX asset validation. Archived source/fonts alone do not prove computed styles or visual parity. Correct conflicting active documentation instead of preserving obsolete semantics.

## Validation By Change Scope

| Change | Required evidence |
| --- | --- |
| Documentation/metadata only | Relevant `make docs-validate` / `make release-validate` checks |
| Functional code | `make build` + `make test-unit`; focused tests first are useful, disclose any omitted gates |
| Concurrency, actors, threads | Also `make test-strict`; TSan when warranted |
| Backend search/cleanup performance | `make test-snapshot-perf-release` using a fresh `make snapshot-perf-db` copy; never commit the DB |
| Frontend performance | `make perf-frontend-profile` smoke; standard recommended before commit, full required before release |
| Performance conclusions | `make perf-unified-table`; record environment, scenarios, actual numbers, and causal limits in the runbook or its linked evidence |
| Hotkeys | `/tmp/scopy_hotkey.log` includes `updateHotKey()` and one action per press |
| Renderer | Node `npm test`, `npm run build`, `npm run verify:assets` in `Tools/MarkdownRenderer`; app build, unit, strict, and a real-app PNG visual check; maintain Swift/Node contracts and export fixtures together |
| Build/test/release tooling | `make test-tooling`, plus `make test-release-policy` for release workflows/scripts/targets |

A host that never enters the requested scene is environment-blocked, not passed. Narrow failures before repeating broad suites. Build/test setup may install missing `xcodegen`; check availability and applicable network/installation authorization first.

## Build And Release Entry Points

- `make build` compiles Debug; `make release` compiles Release. `./deploy.sh` builds and launches; `./deploy.sh --no-launch` builds only. Generate the project with `bash scripts/xcodegen-generate-if-needed.sh` when needed.
- Source and tests live in `Scopy/`, `ScopyTests/`, and `ScopyUITests/`; `Package.swift` and `project.yml` define module ownership. Use Swift with four-space indentation, explicit access control, and names matching types.
- Use `ScopyLog` categories and private metadata; never log clipboard bodies, image bytes, notes, or file contents. See the development guide for logging boundaries.
- Commit messages are short imperative summaries. PRs explain behavior, verification, and material limits; include UI evidence for UI changes.
- For an authorized release, follow [release-runbook.md](doc/current/release-runbook.md) or the repository `scopy-release-homebrew` skill. Version authority is an explicit Git tag, never commit count. Do not overwrite published tags/assets. Completion requires matching DMG/checksum, both casks, Homebrew installation, and installed bundle verification.
