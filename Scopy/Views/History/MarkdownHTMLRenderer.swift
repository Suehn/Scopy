import Foundation

enum MarkdownHTMLRenderer {
    static func render(markdown: String) -> String {
        render(markdown: markdown, context: MarkdownRenderContextResolver.defaultContext(for: markdown))
    }

    /// Returns "" when cancelled; callers treat empty HTML as "no document".
    static func render(markdown: String, context: MarkdownRenderContext) -> String {
        guard !Task.isCancelled else { return "" }
        var source = markdown
        if context.policy.allowLatexDocumentNormalize {
            // Code, links, URLs and paths are islands the LaTeX document normalizer must not rewrite.
            let islands = MarkdownSyntaxProtector.protectForLaTeXDocumentNormalization(source)
            guard !Task.isCancelled else { return "" }
            let normalized = LaTeXDocumentNormalizer.normalize(islands.markdown)
            guard !Task.isCancelled else { return "" }
            source = MarkdownSyntaxProtector.restore(normalized, placeholders: islands.placeholders)
            guard !Task.isCancelled else { return "" }
        }
        // The unified renderer is the delimiter authority for authored/ChatGPT Markdown. Math is
        // only protected while a scientific repair profile rewrites the surrounding text; authored
        // dollar delimiters and currency reach the parser unchanged.
        if context.policy.allowLatexInlineTextNormalize {
            let protected = MathProtector.protectMath(in: source)
            guard !Task.isCancelled else { return "" }
            source = MathProtector.restoreMath(
                in: LaTeXInlineTextNormalizer.normalize(protected.markdown),
                placeholders: protected.placeholders,
                escape: { $0 }
            )
        }
        source = MarkdownATXHeadingNormalizer.normalize(source)
        source = MarkdownTableCodeSpanPipeNormalizer.normalize(source)
        guard !Task.isCancelled else { return "" }
        return MarkdownHTMLDocumentBuilder.document(markdown: source, context: context)
    }
}
