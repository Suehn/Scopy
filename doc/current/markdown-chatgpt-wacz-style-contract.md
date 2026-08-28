# ChatGPT-aligned Markdown Rendering Contract

This is the canonical contract for Scopy Markdown preview and PNG export. It records what the 2026-08-28 ChatGPT captures prove, where each archive is incomplete, and the single local implementation that Scopy must keep stable.

## Evidence Scope

Primary capture:

- archive: `/Users/hh/Downloads/my-archiving-session.wacz`
- captured page: `https://chatgpt.com/`
- archive time: 2026-08-28
- reproducible extraction: `/tmp/scopy-wacz-extract/my-archiving-session-20260828`
- extraction command:

```bash
python3 scripts/quality/analyze-chatgpt-wacz-markdown.py \
  /Users/hh/Downloads/my-archiving-session.wacz \
  --out-dir /tmp/scopy-wacz-extract/my-archiving-session-20260828 \
  --force
```

The extraction found 653 content responses: 444 JavaScript files, 39 CSS files, 145 JSON responses with an unspecified charset, one UTF-8 JSON response, ten WOFF2 responses, two initial HTML responses, and other media/runtime resources. The wider WARC contains 660 requests, 653 responses, seven revisits, and one `warcinfo` record. The Markdown-related audit matched 270 JS/CSS files.

This capture does **not** contain a completed conversation response or hydrated final answer DOM:

- the WACZ registers the ChatGPT root page, not a recoverable `/c/<conversation-id>` document;
- the captured `/stream_status` says `IS_STREAMING` at that response time;
- the extracted conversation-like JSON responses contain zero assistant Markdown messages;
- the saved page text preserves many visible edge-case strings, but text alone cannot prove element type, computed style, line wrapping, scroll geometry, theme, or accessibility tree.

Secondary capture:

- archive: `/Users/hh/Downloads/my-archiving-session (1).wacz`
- captured page: `https://chatgpt.com/c/6a90ea40-c6e4-83ea-8a59-fb00f791fa25`
- archive time: 2026-08-28

This recording reached the named conversation, but the assistant message was still `in_progress` while the archive was being written. It does not contain a final hydrated assistant DOM or computed-style snapshot. A live Microsoft Edge inspection can therefore supply measured layout facts for the same visible surfaces, but those measurements must be labeled `live/runtime-derived`; they are not WACZ payload evidence and cannot establish what the unfinished archived answer would finally have contained.

The secondary WACZ does preserve one complete structured `search_result_group` at `messages[17].metadata.search_result_groups[0]`, including frozen titles, destinations, `openai.com` attribution, publication timestamps, thumbnail URLs, and the three thumbnail PNG responses. Scopy may map those exact visual fields into a `news` fixture while labeling the mapping: the backend objects themselves are `search_result_group` / `search_result`, not a literal `news` payload. The linked article pages were not archived, so this evidence validates card fields and thumbnail provenance, not article bodies or factual claims.

The ordinary ChatGPT Copy action observed alongside this capture writes both `text/plain` Markdown and `text/html`. Both public representations omit private reference objects and DIL metadata. That public copy is intentionally lossy for rich surfaces:

- weather, currency, and finance/stock cards disappear rather than becoming reconstructable card data;
- an `image_group` becomes consecutive ordinary Markdown images;
- news becomes ordinary links;
- no consumer may rebuild a missing card from surrounding prose, private reference syntax, archived runtime bundles, or current network data.

Therefore this contract distinguishes five evidence levels:

| Level | Meaning |
| --- | --- |
| Captured runtime path | Exact parser option, component branch, CSS declaration, or render function exists in the archived code. |
| Archived structured payload | Exact frozen fields exist in a captured response; they may test a labeled Scopy surface mapping but do not prove linked content or final computed UI. |
| Saved-text observation | Characters survived into archived page text; DOM and visual layout remain unknown. |
| Live/runtime-derived | A measured live Edge DOM/layout or a fixture using those measured values; it must not be attributed to WACZ or ordinary Copy. |
| Scopy stability adaptation | A deterministic local rule needed for offline WKWebView preview/export; it is identified as Scopy behavior rather than falsely presented as observed ChatGPT DOM. |

Do not describe runtime-path evidence as a measured final DOM or computed style. A future change to dark mode, responsive thresholds, fonts, or component structure requires a new hydrated capture or live-DOM measurement before constants are changed.

## Captured Runtime Pipeline

The relevant archived code paths are:

