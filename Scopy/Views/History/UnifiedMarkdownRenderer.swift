import Foundation

enum UnifiedMarkdownRenderer: MarkdownPreviewRenderer {
    static let kind: MarkdownRendererKind = .unified
    static var bundleAvailabilityOverride: (() -> Bool)?

    static func render(markdown: String, context: MarkdownRenderContext) -> MarkdownRenderOutput {
        guard isUnifiedBundleAvailable() else {
            return legacyFallback(markdown: markdown, context: context, reason: "unified bundle missing")
        }

        let html = MarkdownHTMLDocumentBuilder.unifiedDocument(markdown: markdown, context: context)
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return legacyFallback(markdown: markdown, context: context, reason: "unified document empty")
        }

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

    private static func isUnifiedBundleAvailable() -> Bool {
        if let bundleAvailabilityOverride {
            return bundleAvailabilityOverride()
        }
        if Bundle.main.url(
            forResource: "scopy-unified-renderer.iife",
            withExtension: "js",
            subdirectory: "MarkdownPreview/contrib"
        ) != nil {
            return true
        }
        return false
    }

    private static func legacyFallback(
        markdown: String,
        context: MarkdownRenderContext,
        reason: String
    ) -> MarkdownRenderOutput {
        let legacyContext = MarkdownRenderContext(
            renderer: .legacyMarkdownIt,
            profile: context.profile,
            policy: context.policy,
            policyVersion: context.policyVersion,
            cacheNamespace: context.cacheNamespace
        )
        let output = LegacyMarkdownItRenderer.render(markdown: markdown, context: legacyContext)
        let diagnostics = MarkdownRenderDiagnostics.legacy(
            context: legacyContext,
            protectedIslandCount: output.diagnostics.protectedIslandCount,
            explicitMathCount: output.diagnostics.explicitMathCount,
            repairedMathCount: output.diagnostics.repairedMathCount,
            fallbackReason: reason,
            warnings: output.diagnostics.warnings + ["unified fallback: \(reason)"]
        )
        return MarkdownRenderOutput(html: output.html, diagnostics: diagnostics)
    }
}
