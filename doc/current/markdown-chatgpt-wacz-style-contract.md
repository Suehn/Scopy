# ChatGPT WACZ Markdown Rendering Contract

This document is the source-derived model for Scopy's ChatGPT-aligned Markdown preview and PNG export path. It exists to prevent screenshot-driven fixes: when WACZ, live DOM, Scopy preview, and export disagree, this contract defines the evidence order, the rendering layers, and which part of Scopy is allowed to adapt each layer.

## Evidence Priority

Use evidence in this order:

1. WACZ conversation JSON is the semantic source for Markdown input examples.
2. WACZ extracted JS and CSS chunks are the source for component structure, cascade, table-column sizing, and responsive width formulas.
3. Scopy implementation files show how the official model is adapted into local WKWebView preview and PNG export.
4. Live `chatgpt.com` DOM metrics can confirm whether the product has drifted after the WACZ capture. They must not override WACZ source evidence unless a new capture is recorded.
5. Screenshots are visual verification only. They are not the source for constants, thresholds, or layout rules.

Current primary capture:

- WACZ archive: `/Users/ziyi/Downloads/ui-全面.wacz`
- Regenerated local extraction: `/tmp/scopy-wacz-extract/ui-full-20260607-doc-model`
- Conversation JSON: `/tmp/scopy-wacz-extract/ui-full-20260607-doc-model/0020_chatgpt.com__backend-api_conversation_6a1a5353-d0fc-83ea-a133-d2a21add48bb.json`
- Assistant Markdown: `/tmp/scopy-wacz-extract/ui-full-20260607-doc-model/assistant-message.md`
- All assistant Markdown messages: `/tmp/scopy-wacz-extract/ui-full-20260607-doc-model/assistant-messages`
- Model summary: `/tmp/scopy-wacz-extract/ui-full-20260607-doc-model/wacz-markdown-rendering-model.md`
- CSS/JS evidence index: `/tmp/scopy-wacz-extract/ui-full-20260607-doc-model/relevant-css-js-lines.txt`
- CSS/JS pattern coverage: `/tmp/scopy-wacz-extract/ui-full-20260607-doc-model/markdown-css-js-coverage.json`
- Current component JS evidence: `/tmp/scopy-wacz-extract/ui-full-20260607-doc-model/0293_chatgpt.com__cdn_assets_98bbfa68-hicd499v3j2r4yyb.js.js`
- Current AssistantMessage component CSS: `/tmp/scopy-wacz-extract/ui-full-20260607-doc-model/0303_chatgpt.com__cdn_assets_AssistantMessage-6zxhctcg.css.css`
- Current root Markdown CSS: `/tmp/scopy-wacz-extract/ui-full-20260607-doc-model/0499_chatgpt.com__cdn_assets_root-n0p757yt.css.css`
- Current breakout table CSS: `/tmp/scopy-wacz-extract/ui-full-20260607-doc-model/0503_chatgpt.com__cdn_assets_table-components-ca43bz4f.css.css`

Regenerate the extraction with:

```bash
python3 scripts/quality/analyze-chatgpt-wacz-markdown.py /Users/ziyi/Downloads/ui-全面.wacz --out-dir /tmp/scopy-wacz-extract/ui-full-20260607-doc-model --force
```

The script parses the WARC directly and extracts response/resource bodies, every assistant Markdown message, CSS/JS evidence lines, CSS/JS pattern coverage, and table inventory. Treat the generated inventory as an audit aid, not as a higher authority than WACZ JS/CSS. If the script summary ever disagrees with extracted JS, fix the script and regenerate before updating this contract.

## Completeness Audit

For the current WACZ, "no omission" is scoped to content that exists inside `/Users/ziyi/Downloads/ui-全面.wacz`, not to future ChatGPT deployments or runtime network state outside the archive.

The regenerated extraction proves:

| Audit item | Current evidence |
| --- | --- |
| WARC records counted | `{"request": 551, "resource": 2, "response": 546, "revisit": 5, "warcinfo": 1}` |
| Content bodies extracted | 548 `response`/`resource` bodies |
| Non-extracted WARC types | `request`, `revisit`, and `warcinfo`; these are counted but are not response/resource bodies |
| Resource records | 2 PNG visual resources: WACZ thumbnail and view image |
| Conversation JSON files | 4 extracted JSON responses under `/backend-api/conversation/` |
| Assistant Markdown messages | 1 total, written under `assistant-messages/` and mirrored as `assistant-message.md` for compatibility |
| Markdown pipe tables | 6 total across all assistant Markdown messages |
| CSS files | 30 extracted CSS files |
| JS files | 431 extracted JS files |
| Markdown-related CSS/JS coverage | 267 CSS/JS files matched at least one tracked Markdown/rendering pattern |