| Concern | Extracted source | Captured behavior |
| --- | --- | --- |
| GFM deletion | `0193_chatgpt.com__cdn_assets_2afb55f3-lu3w05zggnq379p9.js.js` | `remark-gfm` uses `singleTilde: false`. |
| Math delimiter policy | same chunk | `remark-math` uses `singleDollarTextMath: false`. |
| Main KaTeX render | `0369_chatgpt.com__cdn_assets_92cd10e6-jjavjknqtcsnwvej.js.js` | `output: "html"`, `throwOnError: true`, `trust: false`; parse errors retry with `strict: "ignore"` and `throwOnError: false`. |
| Math host semantics | `0235_chatgpt.com__cdn_assets_427e2db6-b5g2la6rlxwmly3m.js.js` | host has `role="math"`, `aria-label`, `data-math-source`, and `data-client-katex-layout`. |
| Completed Markdown styling | `0601_chatgpt.com__cdn_assets_root-d7fyo9pd.css.css` | `.markdown.prose.markdown-new-styling` typography, spacing, wrapping, tables, tokens, and responsive thread-width code paths. |
| Code viewer | `0502_chatgpt.com__cdn_assets_code-block-dop2czwo.css.css` and `0503_chatgpt.com__cdn_assets_code-block-viewer-bb2wmqiy.css.css` | 14/20 code text, local horizontal scroll, preformatted content, and optional wrap mode. |
| Table component | `0606_chatgpt.com__cdn_assets_table-components-b39fqymt.css.css` plus JS matches for `data-col-size` | local horizontal scroll, measured column buckets, `fit-content`, and `min-width: 100%` of its component/thread container; Scopy expresses that minimum as the resolved current thread width. |

The archive also contains alternate/streaming Markdown and code-block paths. They are not the completed `.markdown.prose.markdown-new-styling` contract and must not be mixed into the final style merely because their assets are present.

## One Scopy Rendering Path

There is one production flow:

```text
source + MarkdownRenderContext
  -> bounded source normalization
  -> MarkdownHTMLRenderer
  -> local unified/remark/rehype bundle
  -> MarkdownHTMLDocumentBuilder.document
  -> the same standalone HTML document
       -> MarkdownPreviewWebView
       -> MarkdownExportService
```

Authoritative implementation surfaces:

- `Scopy/Views/History/MarkdownHTMLRenderer.swift`: bounded, code-aware source normalization and the only document entrypoint.
- `Scopy/Views/History/MarkdownHTMLDocumentBuilder.swift`: local assets, CSS, table/runtime measurement, readiness, and export hooks.
- `Tools/MarkdownRenderer/src/render.js`: Markdown AST/HTML AST pipeline.
- `Tools/MarkdownRenderer/src/remarkScopyRich.js`: strict v2 validation and the only trusted rich-surface HAST builders.
- `Tools/MarkdownRenderer/src/richInteractionRuntime.js`: one delegated preview hydrator and deterministic export freeze.
- `Tools/MarkdownRenderer/src/scopyIcons.js`: closed official Phosphor icon paths used by Codex-style links and rich controls.
- `Tools/MarkdownRenderer/src/rehypeScopyKatex.js`: HTML-only math rendering and stable failure behavior.
- `Scopy/Views/History/MarkdownPreviewWebView.swift`: generation-safe WebView lifecycle and metrics.
- `Scopy/Services/Export/MarkdownExportService.swift`: PNG reliability strategies applied to the same HTML.

There is no legacy renderer selection, feature flag, shadow renderer, silent markdown-it fallback, or second preview/export parse result. Missing renderer assets are a render failure, not permission to display a semantically different document.

## `scopy-rich` v2 Structured Snapshot

Ordinary Markdown remains the public interchange fallback. When the producer actually possesses a complete structured surface, it may place one strict JSON object in a fenced block whose info string is exactly `scopy-rich`. The envelope freezes all source data needed for rendering and interaction; it is never a prompt to query, scrape, refresh, or infer. The same `MarkdownHTMLRenderer -> MarkdownHTMLDocumentBuilder` flow recognizes and validates it while building the same Markdown AST/HTML document. Preview hydration and PNG export are two modes of that one document, not separate card renderers or source fetches.

```text
Markdown source
  -> code-aware normalization
  -> MarkdownHTMLRenderer
       -> ordinary Markdown nodes
       -> strict scopy-rich v2 validation and trusted rich-surface nodes
  -> MarkdownHTMLDocumentBuilder.document
  -> one local HTML/CSS/SVG document for preview and export
```

### Envelope and frozen schema

The fence body is UTF-8 JSON with exactly one top-level object. It must contain `"version": 2` and one supported `type`; `kind` is not an alias. Every type may use the common fields `title`, `state`, `message`, `source`, `sourceUrl`, and `asOf`. Unknown keys are rejected at every object level.

Display strings are already formatted and remain literal. The renderer does not localize, refresh, fill, or infer them; unavailable display data is the literal string `—`. Numeric fields exist only where a deterministic preview interaction or chart geometry needs them. They are frozen inputs, not permission to fetch a current value.

