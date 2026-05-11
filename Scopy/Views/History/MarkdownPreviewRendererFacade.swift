import Foundation
import ScopyUISupport

enum MarkdownPreviewRendererFacade {
    static func render(markdown: String, context: MarkdownRenderContext) -> MarkdownRenderOutput {
        render(markdown: markdown, context: context, flags: MarkdownRendererFeatureFlags.current)
    }

    static func render(
        markdown: String,
        context: MarkdownRenderContext,
        flags: MarkdownRendererFlagSet
    ) -> MarkdownRenderOutput {
        let primary: MarkdownRenderOutput
        switch context.renderer {
        case .legacyMarkdownIt:
            primary = LegacyMarkdownItRenderer.render(markdown: markdown, context: context)
        case .unified:
            primary = UnifiedMarkdownRenderer.render(markdown: markdown, context: context)
        }
        recordShadowIfNeeded(markdown: markdown, context: context, primary: primary, flags: flags)
        return primary
    }

    private static func recordShadowIfNeeded(
        markdown: String,
        context: MarkdownRenderContext,
        primary: MarkdownRenderOutput,
        flags: MarkdownRendererFlagSet
    ) {
        guard MarkdownRenderShadowComparator.shouldShadow(context: context, flags: flags) else { return }
        guard !Task.isCancelled else { return }

        let shadowContext = context.withRenderer(.unified)
        let start = ScrollPerformanceProfile.isEnabled ? CFAbsoluteTimeGetCurrent() : nil
        let shadow = UnifiedMarkdownRenderer.render(markdown: markdown, context: shadowContext)
        let elapsed = start.map { (CFAbsoluteTimeGetCurrent() - $0) * 1000 }
        MarkdownRenderShadowComparator.record(
            primary: primary,
            shadow: shadow,
            source: markdown,
            context: context,
            shadowRenderMs: elapsed
        )
    }
}

enum LegacyMarkdownItRenderer: MarkdownPreviewRenderer {
    static let kind: MarkdownRendererKind = .legacyMarkdownIt

    static func render(markdown: String, context: MarkdownRenderContext) -> MarkdownRenderOutput {
        MarkdownHTMLRenderer.renderLegacy(markdown: markdown, context: context)
    }
}
