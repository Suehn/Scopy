import Foundation

enum MarkdownHTMLRenderer {
    static func render(markdown: String) -> String {
        render(markdown: markdown, context: MarkdownRenderContextResolver.defaultContext(for: markdown))
    }

    /// Returns "" when cancelled; callers treat empty HTML as "no document".
    static func render(markdown: String, context: MarkdownRenderContext) -> String {
        guard let source = preprocess(markdown: markdown, policy: context.policy) else { return "" }
        return MarkdownHTMLDocumentBuilder.document(markdown: source, context: context)
    }

    /// The bounded Swift-side source repair for the scientific profiles; every other source reaches
    /// the renderer bundle verbatim (heading and table-pipe repair live in `render.js`). Returns nil
    /// when the task is cancelled.
    static func preprocess(markdown: String, policy: MarkdownRepairPolicy) -> String? {
        guard !Task.isCancelled else { return nil }
        var source = markdown
        if policy.allowLatexDocumentNormalize {
            // Code, links, URLs and paths are islands the LaTeX document normalizer must not rewrite.
            let islands = MarkdownSyntaxProtector.protectForLaTeXDocumentNormalization(source)
            guard !Task.isCancelled else { return nil }
            let normalized = LaTeXDocumentNormalizer.normalize(islands.markdown)
            guard !Task.isCancelled else { return nil }
            source = MarkdownSyntaxProtector.restore(normalized, placeholders: islands.placeholders)
            guard !Task.isCancelled else { return nil }
        }
        // The unified renderer is the delimiter authority for authored/ChatGPT Markdown. Math is
        // only protected while a scientific repair profile rewrites the surrounding text; authored
        // dollar delimiters and currency reach the parser unchanged.
        if policy.allowLatexInlineTextNormalize {
            let protected = MathProtector.protectMath(in: source)
            guard !Task.isCancelled else { return nil }
            source = MathProtector.restoreMath(
                in: LaTeXInlineTextNormalizer.normalize(protected.markdown),
                placeholders: protected.placeholders,
                escape: { $0 }
            )
        }
        guard !Task.isCancelled else { return nil }
        return source
    }
}