| `type` | Type-specific v2 fields |
| --- | --- |
| `news` | `items[] { title, url, source, date, snippet, image, favicon }`. `image` and `favicon` use the closed image-reference form below. |
| `web_results` | The same result fields as `news`; presentation remains a web-results list rather than a news track. |
| `image_group` | `layout` is exactly `search`, `carousel`, or `full_width`; `initialIndex`; `images[] { asset/src, alt, title, source, sourceUrl }`. |
| `weather` | `location`; `selectedUnit` is `F` or `C`; `selectedDay`; `days[] { label, condition, icon, current, high, low, hourly }`. Each temperature display pair is `{ f, c }`; each hourly numeric pair is `{ f, c }`. |
| `finance` | `asset { name, ticker }`; `quote { price, afterHours }`; `selectedRange`; unique `series[] { label, dateRange, change, changePercent, trend, points[] }`; `metrics[]`. A point is `{ label, value, displayValue }`. |
| `currency` | `from` and `to` identities; frozen numeric `amount` and positive `rate`; integer `fractionDigits`. Preview may calculate the other input in either direction from only these frozen values. |

An image reference contains exactly one of:

- `asset`: an ID in the renderer's closed bundled-asset allowlist, plus optional `alt`; or
- `src`: a sanitized HTTP(S) provenance URL or an allowed bounded raster data URL, plus optional `alt`.

`merchant`, `product`, `map`, and `entity` are deliberately unsupported. Unknown types or assets, unknown keys, type mismatches, invalid JSON, any version other than `2`, a non-empty fence meta string, or a fence containing more than one JSON value leave the original fence rendered as ordinary code. Validation is all-or-nothing; there is no legacy-version compatibility or partial card assembled from valid-looking fragments.

### State, missingness, and limits

`state` is one of `ready`, `empty`, `partial`, or `error`:

- `ready` means every required field and collection for that type is present; exact numeric and display-string zero remain valid data;
- `empty` means the producer positively returned no results; `message` is required and type-specific body fields are absent;
- `partial` means the payload is structurally valid but intentionally incomplete in coverage; required schema fields still exist, unavailable display positions contain `—`, and `message` states the boundary;
- `error` means acquisition failed; `message` is required, type-specific body fields are absent, and no stale or guessed card body is synthesized;
- `0`, `0.00`, `+0.00%`, an empty result set, `—`, and an acquisition error are distinct and must never collapse into the same branch.

To keep one clipboard item and one export bounded, v2 applies these hard limits after UTF-8 decoding:

| Input | Limit |
| --- | ---: |
| one `scopy-rich` fence | 1 MiB, maximum nesting depth 8 |
| any display string / any URL | 4,096 / 2,048 Unicode scalars; base64 image payloads use the byte limits below |
| `news.items` / `web_results.items` | 20 each |
| `image_group.images` | 12 |
| `weather.days` / one day's `hourly` | 10 / 24; each day has at least two hourly points |
| `finance.series` / points per series / all series points / `finance.metrics` | 8 / 256 / 1,024 / 16; each series has at least two points |
| one inline raster data image / all inline data images | 256 KiB decoded / 512 KiB decoded |

Exceeding a limit invalidates that fence and preserves it as code; the renderer does not truncate a snapshot and pretend it is complete.

### Links, images, and offline behavior

- Rich outbound links may be emitted only by a handler's explicit `url` or `sourceUrl` field and must pass sanitized HTTP(S) validation. The common envelope `sourceUrl` remains frozen provenance metadata unless its surface handler explicitly renders it; it is never an implicit fallback link. An explicit user click in preview is cancelled inside WKWebView and handed to the native workspace opener after host, credential, control-character, and length validation; programmatic navigation never opens externally. Export links remain inert. Private ChatGPT refs, DIL fields, conversation/session identifiers, and invented citation targets are neither schema fields nor fallback link sources.
- `data:image/png`, `data:image/jpeg`, `data:image/gif`, and `data:image/webp` may be embedded only within the size limits. Payload HTML, SVG, scripts, CSS, and other data MIME types are rejected as images.
- A recognized `asset` resolves only to its bundled local file. An HTTP(S) image `src` is retained as provenance but is never fetched for offline rendering; both modes show the same deterministic placeholder and frozen `alt`. Unknown assets, simultaneous `asset` and `src`, missing sources, and rejected data images invalidate a strict v2 envelope.
- Card icons, chart axes, and chart geometry are deterministic local SVG generated from validated frozen inputs. The exact SVG markup, HTML, base CSS, local files, and interaction runtime are shared by preview and export; canvas, remote icon kits, and export-only reconstruction are forbidden.

### Captured light-state design rules

The supplied 2026-08-28 captures and live Edge computed styles establish reusable layout rules, not screenshot-specific width/height overrides. The WACZ is a valid ZIP/WACZ with indexed WARC responses, CSS, JavaScript, fonts, images, conversation data, and GenUI traffic, but it does not contain the hydrated final component DOM. WACZ evidence therefore supplies data/resources/code paths while live Edge supplies final geometry and computed style.

