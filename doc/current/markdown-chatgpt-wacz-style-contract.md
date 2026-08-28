# ChatGPT-aligned Markdown Rendering Contract

This is the canonical contract for Scopy Markdown preview and PNG export. It records what the 2026-08-28 ChatGPT WACZ proves, where the archive is incomplete, and the single local implementation that Scopy must keep stable.

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

Therefore this contract distinguishes three evidence levels:

| Level | Meaning |
| --- | --- |
| Captured runtime path | Exact parser option, component branch, CSS declaration, or render function exists in the archived code. |
| Saved-text observation | Characters survived into archived page text; DOM and visual layout remain unknown. |
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
| Table component | `0606_chatgpt.com__cdn_assets_table-components-b39fqymt.css.css` plus JS matches for `data-col-size` | local horizontal scroll, measured column buckets, `fit-content`, and `min-width: 100%`. |

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
- `Tools/MarkdownRenderer/src/rehypeScopyKatex.js`: HTML-only math rendering and stable failure behavior.
- `Scopy/Views/History/MarkdownPreviewWebView.swift`: generation-safe WebView lifecycle and metrics.
- `Scopy/Services/Export/MarkdownExportService.swift`: PNG reliability strategies applied to the same HTML.

There is no legacy renderer selection, feature flag, shadow renderer, silent markdown-it fallback, or second preview/export parse result. Missing renderer assets are a render failure, not permission to display a semantically different document.

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
| Links/images/autolinks | Parsed by CommonMark/GFM, then sanitized. `http`, `https`, normal relative/local paths, and the explicit local `plugin:` integration path are preserved according to the sanitizer schema. |
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
- source-citation promotion requires explicit source-like parenthesized HTTP(S) references; normal links are not restyled as citations.

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

Ordinary links inherit primary text color and use a dotted secondary underline plus the local export-friendly arrow. They are non-interactive inside preview/export.

Source citations are separate. Only a parenthesized source-like HTTP(S) reference such as `([AP News][1])` is promoted to an inline citation pill. A group such as `([AP News][1], [Reuters][2])` becomes the first source plus `+1`. A normal reference such as `([guide][1])` remains an ordinary link.

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

Preview and export consume the same standalone HTML, CSS, renderer bundle, KaTeX CSS/fonts, and syntax-highlighting output. All resources are bundled locally and network access is not required.

Each WebView load receives a new opaque render ID inserted into `data-scopy-render-id`. Every size/readiness message must carry that ID. Scopy accepts a message only when:

- it comes from the main frame;
- its render ID matches the current load;
- the navigation belongs to the current load.

Metric deduplication compares width, height, horizontal-overflow state, success/failure state, error reason, and render ID. A same-size failure cannot be swallowed as a duplicate success, and a late message from an earlier document cannot resize or mark the new preview ready.

The document remains hidden until the renderer, KaTeX, highlighting, task/table runtime, fonts, and layout measurement reach a terminal ready state. Renderer failure is reported as failure; it does not silently switch engines.

PNG export builds the same HTML off the main thread, then owns WebKit work on the main actor. Its PDF, one-shot snapshot, and tiled snapshot paths are reliability strategies for one DOM, not alternate renderers. Export-only code wrapping or table scaling may run only after preview-equivalent layout is ready and only to fit bitmap constraints; it may not change Markdown parsing, typography, content width, or table model.

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
| ordinary vs source links | only explicit source-like parenthesized links become citation pills |
| CJK/RTL/combining/emoji | exact character preservation; visual shaping requires WebView verification |
| long unbroken text | no renderer truncation; `anywhere` wrapping outside code |
| long code/math/table | local overflow rather than page/popover width mutation |
| KaTeX parse failure | strict warning, relaxed retry, then literal error surface |
| stale WebView message | ignored by render ID/navigation/main-frame gates |
| same-size failure | delivered because outcome/error participates in deduplication |
| preview vs PNG | identical parse result and base CSS; export adaptation only after readiness |

The archived page exercised 103 broad edge families. Saved-text evidence directly supports escape preservation, code preventing secondary parsing, nested fences, raw-HTML literalization, combining/emoji character survival, and no long-content truncation. It directly exposes only one parser/source failure: the unescaped `|r|` table case. Final DOM semantics, checkbox paint, RTL visual ordering, exact wrapping, and actual overflow remain unprovable from this WACZ alone.

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

A screenshot can verify the currently rendered geometry, but it cannot redefine parser semantics or replace the source-derived contract. Dark, narrow, and preview-versus-export golden-image coverage should be added only with an isolated harness that does not mutate the user's general pasteboard.
