import Foundation

enum MarkdownHTMLRenderer {
    static func render(markdown: String) -> String {
        let context = MarkdownRenderContextResolver.defaultContext(for: markdown)
        return render(markdown: markdown, context: context).html
    }

    static func render(markdown: String, context: MarkdownRenderContext) -> MarkdownRenderOutput {
        MarkdownPreviewRendererFacade.render(markdown: markdown, context: context)
    }

    static func renderLegacy(markdown: String, context: MarkdownRenderContext) -> MarkdownRenderOutput {
        let featureSet = MarkdownRenderFeatureSet.scopyDefault
        guard !Task.isCancelled else { return cancelledOutput(context: context) }
        let syntaxProtected = MarkdownSyntaxProtector.protectForLooseMathRepair(markdown)
        guard !Task.isCancelled else { return cancelledOutput(context: context) }
        let latexNormalized = context.policy.allowLatexDocumentNormalize
            ? LaTeXDocumentNormalizer.normalize(syntaxProtected.markdown)
            : syntaxProtected.markdown
        guard !Task.isCancelled else { return cancelledOutput(context: context) }
        let looseMathNormalized = context.policy.allowLooseMathRepair
            ? MathNormalizer.wrapLooseLaTeX(latexNormalized)
            : latexNormalized
        let normalizedMarkdown = MarkdownSyntaxProtector.restore(
            looseMathNormalized,
            placeholders: syntaxProtected.placeholders
        )
        guard !Task.isCancelled else { return cancelledOutput(context: context) }
        let protected = MathProtector.protectMath(in: normalizedMarkdown)
        guard !Task.isCancelled else { return cancelledOutput(context: context) }
        let inlineNormalizedMarkdown = context.policy.allowLatexInlineTextNormalize
            ? LaTeXInlineTextNormalizer.normalize(protected.markdown)
            : protected.markdown
        let normalizedHeadingsMarkdown = MarkdownATXHeadingNormalizer.normalize(inlineNormalizedMarkdown)
        let tablePipeNormalizedMarkdown = MarkdownTableCodeSpanPipeNormalizer.normalize(normalizedHeadingsMarkdown)
        let emphasisNormalizedMarkdown = MarkdownCJKEmphasisNormalizer.normalize(tablePipeNormalizedMarkdown)
        let safeHTMLExtraction = featureSet.safeHTMLSubset && context.policy.allowSafeHTMLSubset
            ? MarkdownSafeHTMLSubset.extract(from: emphasisNormalizedMarkdown.markdown)
            : MarkdownSafeHTMLExtractionResult(
                markdown: emphasisNormalizedMarkdown.markdown,
                fallbackMarkdown: emphasisNormalizedMarkdown.markdown,
                replacements: [:]
            )
        let renderMarkdown = safeHTMLExtraction.markdown
        let hasMath = context.policy.allowExplicitMath && MarkdownDetector.containsMath(normalizedMarkdown)
        let enableMath = featureSet.math && hasMath

        let fallbackText = MarkdownCJKEmphasisNormalizer.stripRenderSentinel(
            from: MathProtector.restoreMath(
                in: safeHTMLExtraction.fallbackMarkdown,
                placeholders: protected.placeholders,
                escape: { $0 }
            ),
            sentinel: emphasisNormalizedMarkdown.renderSentinel
        )

        guard !Task.isCancelled else { return cancelledOutput(context: context) }
        let html = MarkdownHTMLDocumentBuilder.legacyDocument(
            featureSet: featureSet,
            markdown: renderMarkdown,
            placeholders: protected.placeholders,
            safeHTMLReplacements: safeHTMLExtraction.replacements,
            enableMath: enableMath,
            fallbackText: fallbackText,
            renderSentinel: emphasisNormalizedMarkdown.renderSentinel
        )
        let diagnostics = MarkdownRenderDiagnostics.legacy(
            context: context,
            protectedIslandCount: syntaxProtected.placeholders.count,
            explicitMathCount: protected.placeholders.count
        )
        return MarkdownRenderOutput(html: html, diagnostics: diagnostics)
    }

    private static func cancelledOutput(context: MarkdownRenderContext) -> MarkdownRenderOutput {
        MarkdownRenderOutput(
            html: "",
            diagnostics: MarkdownRenderDiagnostics.legacy(
                context: context,
                protectedIslandCount: 0,
                explicitMathCount: 0,
                warnings: ["render cancelled"]
            )
        )
    }

}