| Surface | Responsive rule and wide-reference state |
| --- | --- |
| Rich thread | The logical layout viewport selects the canonical 40rem or 48rem thread column; the current 816px output surface reaches the 48rem state. Cards fill that column, stay on `#fcfcfc`, and use a 10% black hairline plus the shared 20px radius. No component may key behavior off the physical WKWebView width. |
| News | A horizontal snap track uses 16px gaps and `calc((100% - 2 * gap) / 3)` item basis; narrow containers retain a locally scrolling card width. Each card has a 144px media slot, 12px radius, 16px horizontal copy inset, 12/16 source and date text, and a 14/20 five-line title. The wide reference resolves to three approximately 245px columns without storing that resolved width. |
| Search images | The group occupies the thread width as a reserved three-slot search rail rather than stretching a short result set. Each item takes one flexible 5:4 slot with 4px gaps, so the captured two-result state fills two slots and deliberately leaves the third available. Narrow containers use 128px locally scrolling items. Source raster assets and the fullscreen preview lightbox are shared by preview/export. |
| Finance | The card height is content-derived: padded quote header, range controls whose 4.5rem minimum slots distribute across available width and locally scroll only when needed, a chart whose height clamps between compact and wide states, and an auto-fit metric grid. The chart uses a vertical fade, stable nice-number ticks, and rounded trend strokes. Metrics resolve to three, two, or one label/value columns from a 12rem minimum column rule rather than a screenshot-width branch. |
| Weather | The card height is content-derived from a 20px inset header/current section, full-bleed locally scrolling daily strip, compact metric selector row, and 120px chart plus its bottom inset. Daily controls flex to available width with a 90px minimum; hourly SVG width grows by point slots and owns horizontal overflow instead of squeezing 24 observations into the page width. |
| Currency | The converter uses two equal content rows with a 20px horizontal inset and divider. The amount controls remain editable, preserve currency identity, and scale with the card rather than a captured screenshot width. |

### Stable identity, accessibility, RTL, and overflow

Content IDs derive from validated AST source order, not array memory addresses or the per-load WebView render ID. The card root is `scopy-rich-<type>-<zero-based-document-ordinal>`; descendants append a semantic role and zero-based source index. The same source therefore yields the same IDs in preview and export without a content digest. They never share the footnote `scopy-fn-*` namespace, and the opaque `data-scopy-render-id` remains load-specific.

Each card is a labeled section. Result collections use list semantics; metrics and weather values use labeled value semantics; informative images require frozen alternative text; decorative icons are hidden from assistive technology. Weather and finance charts carry accessible labels and equivalent point lists, so color and SVG geometry are not their only meaning. `empty`, `partial`, and `error` messages remain visible text, not color-only badges.

Grouped source citations keep the compact primary pill inline. Their supporting-source panel uses a continuous hover/focus bridge and a runtime-computed inline offset clamped to 12px from both viewport edges; this is collision handling, not a source-position-specific screenshot offset.

The card root uses `dir="auto"` and logical CSS properties. Tickers, currency codes, signed numbers, date/range tokens, chart axes, and numeric values use LTR isolation without rewriting surrounding Arabic or Hebrew. Cards stay within the current 40rem/48rem thread column. Long titles and values wrap; carousels, charts, and dense tracks may own local horizontal overflow. No rich surface may widen the Markdown document, PNG canvas, or Swift popover.

### Preview interaction and frozen export

Preview hydrates only pre-rendered v2 DOM and uses delegated, idempotent local handlers. It may switch weather unit/day panels, switch finance range panels, edit either side of the frozen-rate currency pair, inspect pre-rendered chart points, and navigate a local-image lightbox. These actions neither mutate the Markdown source nor fetch, refresh, or invent data. Invalid numeric input is visibly invalid and does not overwrite the peer value; keyboard, focus restoration, ARIA state, and Escape behavior are part of the interaction contract.

Any older active text that describes rich preview as inert or non-interactive is obsolete and must be deleted or marked non-canonical. Only export is frozen; preview interaction is required for the supported v2 controls above.

Export constructs the same standalone HTML in a separate WebView and freezes its envelope-selected initial state. Before capture it closes transient lightboxes/tooltips, disables every rich action and link, removes them from the tab order, and installs a cancellation delegate. PDF, one-shot, and tiled capture therefore observe one deterministic frozen DOM. Preview's transient edited values are not a second source and do not leak into export.

Rich v2 exports remain true-color PNGs. Palette reduction is skipped whenever the rendered document contains a validated `data-scopy-version="2"` surface because low-color pngquant settings collapse subtle chart gradients, weather icons, and source imagery even though the shared DOM/CSS is correct. Ordinary Markdown exports may continue to honor the user's PNG compression settings.

## Markdown Semantics

### Blocks and inline syntax

