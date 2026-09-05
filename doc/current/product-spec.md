---
doc_type: spec
status: active
owner: maintainers
last_reviewed: 2026-09-03
canonical: true
related_versions:
  - v0.78.2
  - v0.70.0
  - v0.65.0
---

# Current Requirements

This document is the active requirements baseline for Scopy. Historical planning drafts remain available in [../archive/specs/product-spec-v0-legacy.md](../archive/specs/product-spec-v0-legacy.md).

## Reference State

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
- Treat concealed, transient, auto-generated, and password-manager pasteboard type markers as metadata rather than capture exclusions. When the represented content type is enabled, retain marker-bearing changes like ordinary clipboard changes.
- Persist history using a mix of inline database storage and external payload files as needed.
- Deduplicate equivalent content instead of blindly creating duplicate rows.
- Keep externally backed captures restart-replayable until their SQLite mutation is committed and acknowledged. Replaying the same durable ingest envelope must not duplicate the item-side mutation, increment usage twice, or resurrect an item that was later deleted.
- Keep image/file payload handling safe by validating external storage references before filesystem operations.
- Preserve exact logical byte counts across filesystem metadata, persistence, reload, search/recent hydration, cleanup planning, and display, including legitimate files above 2 GiB. An unrepresentable aggregate must fail safely rather than crash or wrap.

### History Browsing

- Show recent history in a floating panel driven by a global hotkey.
- Support incremental loading for large histories instead of blocking on full-history reads; pinned rows are loaded separately and do not consume the initial recent-page quota.
- Keep an idle history row passive: preview, note, Markdown export, image optimization, popover, and feedback state should be created only for real interaction or owned work, then released when every owned task is idle.
- Keep stable context-menu content predicates out of repeated row-body work. Cache the fast Markdown menu signal by content revision, keep it bounded, and preserve separately cached exact export capability as the authoritative result.
- Coordinate scrolling with one list-owned active slot and one tokenized suppressed-hover candidate rather than broadcasting scroll state through every visible row. A stationary pointer should regain its valid hover after scroll cooldown, while stale tokens must never revive another row.
- Allow per-item copy, pin/unpin, delete, and contextual actions, including AirDrop for images/files and Open Containing Folder for real file-backed items.
- Allow file items to carry editable notes.

### Search And Filtering

- Support four search modes: `Exact`, `Fuzzy`, `Fuzzy+`, and `Regex`.
- Support app-based filtering and content-type filtering from the header.
- Support multi-type filtering for grouped categories such as rich text.
- Keep result ordering user-relevant: pinned items stay prominent, with matching quality and recency driving the remainder.
- Explain results from a non-empty text search with bounded, source-aware match evidence generated alongside the result rather than rescanning full item content in the row UI. If malformed or differently normalized source text makes evidence unrenderable for one candidate, retain that candidate with ordinary metadata and count and log the shortfall. Query-wide evidence preparation failures remain search failures rather than silently stripping evidence from every result.
- Keep each result title stable. In search state, use the existing second line for an occurrence count and one or two short excerpts centered on the best matches; highlight every visible match with the adaptive system find color and a non-color emphasis cue.
- Label evidence from notes and file paths explicitly. If matches are distant or span body and note, show at most two excerpts and keep the existing one-line secondary-row height; a capped count is shown as a lower bound.
- Accessibility must announce the selected row, the match count, each visible excerpt's source and context, and its highlighted terms so candidates remain distinguishable without color or sight.

### Preview, Media, And Export

