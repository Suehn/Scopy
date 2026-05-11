import Foundation

enum MarkdownPreviewRendererFacade {
    static func render(markdown: String, context: MarkdownRenderContext) -> MarkdownRenderOutput {
        switch context.renderer {
        case .legacyMarkdownIt:
            return LegacyMarkdownItRenderer.render(markdown: markdown, context: context)
        case .unified:
            return UnifiedMarkdownRenderer.render(markdown: markdown, context: context)
        }
    }
}

enum LegacyMarkdownItRenderer: MarkdownPreviewRenderer {
    static let kind: MarkdownRendererKind = .legacyMarkdownIt

    static func render(markdown: String, context: MarkdownRenderContext) -> MarkdownRenderOutput {
        MarkdownHTMLRenderer.renderLegacy(markdown: markdown, context: context)
    }
}