| Input | Result |
| --- | --- |
| ATX headings | `#` through `######`; Scopy repairs missing whitespace such as `#标题` outside code. Heading elements receive no generated `id`. |
| Paragraphs and line breaks | CommonMark paragraphs; the local assistant-style path turns source newlines into `<br>` through `remark-breaks`. |
| Emphasis | `*text*`/`_text_` become emphasis; `**text**`/`__text__` become strong text. |
| Deletion | Only paired double tildes such as `~~text~~` create `<del>`; `~text~` remains literal. |
| Inline code | Backtick spans block Markdown/math parsing inside them. Delimiter length follows CommonMark, including embedded backticks. |
| Fenced code | Backtick or tilde fences; a four-backtick outer fence can contain a three-backtick example without splitting into two blocks. |
| Links/images/autolinks | Parsed by CommonMark/GFM, then sanitized. HTTP(S), normal relative/absolute local paths, Codex-style absolute file paths with an optional `:line` suffix, and the explicit local `plugin:` integration path are preserved according to the sanitizer schema. A `file:` URL is not widened into an allowed source merely because it names a local file. |
| Lists/tasks | Ordered/unordered and nested lists; GFM tasks retain disabled checked/unchecked inputs which the document runtime paints consistently for preview and PNG. |
| Tables | GFM pipe tables; alignment markers are supported. Unescaped `|` is a column delimiter even inside mathematical text. |
| Raw HTML | Every user-authored raw tag becomes visible escaped text. `<script>` can never survive as an executable element. Trusted renderer plugins may still create structural elements. |
| Thematic breaks | CommonMark thematic breaks become `<hr>`. |
| Footnotes | GFM footnotes are supported. Renderer-generated IDs use exactly one namespace: definition `scopy-fn-<normalized-id>`, reference `scopy-fnref-<normalized-id>`, and repeated references append `-2`, `-3`, etc. Heading IDs are not synthesized. |

All source normalization is syntax-aware:

- fenced code, indented code, inline code, links, images, reference definitions, URLs, and file paths are protected before loose scientific-text repair;
- `#标题` repair does not rewrite code fences, indented code, or shebangs;
- table-row code spans escape their internal unescaped pipe so examples such as `` `| A | B |` `` remain in one cell;
- three-or-more-backtick fence-marker examples inside a table cell remain cell text;
- source-citation promotion requires explicit source-like parenthesized HTTP(S) references; normal links, local file links, and Codex path links are not restyled as citations.

### IDs and fragment stability

The renderer owns only IDs it generates. Raw HTML is literal, headings have no slugging plugin, and source content cannot inject arbitrary elements or IDs. Footnote `href` and `id` values are generated in the same `scopy-` namespace before sanitization; the sanitizer must not add a second clobber prefix. This prevents visually valid but broken footnote navigation.

### HTML and sanitizer boundary

`remarkLiteralHTML` converts Markdown AST `html` nodes to text before the HTML AST exists. `remark-rehype` runs with `allowDangerousHtml: false`, followed by `rehype-sanitize`. This means:

- user-authored `<details>`, `<kbd>`, `<mark>`, `<sub>`, `<sup>`, `<div>`, `<br>`, and `<script>` are displayed as literal tags;
- the existence of CSS rules for an element is not permission for raw source to create that element;
- syntax highlighting, KaTeX, tasks, footnotes, and source citations remain trusted renderer-generated structures;
- source is JSON-encoded into the standalone document, so `</script>` cannot break out of the payload script.

## Formula Contract

Supported explicit math forms:

| Source form | Mode |
| --- | --- |
| `\(...\)` | inline |
| `\[...\]` | display |
| `$$...$$` | display |
| fenced `math` block | display |

A single-dollar pair such as `$20` or `$x + 1$` remains literal. Currency, shell variables (`$HOME`, `$PATH`), code spans, code fences, links, URLs, and file paths must never be reinterpreted as math.

KaTeX behavior:

1. Render with `displayMode` from the parsed node, `output: "html"`, `strict: "error"`, `throwOnError: true`, and `trust: false`.
2. On a strict/parse failure, emit a warning and retry with `strict: "ignore"`, `throwOnError: false`, and `trust: false`.
3. If the retry cannot produce output, emit a stable `.katex-error` span containing the original literal source.
4. Load `mhchem` locally for chemistry syntax; never load runtime assets from the network.
5. Wrap each formula in a semantic host with `role="math"`, `aria-label=<full source>`, `data-math-source=<full source>`, and `data-client-katex-layout`.
6. Cap user-declared KaTeX geometry at 20em so inputs such as `\\rule{100000em}{100000em}` cannot expand preview or PNG height without bound. This is a Scopy stability guard; it is not claimed as an observed ChatGPT runtime option.
7. Do not put `content-visibility:auto` on formula hosts. WebKit can omit off-viewport formulas from a full-document PNG snapshot even though their intrinsic placeholders remain. Scopy keeps every formula paintable; this is an export-stability guard.
8. The main answer path is HTML-only KaTeX. CSS or auxiliary code mentioning `.katex-mathml` does not prove that the captured main answer used a MathML+HTML pair.

