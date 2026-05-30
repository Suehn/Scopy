# ChatGPT WACZ Markdown Style Contract

This document records the source-derived rendering contract used by Scopy's ChatGPT-aligned Markdown preview and export path.

## Evidence Priority

1. WACZ conversation JSON is the semantic source for Markdown input examples.
2. WACZ extracted CSS and JS chunks are the source for cascade, component classes, table-column sizing, and responsive width formulas.
3. Live `chatgpt.com` DOM metrics are used to confirm the current product surface and responsive behavior. They must not override archived source evidence unless the capture is refreshed.
4. Browser screenshots are visual verification only. They are not the source for changing constants.

Current primary captures:

- `/Users/ziyi/Downloads/ui-全面.wacz`
- `/tmp/scopy-wacz-extract/ui-full-20260530-script/wacz-markdown-rendering-model.json`
- `/tmp/scopy-wacz-extract/ui-full-20260530-script/assistant-message.md`
- `/tmp/scopy-wacz-extract/ui-full-20260530-script/relevant-css-js-lines.txt`
- `/tmp/scopy-wacz-extract/ui/0035_chatgpt.com_backend-api_conversation_6a19ad01-18d8-83ea-b945-71f803842646.json`
- `/tmp/scopy-wacz-extract/ui/0121_chatgpt.com_c_6a19ad01-18d8-83ea-b945-71f803842646.html`
- `/tmp/scopy-wacz-extract/ui/1114-root-l30w6n1j.css`
- `/tmp/scopy-wacz-extract/ui/0676-AssistantMessage-6zxhctcg.css`
- `/tmp/scopy-wacz-extract/ui-表格超宽2/0169_chatgpt.com_backend-api_conversation_6a19f0d5-06c4-83ea-bddc-a2068f6bbc2f.json`
- `/tmp/scopy-wacz-extract/ui-表格超宽2/1182-root-gqg5932l.css`
- `/tmp/scopy-wacz-extract/ui-表格超宽2/0766-AssistantMessage-6zxhctcg.css`
- `/tmp/scopy-wacz-extract/ui-full-20260530/summary.json`
- `/tmp/scopy-wacz-extract/ui-full-20260530/0496_chatgpt.com_cdn_assets_root-n0p757yt.css.css`
- `/tmp/scopy-wacz-extract/ui-full-20260530/0500_chatgpt.com_cdn_assets_table-components-ca43bz4f.css.css`
- `/tmp/scopy-wacz-extract/ui-full-20260530/0300_chatgpt.com_cdn_assets_AssistantMessage-6zxhctcg.css.css`

Use `scripts/quality/analyze-chatgpt-wacz-markdown.py /Users/ziyi/Downloads/ui-全面.wacz --out-dir /tmp/scopy-wacz-extract/ui-full-20260530-script --force` to regenerate the current local extraction. The script parses the WARC directly and its table inventory ignores escaped pipes and pipes inside code spans; it also treats table-cell fence-marker examples such as ```` ```python ```` as text markers rather than as row-spanning code spans.

## Source Model

The rendered assistant Markdown root uses:

```text
markdown prose dark:prose-invert wrap-break-word w-full light markdown-new-styling
```

The light/dark class changes with theme, but `markdown-new-styling` remains the authoritative branch for heading rhythm, paragraph rhythm, table rules, and root wrapping. The older AssistantMessage class family, including `qN-_1G_MarkdownContent`, is kept only for component-specific details when the root DOM still emits those components.

## Width And Wrapping

ChatGPT does not use one fixed text width at every viewport. The table component capture defines the core width model:

```text
--thread-content-width: min(
  calc(100cqw - 2 * var(--thread-content-margin, 0)),
  var(--thread-content-max-width)
)
--thread-gutter-size: calc((100cqw - var(--thread-content-width)) / 2)
```

Live Browser inspection against the current ChatGPT conversation at an `880px` CSS viewport showed the Markdown root at `640px`, with a parent class setting `[--thread-content-max-width:40rem]` and a larger-container branch of `@w-lg/main:[--thread-content-max-width:48rem]`. That capture proves ChatGPT uses responsive content variables, but it is not a reason to emulate browser zoom by post-layout scaling, canvas growth, or a hard-coded `40rem` export column. Line breaks come from the active layout metrics, not from a static screenshot width.

Scopy's preview/export implementation mirrors that principle while keeping output size separate from layout scale:

- the text column stays anchored to the desktop message branch: `48rem`/`768px`
- the default `100%` ChatGPT profile uses `0.8x` font and line-height metrics because Scopy's captured unscaled CSS-pixel baseline matches the browser's physical `125%` evidence
- the `125%` profile uses the same column with `1.0x` font and line-height metrics; it must not apply a second `1.25x` multiplier or narrow the column to `40rem`
- safe inline padding stays `24px` on each side
- the preview/export surface stays fixed at `768px + 48px = 816px` when the screen allows it
- the active text column is `min(profileColumn, 100vw - 48px, outputSurface - 48px)`
- the layout profile is part of the Markdown render context and cache key, so 100% and 125% previews cannot reuse stale HTML
- text wrapping follows `wrap-break-word`: `overflow-wrap: break-word` with normal `word-break`

This separation is intentional: changing the ChatGPT layout scale must change font metrics and line breaks, but it must not change PNG target pixels or the hover-preview shell width. Wide tables still get a scroll container that can break out to the stable render surface, but they do not change the text-column width. PNG export starts from the same laid-out surface; table fitting is a bitmap/export transform after layout, not a second table stylesheet.

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

## Inline Code

Inline code uses the root `.prose :where(code)` contract:

- color: root text `rgb(13, 13, 13)`
- background: alpha-04 in light mode
- inset 1px alpha-08 stroke, matching the WACZ contrast instead of relying on background alone
- radius: 4px
- padding: `0.15rem 0.3rem`
- font size: `0.875em`; in a 16px paragraph this computes to 14px
- font weight: 500
- line height: inherit
- wrapping remains normal with `overflow-wrap: break-word`

Heading-contained code is still inline code. The WACZ root CSS applies the same `code` pill inside headings; heading rules only adjust details such as inherited color and the `h3 code` relative size. Do not strip the pill from `h1 code`, `h2 code`, or other heading code spans. If malformed source such as `#标题` falls back to a paragraph, the renderer must normalize it before Markdown parsing so the heading structure and heading inline-code cascade are both preserved.