The primary Markdown model and the all-assistant model are the same for this WACZ because there is only one assistant Markdown message. That is an evidence-backed property of this archive, not an assumption baked into the parser.

The coverage audit is intentionally broader than the style contract. It counts patterns such as `.markdown`, `.prose`, `markdown-new-styling`, `wrap-break-word`, `blockquote`, `code`, `pre`, `hljs`, `katex`, `citation`, `webpage-citation-pill`, `task`, `checkbox`, `table`, `TableContainer`, `TableWrapper`, `Jc7teW`, `TyagGW_tableContainer`, `thread-content`, `min-w-(--thread-content-width)`, and `data-col-size`. These counts identify files that require manual review; they do not automatically make every matching file part of the Scopy model.

This contract is complete for the captured Markdown rendering surface when:

- every content-bearing WARC record is extracted or explicitly counted as non-content metadata
- every conversation JSON and assistant Markdown message is enumerated
- all assistant Markdown tables are inventoried
- all CSS/JS assets are preserved on disk
- Markdown-related CSS/JS pattern coverage is generated
- the contract explains which evidence becomes a Scopy rendering invariant and which evidence remains audit context

## Principle Model

The ChatGPT Markdown renderer is not one stylesheet applied to a static HTML blob. It is a layered system:

| Layer | ChatGPT source | Scopy adaptation |
| --- | --- | --- |
| Semantic input | Conversation JSON message parts | Markdown source enters Scopy renderer after source-profile routing |
| Parse normalization | ChatGPT parser/editor pipeline behavior, inferred from rendered output and source chunks | Shared pre-parse normalizers for ATX headings, table-row inline-code pipes, source citations, safe HTML placeholders, and CJK emphasis |
| Root Markdown surface | `markdown prose ... wrap-break-word ... markdown-new-styling` root | `#content` and non-table direct children emulate the root typography and text wrapping |
| Component islands | TableContainer, code card, source citation pill, task row components | Scopy emits equivalent local classes and data attributes instead of copying obfuscated class names |
| Responsive layout | CSS variables such as `--thread-content-max-width`, `--thread-content-width`, component baselines, and container-query behavior | Fixed PNG/preview visual surface plus scale-specific internal layout viewport |
| Runtime measurement | React component JS, especially table column measurement | Local JS wraps tables, measures text columns, and assigns local data attributes before preview/export readiness |
| Export adaptation | Not part of ChatGPT web UI | PNG-only transform layer after the preview-equivalent layout has completed |

Two rules follow from this model:

- If a bug is caused by parse semantics, fix the pre-parse/shared renderer path. CSS cannot repair the wrong DOM.
- If a bug is caused by preview/export adaptation, fix the Scopy boundary. Do not change the WACZ-equivalent component model to hide export or popover constraints.

## Scopy Implementation Map

The current implementation surfaces are:

- `Scopy/Views/History/MarkdownHTMLDocumentBuilder.swift`: builds the preview/export HTML, root CSS variables, ChatGPT-like CSS, table wrapper JS, table column sizing, preview fit scale, and export table scaling hook.
- `Scopy/Services/Export/MarkdownRenderLayoutConstants.swift`: defines allowed layout-scale values, fixed visual surface width, content padding, and scale-to-layout viewport mapping.
- `Scopy/Services/Export/MarkdownExportService.swift`: prepares WKWebView output and invokes the export-only table scaling hook after layout.
- `Scopy/Views/History/UnifiedMarkdownRenderer.swift`: unified Markdown rendering bridge.
- `Scopy/Views/History/MarkdownTaskListRuntime.swift`: task-list checkbox-to-painted-marker runtime.
- `scripts/quality/analyze-chatgpt-wacz-markdown.py`: WACZ extraction and evidence inventory helper.
- `ScopyTests/KaTeXRenderToStringTests.swift`: focused contract assertions for ChatGPT table layout, width model, scale model, and table/export boundaries.

