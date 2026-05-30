# ChatGPT WACZ Markdown Style Contract

This document records the source-derived rendering contract used by Scopy's ChatGPT-aligned Markdown preview and export path.

## Evidence Priority

1. WACZ conversation JSON is the semantic source for Markdown input examples.
2. WACZ HTML plus extracted CSS are the styling source for rendered DOM classes and cascade.
3. Browser screenshots are verification only. They are not the source for changing constants.
4. The live `chatgpt.com` tab is used only to confirm the current product surface is reachable; archived WACZ files remain the reproducible evidence for this release.

Current primary captures:

- `/tmp/scopy-wacz-extract/ui/0035_chatgpt.com_backend-api_conversation_6a19ad01-18d8-83ea-b945-71f803842646.json`
- `/tmp/scopy-wacz-extract/ui/0121_chatgpt.com_c_6a19ad01-18d8-83ea-b945-71f803842646.html`
- `/tmp/scopy-wacz-extract/ui/1114-root-l30w6n1j.css`
- `/tmp/scopy-wacz-extract/ui/0676-AssistantMessage-6zxhctcg.css`
- `/tmp/scopy-wacz-extract/ui-表格超宽2/0169_chatgpt.com_backend-api_conversation_6a19f0d5-06c4-83ea-bddc-a2068f6bbc2f.json`
- `/tmp/scopy-wacz-extract/ui-表格超宽2/1182-root-gqg5932l.css`
- `/tmp/scopy-wacz-extract/ui-表格超宽2/0766-AssistantMessage-6zxhctcg.css`

## Source Model

The rendered assistant Markdown root uses:

```text
markdown prose dark:prose-invert wrap-break-word w-full dark markdown-new-styling
```

The `markdown-new-styling` branch is authoritative for heading rhythm and table rules. The older AssistantMessage class family, including `qN-_1G_MarkdownContent`, is kept only for component-specific details such as inline code token styling when the root DOM still emits those components.

## Width And Wrapping

- Markdown content width is `768px`.
- Scopy adds the captured safe inline padding around that content, so the fixed preview/export layout width is `768 + 24 + 24 = 816px`.
- Text wrapping follows `wrap-break-word`, which maps to `overflow-wrap: break-word`.
- Preview keeps this layout width stable. If the visual container is narrower, Scopy scales the already-laid-out surface instead of changing the content width, because changing width changes paragraph line breaks.
- Wide tables are the exception: they keep the same preview frame width, but the table area scrolls horizontally inside it. PNG export then scales that already-laid-out table surface because a bitmap cannot scroll.

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

Inline code in normal flow uses the AssistantMessage inline-code component contract:

- background: alpha-04 in light mode
- inset 1px alpha border
- radius: 4px
- font size: 0.875em / Scopy fixed equivalent 14px
- font weight: 500
- no wrapping inside the pill

Inline code inside headings is not a pill. It inherits the heading font, line height, weight, and color. This is not a cosmetic override; it preserves the heading AST contract. If malformed source such as `#标题` falls back to a paragraph, the renderer must normalize it before Markdown parsing so heading-contained code is styled as heading text rather than paragraph inline code.

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
- `td` block padding: 10px
- non-last columns get 24px end padding
- last-column padding is not patched at export time

Wide tables use a container model derived from the WACZ `TableContainer` rules:

- the preview frame does not widen
- the table surface is wider than the text column when needed
- preview scrolls the table container horizontally
- export scales the same table surface; it does not substitute a second table stylesheet

Wide-table classification is data driven: column count, long cell content, total row content, and measured overflow decide whether the table moves from standard to wide behavior.