- Provide hover previews for text, images, and files.
- Let the user pin the preview that is open into a window of its own, so it can be read without holding the pointer anywhere. A pinned preview is movable to any position on any screen, resizable by its edges, and floats above other apps by default with a toggle to drop it to an ordinary window level; its position, size, and float preference are remembered. It survives list scrolling, row recycling, hovering other rows, and the history panel closing, and it closes only on an explicit action or when its item is deleted or its payload replaced. At most one preview is pinned at a time, and ordinary hover previews are suspended while one is pinned, because the pinned window owns the single shared Markdown WebView. Pinning hands over the already-rendered content instead of preparing the preview again.
- Keep an already-open preview stable while the pointer intentionally crosses from its history row to the preview, regardless of which side or corner hosts the popover. Retention applies only inside the directional corridor and while progress toward the preview continues; leaving the corridor, reversing, stalling, target loss, scroll/dismiss, or the `500ms` cap must close it promptly.
- Returning from the preview to its row keeps only a short fixed handoff grace. Re-entering a row whose preview is already open must not restart preview preparation or flicker the popover.
- Hover intent affects only transfer after a preview is open; it must not alter the user-configured hover preview trigger delay. While a transfer is active, adjacent rows must defer selection and preview ownership so screen-edge popover placement cannot steal the source preview.
- Provide Markdown/LaTeX rendering and PNG export through one fully local CommonMark/GFM pipeline with stable footnote IDs, HTML-only KaTeX, syntax highlighting, source citations, task/table layout, and one closed safe-HTML extension. Attribute-free paired `u`, `kbd`, `mark`, `sub`, and `sup`, plus the exact block `details`/plain-`summary` form, may render as semantic elements; complete comments are hidden and every other user-authored HTML form stays visible literal text rather than executing.
- Recognize only validated `scopy-rich` v2 envelopes for structured web results, search-image groups, news, weather, finance, currency, video, product, product-carousel, place-entity, and static-map cards. The closed public-Markdown presentation adapters may promote exact visible shapes — consecutive image-only paragraphs, a lone YouTube link, a link-plus-price pair, and a name/link/address block — through the same v2 validator using only visible fields; they must not infer thumbnails, ratings, dates, series data, or other stripped metadata, and surfaces whose public copy lacks the data stay ordinary prose. An opt-in, default-off link-enrichment setting may fetch Open Graph titles and downscaled imagery for the bare links of recognized assistant content (ChatGPT web copies, Codex output, and similar), freezing them locally so news and article cards render offline afterwards; the renderer itself never performs network access. The app also checks for new releases through a Sparkle appcast, reminds the user when an update exists, and installs and relaunches on confirmation. Rich data surfaces use frozen source data and bundled allowlisted assets; invalid or unsupported envelopes remain visible code fences, and ordinary copied prose must never be guessed into private card metadata.
- Keep supported weather/day, finance/range, currency, chart, local-image, and grouped-source controls interactive in preview. PNG export freezes those same elements before capture; it must not switch to a second parser, document, stylesheet, asset source, or data model.
- Render the two exact public ChatGPT Search image URLs preserved by the fixture from bundled local raster assets on every machine. Never generalize that mapping into arbitrary remote image fetching or URL-pattern inference; unknown remote Markdown images retain the deterministic offline fallback.
- Distinguish ordinary validated HTTP(S) links, Codex absolute file links with optional line/column suffixes, and source citations. Native opening requires an explicit preview click and strict validation; raw `file:` URLs, unsafe paths, programmatic navigation, and export activation are rejected.
- The reusable Markdown `WKWebView` must have one current visible owner. Hidden premeasurement is forbidden; stale teardown cannot detach a newer owner, identical in-flight HTML cannot restart navigation, and scroll configuration must tolerate WebKit creating its internal scroll view after the initial update.
- A new Markdown load stays visually shielded until stylesheet, fonts, local images, renderer/runtime hydration, two stable paint frames, and terminal geometry are all resolved. Successful cached metrics are valid only for the exact active layout scale; terminal failure must replace the shield with the preserved source/reason instead of exposing an empty WebView.
- Allow Markdown hover previews to adjust ChatGPT layout scale continuously from 80% to 200% from the preview itself, with light magnetic snapping at each 5% stop; the selected preview scale also controls PNG export launched from that preview. The preview control should stay compact until hover or drag interaction and should keep the last rendered Markdown visible while the new layout profile is prepared.
- Allow optional pngquant-based compression for newly ingested images and exported Markdown/LaTeX PNGs.
- Show image thumbnails in the history list when enabled.
- Allow all image history rows to be sent via AirDrop; inline/stored images may be materialized as temporary PNG files for sharing.

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
| Pagination | Pinned items are independent of recent pagination; default recent unpinned page size is 50 and load-more pages fetch 500 unpinned items |
| Responsiveness | Production search dispatch uses `0ms` debounce; queries of at most two characters use a minimum `16ms` coalescing delay |
| Fuzzy / Fuzzy+ | May return a staged first page, but must converge to complete full-history results |
| Exact | After trimming surrounding whitespace, `>= 3` characters search complete history; `<= 2` characters intentionally search only the most recent `2000` items and must say so in the UI |
| Regex | Intentionally searches only the most recent `2000` items and must say so in the UI |
| Match evidence | Each candidate from a non-empty semantic query carries the real matched excerpt and source when it can be rendered. A candidate whose malformed or differently normalized source cannot produce evidence remains visible with normal row metadata; the engine counts and logs the per-item shortfall. Query-wide evidence preparation failures still fail the search. Multiple matches show a count plus at most two excerpts; zero-width regex matches are described as positional evidence. Empty/filter-only searches preserve the normal row metadata. |

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
| Appearance | Markdown ChatGPT layout scale | `100%` | Users can set the default Markdown preview/export layout scale from 80% to 200%; hover preview also provides the same local scale slider |
| Storage | Max items | `10,000` | History retention remains policy-controlled, not architecturally capped |
| Storage | Content budget | `200 MB` | Budget applies to content estimate, not raw DB file size |
| Storage | Cleanup images only | `false` | When enabled, auto-cleanup should preserve text/rich text while removing image items |

