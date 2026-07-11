import Foundation

enum UnifiedMarkdownRenderer: MarkdownPreviewRenderer {
    private final class BundleAvailabilityOverrideStorage: @unchecked Sendable {
        typealias Override = @Sendable () -> Bool

        private let lock = NSLock()
        private var storedValue: Override?

        func value() -> Override? {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }

        func setValue(_ value: Override?) {
            lock.lock()
            storedValue = value
            lock.unlock()
        }
    }

    static let kind: MarkdownRendererKind = .unified
    private static let bundleAvailabilityOverrideStorage = BundleAvailabilityOverrideStorage()

    static func setBundleAvailabilityOverride(
        _ override: (@Sendable () -> Bool)?
    ) {
        bundleAvailabilityOverrideStorage.setValue(override)
    }

    static func render(markdown: String, context: MarkdownRenderContext) -> MarkdownRenderOutput {
        guard isUnifiedBundleAvailable() else {
            return legacyFallback(markdown: markdown, context: context, reason: "unified bundle missing")
        }

        let normalizedMarkdown = MarkdownTableCodeSpanPipeNormalizer.normalize(
            MarkdownATXHeadingNormalizer.normalize(markdown)
        )
        let html = MarkdownHTMLDocumentBuilder.unifiedDocument(markdown: normalizedMarkdown, context: context)
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
        if let bundleAvailabilityOverride = bundleAvailabilityOverrideStorage.value() {
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
            cacheNamespace: context.cacheNamespace,
            layoutScale: context.layoutScale
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