The optional loose-math repair is a Scopy input adaptation for clearly detected OCR/scientific or LaTeX-document profiles. It is disabled for ordinary ChatGPT/authored Markdown, and profile selection may change only bounded source repair—not the renderer, CSS, or output architecture.

## Typography, Fonts, and Rhythm

The completed-style runtime path resolves to the following light-theme geometry at a 16px root. These are code-path values from the capture, not a measured final DOM instance:

| Element | Size / line-height | Weight | Block rhythm |
| --- | ---: | ---: | --- |
| body/root | 16 / 26px | 400 | zero outer margin |
| h1 | 24 / 32px | 600 | top 0, bottom 8px |
| h2 | 20 / 28px | 600 | top 16px, bottom 4px |
| h3 | 18 / 28px | 600 | top 16px, bottom 4px |
| h4 | 16 / 24px | 600 | top 16px, bottom 0 |
| h5 | 16 / 26px | 600 | 0 |
| h6 | 16 / 26px | 400 | 0 |
| paragraph | 16 / 26px | 400 | 4px block margin; adjacent `p + p` uses 16px |
| list | 16 / 26px | 400 | margin 0; 26px start padding |
| list item | 16 / 26px | 400 | 6px start padding; bold marker |
| blockquote | 16 / 24px | 400 | bottom 8px; padding `8px 0 8px 24px` |
| table | 14 / 24px | 400 | table owns its row padding/borders |

The quote bar is a pseudo-element, not a traditional border: 4px wide, inset 8px from top and bottom, with a 2px radius.

Inline code uses the local mono stack, `0.875em`, weight 500, inherited line height, `2.4px 4.8px` padding, 4px radius, low-alpha background/stroke, and `overflow-wrap: anywhere`. The same rule applies inside headings; there is no h3-only size override.

Code cards use 14/20px monospace text, 24px radius, a local neutral surface, an in-card language label, `white-space: pre`, `min-width: max-content`, and local horizontal scrolling. Highlighting is explicit-language only (`detect: false`) so the same source does not change colors as the bundled language detector evolves. Export may opt into pre-wrap only as a post-layout bitmap-fit strategy.

Scopy body font stack:

```text
-apple-system-body, ui-sans-serif, -apple-system, system-ui,
Segoe UI, Helvetica, Apple Color Emoji, Arial, sans-serif,
Segoe UI Emoji, Segoe UI Symbol
```

Mono stack:

```text
ui-monospace, SFMono-Regular, SF Mono, Menlo, Consolas,
Liberation Mono, monospace
```

Font evidence must be stated carefully. The WACZ declares 63 `@font-face` entries, but only 14 faces have archived bytes: 11 KaTeX faces (ten external WOFF2 plus one inline Size3), one external OpenAI Sans Semibold, and two inline Circle faces. The initial body lacks `data-type-stack="openaisans"`; therefore the archive does not prove that completed answer text used OpenAI Sans. Scopy deliberately uses the macOS/system stack for ordinary text and bundled KaTeX fonts for math, with no network dependency. CJK, Arabic, Hebrew, emoji, and uncommon scripts may use system fallback fonts.

## Links, Citations, Tasks, and Tables

Ordinary links receive the external-link treatment only when their sanitized destination is an absolute HTTP(S) URL with a host, no credentials, no encoded or decoded control characters, and at most 8,192 UTF-8 bytes. Those links use the local blue accent, reveal an underline on hover, and append the bundled official Phosphor `arrow-up-right` icon. An explicit preview click opens the validated HTTP(S) destination through the native workspace URL handler; export is inert.

A Codex file link such as `[render.js](/Users/hh/Documents/code/Scopy/Tools/MarkdownRenderer/src/render.js:25)` retains the absolute path and one-based `:25` suffix as its Markdown destination. It is local, receives a file-kind icon rather than an external affordance, and never becomes a source citation. An explicit preview click may hand only that validated absolute path plus optional one-based line/column suffix to the native workspace opener; programmatic navigation, remote hosts, relative paths, double-slash paths, queries, fragments, credentials, and control characters are rejected. Relative paths and `plugin:` destinations retain the non-HTTP visual classification but remain inert. Same-document footnote/fragment links alone retain in-WebView navigation. Raw `file:` URLs are sanitized away rather than treated as an alias for the Codex absolute-path form.

Ordinary links do not fetch or guess favicons. Rich v2 results may request only an explicitly named bundled favicon asset from the closed allowlist; any other brand icon falls back to deterministic local renderer SVG.

Source citations are separate. Only a parenthesized source-like HTTP(S) reference such as `([AP News][1])` is promoted to an inline citation pill. A concrete group such as `([AP News][1], [Reuters][2])` becomes the first source plus `+1` while retaining a focusable supporting-source list in preview. If copied text literally says `AP News +1` but exposes only one URL, Scopy may preserve that count but must not invent a supporting destination. A normal `([guide][1])`, local path, or Codex file link remains ordinary. Saved WACZ text can prove label survival, not this final citation DOM or its computed layout; those require current renderer tests or a labeled live inspection.