When changing behavior, update the contract and tests in the same direction. A local class name such as `.scopy-chatgpt-table-container` is acceptable only when its geometry and lifecycle are mapped to the captured official component.

## Source Model

The rendered assistant Markdown root uses:

```text
markdown prose dark:prose-invert wrap-break-word w-full light markdown-new-styling
```

The light/dark class changes with theme, but `markdown-new-styling` remains the authoritative root branch for heading rhythm, paragraph rhythm, list rhythm, blockquotes, and ordinary root Markdown table rules. The older AssistantMessage class family, including `qN-_1G_MarkdownContent`, is evidence only when the current DOM still emits that component path.

The root CSS and component CSS can both contain table rules. They are not interchangeable:

- Root `.markdown table` rules describe native Markdown table styling under the root cascade.
- Current TableContainer component rules describe the interactive measured table path with wrapper scroll, `fit-content`, `data-col-size`, and fixed component baselines.
- Scopy uses the root Markdown pipe-table sizing model for ordinary Markdown tables. It keeps a local scroll wrapper for preview/export containment, but that wrapper must not switch pipe tables onto the component `xs`/baseline model.

## Width And Wrapping

ChatGPT does not use one fixed text width at every viewport. The breakout table component capture defines the responsive content model:

```text
--thread-content-width: min(
  calc(100cqw - 2 * var(--thread-content-margin, 0)),
  var(--thread-content-max-width)
)
--thread-gutter-size: calc((100cqw - var(--thread-content-width)) / 2)
```

Live inspection of the same product family showed a smaller branch around `40rem` and a larger branch around `48rem`. That proves the official renderer is responsive. It does not justify post-layout bitmap scaling, canvas growth, or reusing line breaks from another scale.

Scopy mirrors the principle while keeping output size separate from layout scale:

- the visual preview/PNG surface is fixed at `816px` when screen space allows it
- the desktop message content branch is `48rem` / `768px`
- safe inline padding is `24px` on each side
- the default `100%` profile lays out in an `816px` internal viewport
- a non-100% profile lays out in an internal viewport of `816px / scale`
- WebKit visual scaling then maps that layout back onto the fixed surface
- the active text column is `min(768px, renderWidth - 48px)` where `renderWidth` is the internal layout viewport before zoom
- the layout scale is part of the render context and cache key
- the hover-preview frame is owned by Scopy's shared preview-frame policy, not Markdown content width
- live preview may fit-scale the already-laid-out surface into the shared popover frame; that fit scale is display-only
- WebView measurement may update height and overflow state, but must not shrink or grow the outer Markdown popover
- normal text wrapping follows `wrap-break-word`: `overflow-wrap: break-word` with `word-break: normal`

This is the main distinction between preview and export:

- Preview must look like ChatGPT at the chosen layout profile inside Scopy's preview shell.
- PNG export must start from that same layout and then may apply export-only scaling for bitmap constraints.
- Export may not substitute a different table stylesheet, different text column, or different Markdown parse result.

## Typography Rhythm

Measured from the WACZ rendered `markdown-new-styling` DOM:

| Element | Font | Line height | Weight | Margins |
| --- | --- | --- | --- | --- |
| root | 16px | 26px | 400 | 0 |
| h1 | 24px | 32px | 600 | bottom 8px |
| h2 | 20px | 28px | 600 | top 16px, bottom 4px |
| h3 | 18px | 28px | 600 | top 16px, bottom 4px |
| h4 | 16px | 24px | 600 | top 16px, bottom 0 |
| h5 | 16px | 26px | 600 | 0 |
| h6 | 16px | 26px | 400 | 0 |
| p | 16px | 26px | 400 | 8px top, 4px bottom; adjacent paragraphs use 16px block separation |

Do not fall back to the older AssistantMessage heading scale unless a new WACZ capture proves the DOM has changed again.

## Markdown Input Normalization

Scopy normalizes input before both legacy and unified renderers where ChatGPT behavior depends on parse semantics:

- `#标题` becomes `# 标题`
- `##标题` becomes `## 标题`
- valid ATX headings are unchanged
- fenced and indented code blocks are unchanged
- shebang-like lines such as `#! /usr/bin/env bash` are unchanged
- table-row one- or two-backtick inline code spans escape their internal unescaped `|`
- table-row runs of three or more backticks are treated as fence-marker examples inside cells, not as inline code spans
- source-reference citations are promoted only when the reference shape and URL prove citation intent

