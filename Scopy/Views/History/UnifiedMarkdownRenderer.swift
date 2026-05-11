import Foundation

enum UnifiedMarkdownRenderer: MarkdownPreviewRenderer {
    static let kind: MarkdownRendererKind = .unified

    static func render(markdown: String, context: MarkdownRenderContext) -> MarkdownRenderOutput {
        let html = MarkdownHTMLDocumentBuilder.unifiedDocument(markdown: markdown, context: context)
        let diagnostics = MarkdownRenderDiagnostics(
            renderer: .unified,
            profile: context.profile,
            policyVersion: context.policyVersion,
            protectedIslandCount: 0,
            explicitMathCount: MarkdownDetector.containsMath(markdown) ? 1 : 0,
            repairedMathCount: 0,
            fallbackReason: nil,
            warnings: []
        )
        return MarkdownRenderOutput(html: html, diagnostics: diagnostics)
    }
}