Task rows do not depend on WebKit's platform checkbox tint. The parsed disabled checkbox supplies checked state; Scopy paints one checked/unchecked marker path so preview and PNG use identical geometry and colors.

Every pipe table uses one table model:

- `.scopy-chatgpt-table-container` owns local horizontal scrolling;
- `.scopy-chatgpt-table-wrapper` is `width: fit-content`, has the current thread width as its minimum, and is centered inside the full-width scrolling container;
- table text is 14/24px;
- header cells are weight 600, line-height 16px, and have 8px block padding;
- body cells have 10px block padding;
- non-final columns have 24px end padding;
- the last body row removes its bottom border and keeps 24px bottom padding;
- cell text uses `word-break: normal` and `overflow-wrap: anywhere`;
- table-local overflow never requests a wider Swift hover popover.

Column bucket thresholds are based on text length:

| Length | Bucket | Min/max width as fraction of thread max width |
| ---: | --- | --- |
| `<= 40` | `sm` | 4/24 to 6/24 |
| `41...100` | `md` | 6/24 to 8/24 |
| `101...160` | `lg` | 8/24 to 12/24 |
| `> 160` | `xl` | 14/24 to 18/24 |

There is no `xs` bucket for ordinary Markdown pipe tables and no separate two-column/wide-table renderer. Horizontal overflow is the natural result of the same model at a narrow viewport.

An unescaped pipe remains a real delimiter. The captured edge corpus visibly loses the geometric-series condition `(|r|<1)` after the opening `(`; the strongest explanation is the unescaped `|r|` inside a pipe table. Correct source is `\lvert r\rvert < 1` or an escaped pipe. The renderer must not guess that a syntactic table delimiter was intended as math.

## Width, Scale, and Overflow

Scopy separates layout width, display fit, and bitmap export:

- fixed preview/PNG output surface: 816px;
- content inline padding: 24px per side;
- default thread max width: 40rem / 640px;
- wide thread max width: 48rem / 768px when the logical layout viewport is at least 856px; Scopy resolves this from `816 / scale` while building the document because a CSS media query would observe only the narrower physical WKWebView;
- ordinary answer blocks and short tables are centered on that thread column;
- ordinary text and inline code: `overflow-wrap: anywhere; word-break: normal`;
- code, KaTeX display, and tables own local horizontal overflow;
- images are constrained to the content width.

The user-selected ChatGPT layout scale is clamped to 80...200%. The output pixel surface remains fixed. Layout occurs in an internal viewport of `816 / scale`, then WebKit-style visual zoom maps it back to the fixed surface. This causes real reflow before display scaling; it must not reuse line breaks from another scale or enlarge the PNG canvas to simulate zoom.

Preview fit-to-popover scaling is display-only. It must not change the internal Markdown viewport, table baseline, cache key, or PNG target width.

The current production document is the captured light-theme branch. The WACZ contains light/dark token code paths but no hydrated theme class or final computed style. Do not invent a dark palette from asset presence alone; dark-mode parity remains a separately capturable/visually verifiable extension.

## Unicode, RTL, and Large Input

- UTF-8 source passes through without normalization, truncation, or grapheme rewriting.
- CJK, Arabic, Hebrew, Devanagari, Hangul, combining marks, variation selectors, ZWJ emoji, and skin-tone sequences are preserved as characters.
- the answer root uses `dir="auto"`; list, quote, footnote, citation, and link spacing uses logical inline properties so RTL layout mirrors correctly.
- formula hosts force `direction: ltr` and `unicode-bidi: isolate` so surrounding RTL text does not reorder mathematical syntax.
- the captured flat text proves character survival, not Arabic shaping, bidi visual order, emoji baseline, caret movement, or computed fallback font.
- a 100,000-character unbroken token is not truncated by the renderer; CSS handles wrapping outside preformatted code.
- ZWJ has real emoji coverage in the captured text. ZWSP and NBSP are named but were not actually present as independent test characters; ZWNJ was not independently tested.
- ASCII-art first-line indentation seen in flattened text cannot be attributed to source or renderer because the text extractor may trim the first line. Visual monospace alignment requires a real DOM/screenshot test.

## Preview and Export Stability

Preview and export consume the same parse result, standalone HTML, base CSS, renderer bundle, rich-interaction runtime, KaTeX CSS/fonts, syntax-highlighting output, and bundled rich assets. All resources are local and network access is neither required nor permitted for rendering. Preview hydrates supported controls; export freezes those same controls in the envelope-selected initial state before capture.

Each WebView load receives a new opaque render ID inserted into `data-scopy-render-id`. Every size/readiness message must carry that ID. Scopy accepts a message only when:

- it comes from the main frame;
- its render ID matches the current load;
- the navigation belongs to the current load.

Metric deduplication compares width, height, horizontal-overflow state, success/failure state, error reason, and render ID. A same-size failure cannot be swallowed as a duplicate success, and a late message from an earlier document cannot resize or mark the new preview ready.

