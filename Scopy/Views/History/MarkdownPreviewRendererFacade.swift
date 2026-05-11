import Foundation

enum MarkdownPreviewRendererFacade {
    static func render(markdown: String, context: MarkdownRenderContext) -> MarkdownRenderOutput {
        switch context.renderer {
        case .legacyMarkdownIt:
            return LegacyMarkdownItRenderer.render(markdown: markdown, context: context)
        case .unified:
            let legacyContext = context.withRenderer(.legacyMarkdownIt)
            let output = LegacyMarkdownItRenderer.render(markdown: markdown, context: legacyContext)
            let diagnostics = MarkdownRenderDiagnostics.legacy(
                context: context,
                protectedIslandCount: output.diagnostics.protectedIslandCount,
                explicitMathCount: output.diagnostics.explicitMathCount,
                repairedMathCount: output.diagnostics.repairedMathCount,
                fallbackReason: "unified renderer is not bundled yet",
                warnings: output.diagnostics.warnings
            )
            return MarkdownRenderOutput(html: output.html, diagnostics: diagnostics)
        }
    }
}

enum LegacyMarkdownItRenderer: MarkdownPreviewRenderer {
    static let kind: MarkdownRendererKind = .legacyMarkdownIt

    static func render(markdown: String, context: MarkdownRenderContext) -> MarkdownRenderOutput {
        MarkdownHTMLRenderer.renderLegacy(markdown: markdown, context: context)
    }
}