The parser boundary is strict. A malformed heading or exploded table row must be fixed before Markdown parsing; CSS must not be used to mimic the correct visual output after the DOM is already wrong.

## Inline Code

Inline code uses the root `.prose :where(code)` contract:

- color: root text `rgb(13, 13, 13)`
- background: alpha-04 in light mode
- inset 1px alpha-08 stroke
- radius: 4px
- padding: `0.15rem 0.3rem`
- font size: `0.875em`; in a 16px paragraph this computes to 14px
- font weight: 500
- line height: inherit
- wrapping remains normal with `overflow-wrap: break-word`

Heading-contained code is still inline code. Do not strip the pill from `h1 code`, `h2 code`, or other heading code spans.

## Code Blocks

Code blocks use the ChatGPT rounded code-card surface:

- border radius: 24px
- border: 1px solid light border
- background: neutral alpha surface
- top language label area before code text
- monospace font from the captured `ui-monospace, SFMono-Regular, ...` stack
- language labels are display chrome and are not reusable Markdown content

Syntax coloring is language-dependent and comes from WACZ root stylesheet token colors, not a hand-picked Scopy palette.

The shared preview/export theme maps `hljs` output onto the captured CodeBlock semantic colors:

| Semantic token | Color |
| --- | --- |
| base | `rgb(13, 13, 13)` |
| comment | `#4f4f4f` |
| meta/tag | `#004f99` |
| keyword | `#ba437a` |
| heading/attribute | `#ba8e00` |
| atom/standard-name | `#b9480d` |
| string | `#008635` |
| name | `#6b3ab4` |
| invalid | `#ba2623` |

Both legacy `markdown-it` and unified `rehype-highlight` must emit or preserve `hljs` token classes before export readiness flips. PNG export waits for the same rendered DOM state as preview.

## Links And Source Citations

Ordinary Markdown links remain text links:

- text color inherits the primary text color
- underline style is dotted with `rgb(143, 143, 143)`
- the local export surface appends the external-link arrow for normal links

ChatGPT source citations are a separate visual component. The captured `AP News` citation uses an inline wrapper with `data-testid="webpage-citation-pill"` and a nested source anchor:

- wrapper display: `inline-flex`
- wrapper margin-left: 4px
- wrapper top offset: `-0.094rem`
- anchor display: `flex`
- anchor height: 18px
- anchor padding: `0 8px`
- anchor font-size: 9px
- anchor color: `rgb(93, 93, 93)`
- anchor background: `rgb(244, 244, 244)`
- anchor border-radius: 12px
- no underline and no external-link arrow

Scopy may promote Markdown source-reference syntax to the same visual class only when the source carries explicit citation semantics, such as `([AP News][1])` plus a `[1]: https://...` definition. It must not rewrite ordinary parenthesized links such as `([guide][1])`. A grouped citation such as `([AP News][1], [Reuters][2])` collapses to the first source with `data-scopy-source-count="+1"` so the visible form follows ChatGPT's single-pill `AP News +1` shape.

## Blockquotes

Blockquotes use the root Markdown rule:

- margin: 0, with `markdown-new-styling` bottom rhythm
- padding: `8px 0 8px 24px`
- line-height: 24px
- no traditional border
- a 4px rounded quote bar is absolutely positioned from 8px top to 8px bottom
- quote text remains weight 400 and inherits normal text color

## Lists And Tasks

- `ul` and `ol` use zero block margin and 26px left padding.
- nested lists retain the same local padding model.
- normal list markers are bold and current-color in the captured DOM.
- task lists do not rely on native checkbox rendering.
- Scopy paints one marker path so preview and export share the same checked/unchecked geometry and colors.

## Table System

Markdown pipe tables use the WACZ root Markdown table path. There is still no separate "standard table" versus "wide table" heuristic branch: every pipe table receives the same root Markdown column-size model, and overflow is the natural result when the measured table is wider than the active content area.

The WACZ also contains a separate TableContainer/component path. That path is real official evidence, but it is not the default path for ordinary Markdown pipe tables in Scopy.

### Official Component Structure

The current WACZ JS defines these component classes:

