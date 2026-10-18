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
- Version: `v0.84.0`
- Date: `2026-10-18`
- Release note: [v0.84.0](./history/v0.84.0.md)
- Changelog: [CHANGELOG.md](./CHANGELOG.md)
- Profile doc: `none`
<!-- release-current:end -->

## Recent Releases

<!-- release-recent:start -->
- `2026-10-18` [v0.84.0](./history/v0.84.0.md) - Rank and highlight fuzzy matches by their contiguous phrase, and score fuzzy subsequence queries up to 2x faster
- `2026-10-18` [v0.83.0](./history/v0.83.0.md) - Search short queries up to 8x faster, rebuild only changed history rows, keep deep search pages through new copies, and start over after a stale reopen
- `2026-10-18` [v0.82.2](./history/v0.82.2.md) - Harden capture, quit and storage races, page recent history by key, and search non-ASCII text up to 52% faster
- `2026-10-13` [v0.82.1](./history/v0.82.1.md) - Fix Homebrew installation on macOS 15 and later
- `2026-09-26` [v0.82.0](./history/v0.82.0.md) - Fix the scroll-stop jump, add undo, ⌘1–9, a status menu, Launch at Login and Chinese, and consolidate search, capture and rendering
- `2026-09-23` [v0.81.0](./history/v0.81.0.md) - Compress exports 2x faster (5x at speed 1) with the rebuilt pngquant
- `2026-09-11` [v0.80.7](./history/v0.80.7.md) - Restore preview typography and remove the reserved toolbar row
- `2026-09-11` [v0.80.6](./history/v0.80.6.md) - Keep multiple resizable previews with quiet unified controls and responsive reading layout
- `2026-09-11` [v0.80.5](./history/v0.80.5.md) - Discover and cache website icons across Markdown links, citations and source cards
- `2026-09-05` [v0.80.3](./history/v0.80.3.md) - Preserve Chinese tables and emphasis when capturing ChatGPT copies
- `2026-09-05` [v0.80.2](./history/v0.80.2.md) - Fix Chinese emphasis and single-dollar math while simplifying capture tests
- `2026-09-05` [v0.80.1](./history/v0.80.1.md) - Keep search pagination correctly ranked and apply new rows in small batches
<!-- release-recent:end -->

## Full History

- Current history directory: [history/README.md](./history/README.md)
- Legacy pre-reorg index snapshot: [../archive/release-index-legacy.md](../archive/release-index-legacy.md)
