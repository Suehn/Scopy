---
doc_type: portal
status: active
owner: maintainers
last_reviewed: 2026-09-05
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
- Version: `v0.80.7`
- Date: `2026-09-11`
- Release note: [v0.80.7](./history/v0.80.7.md)
- Changelog: [CHANGELOG.md](./CHANGELOG.md)
- Profile doc: `none`
<!-- release-current:end -->

## Recent Releases

<!-- release-recent:start -->
- `2026-09-11` [v0.80.7](./history/v0.80.7.md) - Restore preview typography and remove the reserved toolbar row
- `2026-09-11` [v0.80.6](./history/v0.80.6.md) - Keep multiple resizable previews with quiet unified controls and responsive reading layout
- `2026-09-11` [v0.80.5](./history/v0.80.5.md) - Discover and cache website icons across Markdown links, citations and source cards
- `2026-09-05` [v0.80.4](./history/v0.80.4.md) - Render original Codex icons and preserve source artwork colors
- `2026-09-05` [v0.80.3](./history/v0.80.3.md) - Preserve Chinese tables and emphasis when capturing ChatGPT copies
- `2026-09-05` [v0.80.2](./history/v0.80.2.md) - Fix Chinese emphasis and single-dollar math while simplifying capture tests
- `2026-09-05` [v0.80.1](./history/v0.80.1.md) - Keep search pagination correctly ranked and apply new rows in small batches
- `2026-09-04` [v0.80.0](./history/v0.80.0.md) - Copy reports whether it reached the pasteboard, copied folders replay as folders, and any hover preview can be pinned into a movable, resizable, always-on-top window
- `2026-09-03` [v0.79.0](./history/v0.79.0.md) - Row construction stops doing render work and search indexes mutate in place: search typing blocks the main thread 31% less with 35% shorter worst stalls, clipboard capture 12% cheaper
- `2026-09-03` [v0.78.2](./history/v0.78.2.md) - Marker-bearing clipboard content remains captured; history pages skip inline payload blobs; search evidence failures stay correctly scoped
- `2026-09-03` [v0.78.1](./history/v0.78.1.md) - Protected pasteboard transactions stay out of history; valid search hits survive unrenderable match evidence
- `2026-09-03` [v0.78.0](./history/v0.78.0.md) - Hover previews at final size, search keeps rows while typing, rich copies stop blocking the main thread, binary index caches, prefetched and chunked page loads
<!-- release-recent:end -->

## Full History

- Current history directory: [history/README.md](./history/README.md)
- Legacy pre-reorg index snapshot: [../archive/release-index-legacy.md](../archive/release-index-legacy.md)