| Component | WACZ class | Role |
| --- | --- | --- |
| table container | `Jc7teW_TableContainer` | horizontal scroll owner and component baseline owner |
| table wrapper | `Jc7teW_TableWrapper` | `fit-content` wrapper with `min-width: 100%` |
| table | `Jc7teW_Table` | measured table surface |
| row | `Jc7teW_Row` | `tr`, plus `data-w-header-row` for header rows |
| cell | `Jc7teW_Cell` | `td`, plus `data-col-size` |

Scopy maps those concepts to local names:

| ChatGPT concept | Scopy local class/attribute |
| --- | --- |
| TableContainer | `.scopy-chatgpt-table-container` |
| TableWrapper | `.scopy-chatgpt-table-wrapper` |
| column size | `data-col-size` plus local mirror `data-scopy-col-size` |
| export-scaled table marker | `data-scopy-table-scaled="true"` |

The name changes are intentional. The geometry and lifecycle must match; copying obfuscated class names is not required.

### Markdown Pipe-Table Measurement Lifecycle

The captured Markdown/rehype table plugin:

- walks rendered `table` nodes before HTML output
- measures text-node length in the header and body cells
- assigns `data-col-size` to each header/body cell
- assigns column sizes with `>160 -> xl`, `>100 -> lg`, `>40 -> md`, otherwise `sm`
- has no `xs` bucket for Markdown pipe tables

Scopy mirrors this path after local Markdown rendering by measuring the table DOM, assigning official `data-col-size`, and preserving a local `data-scopy-col-size` mirror for diagnostics.

### Official Component Measurement Lifecycle

The separate TableContainer component JS:

- renders cells with `data-col-size`
- measures `textContent.length` in table body rows during `useLayoutEffect`
- respects `colSpan` by distributing a spanned cell length across the covered column positions
- merges explicit column sizes when present
- keeps the table hidden until measurement is ready
- assigns column sizes with `>160 -> xl`, `>100 -> lg`, `>40 -> md`, `>4 -> sm`, otherwise `xs`

Do not apply this component-only `xs` bucket to ordinary Markdown pipe tables.

### Official Component CSS

The current AssistantMessage component CSS defines:

- container `--w-table-col-baseline: 640px`
- at `min-width: 1024px`, baseline becomes `768px`
- container `overflow-x: auto`
- inner wrapper `width: fit-content; min-width: 100%`
- table `border-collapse: separate; border-spacing: 0; table-layout: auto; border: 0; width: fit-content; min-width: 100%`
- cell base border: bottom 1px
- body cell padding block: `10px`
- header cell padding block: `8px`
- base cell padding inline: `8px`
- first cell start padding: `0`
- last cell end padding: `0`
- last row removes bottom border only

Column size ranges are fractions of the component baseline:

| Size | Text length rule | Min width | Max width |
| --- | ---: | ---: | ---: |
| `xs` | `<= 4` | `2 / 24` | `4 / 24` |
| `sm` | `> 4` | `4 / 24` | `6 / 24` |
| `md` | `> 40` | `7 / 24` | `9 / 24` |
| `lg` | `> 100` | `9 / 24` | `13 / 24` |
| `xl` | `> 160` | `14 / 24` | `18 / 24` |

This is why a table may overflow horizontally as the layout viewport narrows under browser zoom: the columns are constrained against a component baseline, not always squeezed into the current text column.

### Root Markdown Table Rules

The WACZ root stylesheet contains `.markdown table` rules with `data-col-size=sm/md/lg/xl` ranges based on `--thread-content-max-width`.

Column size ranges are fractions of the root thread content max width:

| Size | Text length rule | Min width | Max width |
| --- | ---: | ---: | ---: |
| `sm` | `<= 40` | `4 / 24` | `6 / 24` |
| `md` | `> 40` | `6 / 24` | `8 / 24` |
| `lg` | `> 100` | `8 / 24` | `12 / 24` |
| `xl` | `> 160` | `14 / 24` | `18 / 24` |

Use this distinction when debugging:

- If the DOM is a native Markdown table without the TableContainer component, root rules describe that surface.
- If the DOM has TableContainer measurement and component classes, component CSS wins for layout behavior.
- Scopy ordinary pipe tables must remain on the root Markdown model even though Scopy wraps them in a local scroll container.

### Scopy Preview Rules

Preview must:

