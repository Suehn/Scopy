import Foundation

enum MarkdownHTMLRenderer {
    static func render(markdown: String) -> String {
        let context = MarkdownRenderContextResolver.defaultContext(for: markdown)
        return render(markdown: markdown, context: context).html
    }

    static func render(markdown: String, context: MarkdownRenderContext) -> MarkdownRenderOutput {
        guard !Task.isCancelled else { return cancelledOutput(context: context) }
        let syntaxProtected = MarkdownSyntaxProtector.protectForLooseMathRepair(markdown)
        guard !Task.isCancelled else { return cancelledOutput(context: context) }
        let latexNormalized = context.policy.allowLatexDocumentNormalize
            ? LaTeXDocumentNormalizer.normalize(syntaxProtected.markdown)
            : syntaxProtected.markdown
        guard !Task.isCancelled else { return cancelledOutput(context: context) }
        let normalizedMarkdown = MarkdownSyntaxProtector.restore(
            latexNormalized,
            placeholders: syntaxProtected.placeholders
        )
        guard !Task.isCancelled else { return cancelledOutput(context: context) }
        let protected = MathProtector.protectMath(in: normalizedMarkdown)
        guard !Task.isCancelled else { return cancelledOutput(context: context) }
        let inlineNormalizedMarkdown = context.policy.allowLatexInlineTextNormalize
            ? LaTeXInlineTextNormalizer.normalize(protected.markdown)
            : protected.markdown
        let restoredMathMarkdown = MathProtector.restoreMath(
            in: inlineNormalizedMarkdown,
            placeholders: protected.placeholders,
            escape: { $0 }
        )
        let normalizedHeadingsMarkdown = MarkdownATXHeadingNormalizer.normalize(restoredMathMarkdown)
        let tablePipeNormalizedMarkdown = MarkdownTableCodeSpanPipeNormalizer.normalize(normalizedHeadingsMarkdown)

        guard !Task.isCancelled else { return cancelledOutput(context: context) }
        let html = MarkdownHTMLDocumentBuilder.document(
            markdown: tablePipeNormalizedMarkdown,
            context: context
        )
        let diagnostics = MarkdownRenderDiagnostics(
            profile: context.profile,
            explicitMathDetected: MarkdownDetector.containsMath(normalizedMarkdown),
            warnings: []
        )
        return MarkdownRenderOutput(html: html, diagnostics: diagnostics)
    }

    private static func cancelledOutput(context: MarkdownRenderContext) -> MarkdownRenderOutput {
        MarkdownRenderOutput(
            html: "",
            diagnostics: MarkdownRenderDiagnostics(
                profile: context.profile,
                explicitMathDetected: false,
                warnings: ["render cancelled"]
            )
        )
    }
}
