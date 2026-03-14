---
doc_type: spec
status: active
owner: maintainers
last_reviewed: 2026-03-07
canonical: true
related_versions:
  - v0.60.2
---

# Current Requirements

This document is the active requirements baseline for Scopy. Historical planning drafts remain available in [../archive/specs/product-spec-v0-legacy.md](../archive/specs/product-spec-v0-legacy.md).

## Reference State

- Reference release: `v0.60.2`
- Source of truth for current version metadata: [../meta/release-current.yml](../meta/release-current.yml)
- Source of truth for development and implementation workflow: [development-guide.md](./development-guide.md)

## Product Definition

Scopy is a native macOS clipboard manager for users who need durable clipboard history, fast recall, low-friction filtering, and safe handling of mixed content types without sacrificing responsiveness.

## Product Goals

- Preserve useful clipboard history across text, rich text, images, and files.
- Keep retrieval fast enough that search feels immediate during interactive typing.
- Let users act on history items directly from the panel: copy, pin, delete, preview, export, and annotate where supported.
- Keep settings and operational behavior understandable and predictable.

## Current User-Facing Capabilities

### Capture And Persistence

- Capture text, RTF, HTML, images, and file items into history.
- Persist history using a mix of inline database storage and external payload files as needed.
- Deduplicate equivalent content instead of blindly creating duplicate rows.
- Keep image/file payload handling safe by validating external storage references before filesystem operations.

### History Browsing

- Show recent history in a floating panel driven by a global hotkey.
- Support incremental loading for large histories instead of blocking on full-history reads.
- Allow per-item copy, pin/unpin, delete, and contextual actions.
- Allow file items to carry editable notes.

### Search And Filtering

- Support four search modes: `Exact`, `Fuzzy`, `Fuzzy+`, and `Regex`.
- Support app-based filtering and content-type filtering from the header.
- Support multi-type filtering for grouped categories such as rich text.
- Keep result ordering user-relevant: pinned items stay prominent, with matching quality and recency driving the remainder.

### Preview, Media, And Export

- Provide hover previews for text, images, and files.
- Provide Markdown/LaTeX rendering and export-to-PNG.
- Allow optional pngquant-based compression for newly ingested images and exported Markdown/LaTeX PNGs.
- Show image thumbnails in the history list when enabled.

### Settings And Diagnostics

- Provide settings pages for General, Shortcuts, Clipboard, Appearance, Storage, and About.
- Preserve explicit Save/Cancel semantics for settings changes.
- Apply recorded hotkeys immediately after capture while keeping the rest of settings transactional.
- Show About-page version/build information and lightweight performance metrics.

## Current Search Contract

| Dimension | Current requirement |
| --- | --- |
| Modes | Exact / Fuzzy / Fuzzy+ / Regex |
| Filters | App filter, single-type filter, grouped multi-type filter |
| Pagination | Default page size is 50; incremental loading must remain available |
| Responsiveness | Typing should stay responsive with debounce around `150-200ms` |
| Fuzzy / Fuzzy+ | May return a staged first page, but must converge to complete full-history results |
| Exact | `>= 3` characters search complete history; `<= 2` characters intentionally search only the most recent `2000` items and must say so in the UI |
| Regex | Intentionally searches only the most recent `2000` items and must say so in the UI |

## Current Settings Surface

| Page | Setting | Current default | Requirement |
| --- | --- | --- | --- |
| General | Default search mode | `Fuzzy+` | New sessions should default to the same mode the main UI expects |
| Shortcuts | Global hotkey | `Shift+Cmd+C` | Users can re-record the panel toggle hotkey |
| Clipboard | Save images | `true` | Turning it off skips image history writes without mutating the live clipboard |
| Clipboard | Save files | `true` | Turning it off skips file history writes without mutating the live clipboard |
| Clipboard | Auto-compress new images | `false` | Uses pngquant parameters before writing image history |
| Clipboard | Compress exported PNG | `true` | Markdown/LaTeX PNG export should use pngquant when enabled |
| Clipboard | Polling interval | `500 ms` | Adjustable within the supported range `100...2000 ms` |
| Appearance | Show image thumbnails | `true` | Users can hide thumbnails for a denser list |
| Appearance | Thumbnail height | `40 px` | Users can pick supported thumbnail sizes |
| Appearance | Hover preview delay | `1.0 s` | Users can slow down or speed up preview trigger timing |
| Storage | Max items | `10,000` | History retention remains policy-controlled, not architecturally capped |
| Storage | Content budget | `200 MB` | Budget applies to content estimate, not raw DB file size |
| Storage | Cleanup images only | `false` | When enabled, auto-cleanup should preserve text/rich text while removing image items |

## Behavioral Requirements

### Correctness And Safety

- Copying from history must reproduce the stored content type as faithfully as the system pasteboard allows.
- Cleanup, delete, and optimization paths must not remove or rewrite unrelated files.
- File notes, image optimization, and export flows must not corrupt the underlying item model.
- UI refactors must not silently change settings transaction semantics.

### Performance And UX

- Search targets remain:
  - `<= 5k` items: P95 `<= 50ms`
  - `10k-100k` items: first page P95 `<= 100-150ms`
- Heavy I/O, hashing, indexing, cleanup, preview preparation, and export work should stay off the main thread.
- The history view and search UI must remain usable on realistic snapshot databases, not just toy data.

### Operability

- The app must remain buildable and testable on the repo baseline: macOS 14+, Swift 5.9, Xcode 16.
- Release and documentation flows are tag-driven and metadata-backed.
- Canonical documentation should stay aligned with the active release rather than accumulating historical planning text.

## Out Of Scope

- Cloud sync
- Semantic search or embedding-based retrieval
- Major UI redesign proposals that are not already merged
- Any feature idea that exists only in [../proposals](../proposals/README.md)

## Acceptance

A change is aligned with this requirements document when it:

1. Preserves or intentionally evolves a documented user-visible capability.
2. Respects the current settings and interaction contract.
3. Keeps the search, storage, and preview paths within their documented behavior boundaries.
4. Updates release/docs metadata when the user-visible contract actually changes.

## Related Docs

- Development and architecture guide: [development-guide.md](./development-guide.md)
- Runtime and release workflow: [release-runbook.md](./release-runbook.md)
- Current release index: [../releases/README.md](../releases/README.md)
- Historical planning baseline: [../archive/specs/product-spec-v0-legacy.md](../archive/specs/product-spec-v0-legacy.md)
