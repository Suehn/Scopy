# Markdown/LaTeX Renderer Migration Status

> Updated: 2026-05-11
> Scope: implementation status for `doc/implementation/Markdown-LaTeX-renderer-migration-blueprint.md`.

## Default Renderer Matrix

| Source profile | Default renderer | Loose repair | Reason |
| --- | --- | ---: | --- |
| `authoredMarkdown` | `unified` | off | Standard Markdown is lowest-risk for AST rendering and should preserve Markdown semantics. |
| `chatGPTMarkdown` | `unified` | off | Local file links, code spans, and generated Markdown are the primary regression class fixed by the unified path. |
| `scientificMarkdown` | `legacyMarkdownIt` | off | Explicit math is supported, but this profile still needs more visual/export comparison before default cutover. |
| `latexDocumentLike` | `legacyMarkdownIt` | on | Existing Swift LaTeX document normalization remains the stable path for document-shaped TeX fragments. |
| `pdfOCRScientific` | `legacyMarkdownIt` | on | OCR-style loose math is still high-risk; unified AST repair exists and is corpus-tested, but default cutover is intentionally deferred. |
| `richHTML` | `legacyMarkdownIt` | off | Safe HTML subset parity exists in unified tests, but rich HTML preview/export parity needs a longer soak. |
| `plainTextUnknown` | `legacyMarkdownIt` | off | Avoid over-interpreting ordinary clipboard text as Markdown or math. |

## Flags And Rollback

- `SCOPY_MARKDOWN_RENDERER=legacy` forces `legacyMarkdownIt` with the old `legacyCompatible` policy as a hard rollback.
- `SCOPY_MARKDOWN_RENDERER=unified` forces unified for all profiles; this is for debugging and validation, not the product default.
- `SCOPY_MARKDOWN_UNIFIED_SAFE_PROFILES=0` disables the safe-profile default cutover.
- `SCOPY_MARKDOWN_UNIFIED_SCIENTIFIC=1` allows `scientificMarkdown` to use unified for targeted validation.
- `SCOPY_MARKDOWN_UNIFIED_SHADOW=1` records structural shadow comparisons without changing user-visible output.

## Verification Coverage

- Shared corpus: `ScopyTests/Fixtures/MarkdownRenderingCorpus/cases.json`.
- Swift corpus runner: `ScopyTests/MarkdownRenderingCorpusTests.swift`.
- Unified JS corpus runner: `Tools/MarkdownRenderer/test/corpus.test.js`.
- Focused renderer tests cover profile selection, render-aware cache keys, fallback, syntax protection, safe HTML, backslash math, dollar guards, and AST loose repair.

## Remaining Intentional Legacy Areas

`latexDocumentLike`, `pdfOCRScientific`, `richHTML`, and `plainTextUnknown` still default to legacy by design. The unified implementation exists for shadow/forced validation, but these profiles should not be cut over until export screenshots, performance profile, and corpus expansion show no regressions.