## Markdown Input Normalization

Scopy normalizes ATX heading markers before both legacy and unified renderers:

- `#标题` becomes `# 标题`
- `##标题` becomes `## 标题`
- existing valid headings are unchanged
- fenced code blocks are unchanged
- indented code blocks are unchanged
- shebang-like lines such as `#! /usr/bin/env bash` are unchanged

This shared pre-parse step prevents renderer-path drift: legacy and unified output must start from the same heading semantics.

## Code Blocks

Code blocks use the ChatGPT rounded code-card surface:

- border radius: 24px
- border: 1px solid light border
- background: neutral alpha surface
- top language label area before code text
- monospace font from the captured `ui-monospace, SFMono-Regular, ...` stack
- language labels are display chrome and are not part of reusable Markdown content

Syntax coloring is language-dependent and comes from the WACZ root stylesheet token colors, not a hand-picked Scopy palette.

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

Both legacy `markdown-it` and unified `rehype-highlight` must emit or preserve `hljs` token classes before export readiness flips. PNG export waits for the same rendered DOM state as preview, so code colors must not depend on a preview-only stylesheet or late post-processing step.

## Links And Source Citations

Ordinary Markdown links remain text links:

- text color inherits the primary text color
- underline style is dotted with `rgb(143, 143, 143)`
- the local export surface appends the external-link arrow for normal links

ChatGPT source citations are not ordinary links. The live DOM for the selected `AP News` source uses an inline wrapper with `data-testid="webpage-citation-pill"` and a nested source anchor:

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

For grouped citations such as live `AP News +1`, the source label and count are separate parts of the same pill. The measured selected example uses a 70px wrapper, an `AP News` text span, and a `+1` suffix span with `rgb(143, 143, 143)`, 4px horizontal padding, and a -4px right margin inside the same 18px-high anchor.

Scopy may promote Markdown source-reference syntax to the same visual class when the source carries explicit citation semantics, such as `([AP News][1])` plus a `[1]: https://...` definition, or the same parenthesized HTTP inline-link shape. The promotion removes the literal parentheses and marks the anchor as `data-scopy-source-citation="true"`; it must not rewrite ordinary parenthesized links such as `([guide][1])`. A parenthesized citation group such as `([AP News][1], [Reuters][2])` collapses to the first source with `data-scopy-source-count="+1"` so the visible form follows ChatGPT's `AP News +1` pill instead of rendering multiple ordinary links.

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
- task lists do not rely on native checkbox rendering. Scopy paints the marker so preview and export share the same checked/unchecked geometry and colors.

## Tables

Standard Markdown tables keep the `markdown-new-styling` natural table path:

- `border-collapse: separate`
- `border-spacing: 0`
- table width is `100%` for standard tables
- `th` block padding: 8px
- `th` line-height: 16px
- `td` block padding: 10px
- last-row `td` bottom padding: 24px
- non-first columns get 8px start padding
- non-last columns get 24px end padding
- the last column gets 40px end padding from the captured `last:pe-10` rule

Wide tables use a container model derived from the WACZ table container rules:

- the preview frame does not widen
- the scroll container can expand to the full render surface rather than being trapped inside the text column
- the table surface is wider than the text column when needed, but starts at the same message-column x position
- preview scrolls the table container horizontally
- export scales the same table surface; it does not substitute a second table stylesheet

The Markdown table JS assigns column sizes by rendered text length: `>160 -> xl`, `>100 -> lg`, `>40 -> md`, otherwise `sm`. The `ui-全面.wacz` assistant Markdown contains six pipe tables; the 16-column wide table starts at line 290 and has 10 data rows, with every column classified as `sm` by the captured thresholds. Do not use naive pipe counts for table analysis: escaped pipes and pipes inside one- or two-backtick inline code spans must not create columns, while the source's fence-marker examples such as ```` ```python ```` remain cell text and still split at real table delimiters.

The implementation rule is pre-parse and shared: table-row code spans with one or two backticks get their internal unescaped `|` characters escaped before GFM parsing, but runs of three or more backticks are treated as fence-marker examples inside table cells, not as inline code spans. This keeps `` `| A | B |` `` in a single cell without merging cells like ` ```python | ```bash `.