## Behavioral Requirements

### Correctness And Safety

- Copying from history must reproduce the stored content type as faithfully as the system pasteboard allows.
- A copy that did not reach the system pasteboard must fail, not report success. A missing row, an unreadable payload, and a pasteboard that refused the content are all errors; usage counts and item events must not advance, the panel must stay open, and the failure must be visible to the user rather than only logged.
- A file capture replays the exact nodes it recorded, in copy order. Directories and packages are part of that list: a copied folder must return to the pasteboard as the folder, not as its path text. Falling back to path text is only correct when every recorded node is gone.
- When HTML and plain-text clipboard representations are demonstrably related, preserve authored Markdown structure from the plain-text representation while retaining the HTML payload. Comparison must tolerate CJK inline-emphasis boundaries and HTML extraction joining table cells; it must not discard authored tables or bold because whitespace/token boundaries changed. Unrelated or suspicious side-channel text must not replace the trustworthy rich-content extraction.
- Cleanup, delete, and optimization paths must not remove or rewrite unrelated files.
- Cleanup must revalidate each planned row inside the deleting transaction. A row pinned after planning, or whose content identity, recency, size, type, or storage ownership changed, must remain untouched; history and search must converge from the exact committed deletion set.
- Durable ingest artifacts must stay inside the owned Application Support spool. Traversal, foreign acknowledgement URLs, symlinks, and malformed artifact names fail closed without reading or deleting outside that root.
- The storage commit protocol guarantees process-crash/restart consistency (D1). It does not claim power-loss durability while SQLite remains WAL `synchronous=NORMAL` and file publication is not explicitly synced.
- Cleanup decisions must use exact nonnegative persisted byte counts; a large row that satisfies a cleanup target must not cause later unrelated rows to be selected because of integer narrowing or overflow.
- AirDrop should share validated real files when available and may generate temporary PNGs for image rows; Open Containing Folder must only reveal real user files, never temporary share artifacts.
- Paste-optimized for Codex must post `Control+V` after copying and closing the panel, and only after the copy is known to have reached the pasteboard; pasting after a failed write would deliver whatever the clipboard held before.
- File notes, image optimization, and export flows must not corrupt the underlying item model.
- Markdown preview and PNG export must use the same parsed HTML and base CSS for math, footnotes, syntax highlighting, tables, tasks, citations, CJK/RTL text, and Unicode; export-only fitting may run only after preview-equivalent layout is ready.
- UI refactors must not silently change settings transaction semantics.

### Performance And UX

- Search targets remain:
  - `<= 5k` items: P95 `<= 50ms`
  - `10k-100k` items: first page P95 `<= 100-150ms`
- Heavy I/O, hashing, indexing, cleanup, preview preparation, and export work should stay off the main thread.
- Hover-intent sampling must be absolutely bounded, must not invalidate SwiftUI at sampling frequency, and must remain correct for negative screen coordinates, multi-display placement, live popover movement or resize, delayed geometry, adjacent-row crossings, and teardown.
- Same-ID content replacement must invalidate stale preview, note, export, and presentation work. Image optimization may survive only the revision transition explicitly owned by its result.
- Context-menu availability must preserve keyboard and accessibility behavior; performance work may cache stable predicates but must not defer menu availability until hover or conflate a heuristic Markdown signal with exact PNG-export capability.
- Normal row/button/context-menu pointer events must not be classified as scrollbar interaction; suppression begins only for an actionable vertical or horizontal scroller part with matched down/up ownership.
- The history view and search UI must remain usable on realistic snapshot databases, not just toy data.
- Search typing focus and list selection remain independent: focusing the search field does not clear the selected row, and hover can still update row selection while the field is focused.

### Operability

- The app must remain buildable and testable on the repo baseline: macOS 14+, Swift 5.9, Xcode 16.
- Release and documentation flows are tag-driven and metadata-backed. Only the explicit maintainer flow may create a tag; pushing release documents must validate without publishing.
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