The document remains hidden until the renderer, KaTeX, highlighting, task/table/rich runtime, local fonts/assets, and layout measurement reach a terminal ready state. Renderer failure is reported as failure; it does not silently switch engines.

PNG export builds the same HTML off the main thread, then owns WebKit work on the main actor. Its PDF, one-shot snapshot, and tiled snapshot paths are reliability strategies for one frozen DOM, not alternate renderers. The export freeze closes transient overlays/tooltips, disables rich controls and links, removes them from the tab order, and cancels activation. Export-only code wrapping or table scaling may run only after preview-equivalent layout is ready and only to fit bitmap constraints; it may not change Markdown parsing, typography, content width, table/card models, or frozen source data.

## Edge-case Acceptance Matrix

| Family | Required behavior |
| --- | --- |
| single vs double tilde | single literal; double deletion |
| `$` currency/shell/math ambiguity | single-dollar literal; explicit backslash/double-dollar/fence math only |
| code syntax islands | no Markdown/math repair inside inline/fenced/indented code |
| nested fences | longer outer fence preserves shorter inner fence text |
| raw HTML/script | visible escaped source; no executable element |
| escaped table pipe | remains in the cell |
| unescaped table pipe | splits cells; source author must escape or use LaTeX delimiters |
| empty/aligned/wide tables | semantic cells preserved; one column model; local horizontal overflow |
| tasks | checked and unchecked state preserved and disabled |
| footnotes and repeated refs | one `scopy-` ID namespace; every fragment target exists |
| ordinary, Codex file, and source links | only explicit source-like parenthesized HTTP(S) links become citation pills; Codex absolute paths preserve `:line` and remain local |
| CJK/RTL/combining/emoji | exact character preservation; visual shaping requires WebView verification |
| long unbroken text | no renderer truncation; `anywhere` wrapping outside code |
| long code/math/table | local overflow rather than page/popover width mutation |
| KaTeX parse failure | strict warning, relaxed retry, then literal error surface |
| stale WebView message | ignored by render ID/navigation/main-frame gates |
| same-size failure | delivered because outcome/error participates in deduplication |
| preview vs PNG | identical parse result, HTML, base CSS, local assets, and runtime; preview hydrates, export freezes before capture |
| `scopy-rich` validity | strict v2 object renders a supported card; every other version and invalid/unknown/oversized input remains a code fence |
| rich state | zero, empty, partial, missing `—`, and error remain visibly distinct |
| rich image source | allowlisted asset renders bundled bytes; remote URL never fetches; unknown or ambiguous asset/source input invalidates the envelope |
| rich interaction | weather/day, finance/range, currency, chart, and local-image controls use only pre-rendered frozen data; export disables all actions |
| rich identity/a11y/RTL | content-derived stable IDs, labeled semantics, LTR numeric isolation, and local overflow |

The primary archived page exercised 103 broad edge families. Its saved-text evidence directly supports escape preservation, code preventing secondary parsing, nested fences, raw-HTML literalization, combining/emoji character survival, and no long-content truncation. It directly exposes only one parser/source failure: the unescaped `|r|` table case. Final DOM semantics, checkbox paint, RTL visual ordering, exact wrapping, and actual overflow remain unprovable from that WACZ alone.

## Required Verification

After renderer or preview/export changes:

```bash
cd Tools/MarkdownRenderer
npm test
npm run build

cd ../..
make build
make test-unit
make test-strict
scripts/perf-frontend-profile.sh --include-hover
make docs-validate
git diff --check
```

Focused renderer assertions live in:

- `Tools/MarkdownRenderer/test/chatgpt-wacz-20260828.test.js`
- `Tools/MarkdownRenderer/test/render.test.js`
- `ScopyTests/ChatGPTMarkdownRendererTests.swift`
- `ScopyTests/WebViewLifecycleTests.swift`

Real user fixtures, rich-surface provenance, and strict v2 examples live in:

- `ScopyUITests/Fixtures/user_markdown_stress.md` (the complete 2,728-line Markdown/math/table/Unicode stress input)
- `ScopyUITests/Fixtures/chatgpt_rich_copy_sample.md` (copied visible text; ordinary-Markdown degradation, never synthesized cards)
- `ScopyUITests/Fixtures/chatgpt_rich_surfaces.md`
- `ScopyUITests/Fixtures/README.md`

Whole-fixture Node coverage is in `Tools/MarkdownRenderer/test/user-fixtures.test.js`. Real-app PNG export cases are in `ScopyUITests/ExportMarkdownPNGUITests.swift`; failure to enable the macOS UI automation harness is environment-blocked and cannot be counted as a pass.

A screenshot can verify the currently rendered geometry, but it cannot redefine parser semantics or replace the source-derived contract. Dark, narrow, and preview-versus-export golden-image coverage should be added only with an isolated harness that does not mutate the user's general pasteboard.
