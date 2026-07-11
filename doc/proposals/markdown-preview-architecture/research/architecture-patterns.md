# Architecture Pattern Research

## Scope

Bounded synthesis of previously verified official specifications and the current Scopy implementation. No additional product-code changes or broad web crawl were performed.

## Sources

- Apple Pasteboard Programming Guide: https://developer.apple.com/library/archive/documentation/General/Devpedia-CocoaApp-MOSX/Pasteboard.html
- Apple `NSPasteboardItem`: https://developer.apple.com/documentation/appkit/nspasteboarditem
- W3C Clipboard API: https://www.w3.org/TR/clipboard-apis/
- Typora Copy and Paste: https://support.typora.io/Copy-and-Paste/
- Typora Markdown Reference: https://support.typora.io/Markdown-Reference/
- CommonMark 0.31.2: https://spec.commonmark.org/0.31.2/
- CommonMark CJK emphasis issue: https://github.com/commonmark/commonmark-spec/issues/650
- unified: https://unifiedjs.com/
- remark-rehype: https://github.com/remarkjs/remark-rehype
- rehype-sanitize: https://github.com/rehypejs/rehype-sanitize
- KaTeX common issues: https://katex.org/docs/issues

## Comparable Patterns

### 1. macOS pasteboard representation sets

The AppKit model treats one pasteboard item as a collection of representations. A receiver selects a type it understands; therefore HTML, RTF, plain text, and source formats are complementary rather than mutually exclusive. The stable persistence analogue is an entry/snapshot with child representations, not one winning payload column.

Implications for Scopy:

- Capture original representations before selecting a display type.
- Preserve pasteboard item boundaries and exact per-type bytes.
- Replay a representation set for original-copy behavior.
- Keep generated HTML/RTF distinguishable from captured originals.

### 2. Typora source-versus-rich conversion

Typora documents both multi-format copy and HTML-first smart paste. This demonstrates two distinct product intents:

- exact/source copy, where Markdown remains Markdown source;
- rendered/rich copy, where target applications receive HTML/RTF/plain forms.

Trying to infer both intents behind one irreversible ingest choice causes ambiguity. A clipboard manager should preserve originals first and expose conversion as a separate derived action.

### 3. AST-based Markdown compilation

The unified/remark/rehype model separates parsing, syntax-tree transforms, Markdown-to-HTML conversion, sanitization, highlighting/math transforms, and serialization. That boundary is more maintainable than global source regexes because extensions can own syntax/AST nodes and sanitizer schema changes.

Implications for Scopy:

- Keep one canonical compiler/dialect for normal Markdown.
- Implement CJK emphasis at tokenizer/parser or syntax-aware lexical level.
- Implement safe HTML and footnote behavior in AST/sanitizer configuration.
- Treat WebView as a presentation consumer rather than the owner of parsing policy.

### 4. Versioned compilers and reproducible artifacts

Markdown output depends on parser, plugins, sanitization, KaTeX/highlight versions, CSS, resource policy, and theme. Reproducibility therefore requires a manifest and complete cache key rather than only a source hash.

Implications for Scopy:

- Version dialect, transform, compiler bundle, sanitizer, assets, theme, and cache schema.
- Match KaTeX JS and CSS versions in one manifest.
- Compare semantic DOM/AST signatures and visual output in regression tests.
- Cache rendered results as disposable derived artifacts, never as the only stored truth.

## Feasible Approaches

### A. Immutable capture snapshots plus one canonical compiler — recommended

Preserve representation sets, separate exact and semantic identity, derive preview sources explicitly, and render all Markdown through one versioned compiler. Use shadow comparison and a legacy kill switch during migration.

Strengths:

- Solves representation loss, first-wins deduplication, and route-dependent syntax simultaneously.
- Gives clear extension points for new pasteboard codecs, Markdown features, resources, and outputs.
- Supports lazy migration, rollback, and privacy-preserving diagnostics.

Weaknesses:

- Highest initial architecture and migration cost.

### B. Shared preprocessor over the current dual-renderer model

Patch CJK, math, footnotes, and images while retaining one-payload storage and profile-based renderer selection.

Strengths:

- Faster short-term delivery.

Weaknesses:

- Does not solve clipboard fidelity or semantic first-wins behavior.
- Permanently doubles extension and regression work.

### C. Persist rendered HTML snapshots

Render once at ingest and reuse the snapshot.

Strengths:

- Fast repeated presentation and historically stable appearance.

Weaknesses:

- Freezes bugs, sanitizer policy, dependency behavior, and theme into stored data.
- Increases storage and complicates future corrections.
- Still needs Approach A to preserve original representations.

## Recommendation

Adopt Approach A. Preserve first, derive second, and compile once for multiple consumers. Use cached HTML only as an evictable artifact. Keep the legacy renderer solely as a time-bounded migration rollback, not as a permanent content-dependent language branch.