- wrap every table in `.scopy-chatgpt-table-container > .scopy-chatgpt-table-wrapper`
- mark ordinary tables with `data-scopy-table-model="markdown-pipe"`
- assign official `data-col-size` and local mirror `data-scopy-col-size` to every visible cell
- never assign `xs` for Markdown pipe tables
- size Markdown pipe-table columns from `--scopy-chatgpt-thread-content-max-width`, not the narrowed current content width
- keep `.scopy-chatgpt-table-container` out of the overflow probe that widens the Swift hover popover
- preserve local horizontal scroll
- never transform-scale tables
- never switch to a separate stylesheet for two-column tables
- allow browser-zoom-like layout narrowing to produce horizontal overflow when the root Markdown column model requires it

### Scopy PNG Export Rules

PNG export must:

- start from the same DOM and CSS as preview
- invoke `window.__scopyScaleChatGPTTablesForExport` only after WACZ-equivalent layout has completed
- measure the laid-out table width
- apply a transform to the table surface only when it exceeds the bitmap target width
- reserve scaled height on the container to avoid clipping
- never change the Markdown parse result, text column, table model baseline, or cell padding to make the bitmap fit

This export layer is intentionally extra. It is not part of official ChatGPT rendering; it exists because Scopy exports a single PNG.

### Table Inventory From Current WACZ

The current `ui-全面.wacz` assistant Markdown contains six pipe tables:

| Start line | Columns | Data rows | Column sizes after fixed analyzer | Max cell text lengths |
| ---: | ---: | ---: | --- | --- |
| 256 | 3 | 5 | `sm, xs, sm` | `8, 4, 12` |
| 268 | 3 | 3 | `sm, sm, xs` | `6, 6, 4` |
| 278 | 3 | 5 | `xs, sm, sm` | `4, 25, 25` |
| 290 | 16 | 10 | `xs, xs, sm, sm, sm, sm, sm, sm, sm, xs, sm, sm, sm, sm, sm, xs` | `2, 4, 11, 13, 9, 10, 9, 11, 7, 4, 7, 12, 28, 21, 17, 4` |
| 463 | 2 | 19 | `sm, sm` | `7, 11` |
| 489 | 2 | 8 | `sm, sm` | `8, 37` |

Do not use naive pipe counts for table analysis. Escaped pipes and pipes inside one- or two-backtick inline code spans must not create columns, while fence-marker examples such as ```` ```python ```` remain cell text and still split at real table delimiters.

## Preview/Export Boundary Checklist

Use this checklist before changing Markdown preview/export:

- Does the source Markdown parse to the same semantic structure on legacy and unified paths?
- Does the root surface still use `wrap-break-word` semantics?
- Does the active layout scale cause reflow before visual scaling?
- Is the Swift popover width independent from Markdown line breaking?
- Are all pipe tables on the root Markdown pipe-table model?
- Are table column sizes based on text length and `thread-content-max-width`, not current content width?
- Is table overflow local to the table scroll container in preview?
- Is any transform scaling limited to PNG export after layout?
- Are code, task-list, citation, and table component rules shared between preview and export where applicable?
- Did tests assert the absence of old heuristics, not only the presence of new CSS?

## Known Drift Risks

- Obfuscated WACZ class names can change without changing behavior. Prefer behavior and CSS declarations over class-name stability.
- Root Markdown table rules and component TableContainer rules can coexist. Do not collapse them into one mental model.
- The WACZ analyzer is a helper. It must be kept aligned with extracted JS thresholds.
- Live ChatGPT can ship a new renderer after this WACZ. Refresh WACZ before changing constants.
- Browser zoom, Scopy layout scale, live preview fit scale, and PNG export scale are different layers. Mixing them is the common source of "looks like ChatGPT at 100% but diverges at 145%" bugs.

## Verification Matrix

| Change type | Required checks |
| --- | --- |
| WACZ evidence or analyzer logic | Regenerate WACZ model, inspect CSS/JS evidence lines, run `make docs-validate` |
| Markdown parse normalization | Node renderer tests and focused Swift renderer tests |
| Table layout or table CSS | `KaTeXRenderToStringTests/testMarkdownTableUsesChatGPTStyleWithExistingOverflowSupport` plus preview/export visual smoke when behavior changes |
| Layout scale or preview shell | `MarkdownPreviewRendererFacadeTests`, hover-preview tests, and a scale-specific preview smoke |
| PNG export adaptation | focused export UI tests for wide table/global-scale behavior |
| Documentation-only edits | `make docs-validate` and `git diff --check` |
