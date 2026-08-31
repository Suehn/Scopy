---
doc_type: portal
status: active
owner: maintainers
last_reviewed: 2026-08-22
canonical: true
---

# Release Docs

This page is the human-facing index for current release state. Automation should read [../meta/release-current.yml](../meta/release-current.yml).

## How To Use This Page

- Treat the current release block as a human mirror of metadata.
- Use the recent release list as the operational window.
- Use [history/README.md](./history/README.md) for immutable release notes beyond the current window.
- Release titles and notes describe behavior at that version; they never override the current Markdown contract in [markdown-chatgpt-wacz-style-contract.md](../current/markdown-chatgpt-wacz-style-contract.md).

## Current Release

<!-- release-current:start -->
- Version: `v0.72.2`
- Date: `2026-08-31`
- Release note: [v0.72.2](./history/v0.72.2.md)
- Changelog: [CHANGELOG.md](./CHANGELOG.md)
- Profile doc: [v0.72.2 performance profile](../perf/release-profiles/v0.72.2-profile.md)
<!-- release-current:end -->

## Recent Releases

<!-- release-recent:start -->
- `2026-08-31` [v0.72.2](./history/v0.72.2.md) - Architecture, correctness, safety, and performance hardening without UX changes
- `2026-08-29` [v0.72.1](./history/v0.72.1.md) - Link enrichment re-render fixes, official news-card presentation, and precise promotion gates
- `2026-08-29` [v0.72.0](./history/v0.72.0.md) - All rich surface types, opt-in link enrichment, and Sparkle auto-update
- `2026-08-29` [v0.71.0](./history/v0.71.0.md) - Renderer hardening gate and desktop-wide rich fidelity
- `2026-08-28` [v0.70.0](./history/v0.70.0.md) - Interactive ChatGPT-style rich surfaces and stable Markdown preview lifecycle
- `2026-08-28` [v0.65.4](./history/v0.65.4.md) - ChatGPT-aligned Markdown preview and PNG export rendering
- `2026-08-22` [v0.65.3](./history/v0.65.3.md) - Restart-surviving search index caches, typing-safe warm-up, and index-only corpus metrics
- `2026-08-09` [v0.65.2](./history/v0.65.2.md) - Explain every search result with source-aware highlighted match evidence
- `2026-07-11` [v0.65.1](./history/v0.65.1.md) - Unify GitHub and local tagged packaging on the DerivedData-aware release script
- `2026-07-11` [v0.65.0](./history/v0.65.0.md) - Crash-consistent clipboard ingest, race-safe cleanup, passive-row performance, lossless storage accounting, and explicit release tag authority
- `2026-06-15` [v0.8.8](./history/v0.8.8.md) - Scroll row cache and lazy Markdown export checks
- `2026-06-07` [v0.8.7](./history/v0.8.7.md) - WACZ root Markdown table parity
<!-- release-recent:end -->

## Full History

- Current history directory: [history/README.md](./history/README.md)
- Legacy pre-reorg index snapshot: [../archive/release-index-legacy.md](../archive/release-index-legacy.md)
