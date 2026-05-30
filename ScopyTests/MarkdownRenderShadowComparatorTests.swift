import XCTest
import ScopyKit

final class MarkdownRenderShadowComparatorTests: XCTestCase {
    func testShouldShadowOnlySafeLegacyProfilesWhenFlagEnabled() {
        let flags = MarkdownRendererFlagSet(
            forceLegacy: false,
            forceUnified: false,
            unifiedSafeProfilesEnabled: false,
            unifiedScientificEnabled: false,
            shadowUnifiedEnabled: true
        )

        XCTAssertTrue(MarkdownRenderShadowComparator.shouldShadow(
            context: context(profile: .authoredMarkdown, renderer: .legacyMarkdownIt),
            flags: flags
        ))
        XCTAssertTrue(MarkdownRenderShadowComparator.shouldShadow(
            context: context(profile: .chatGPTMarkdown, renderer: .legacyMarkdownIt),
            flags: flags
        ))
        XCTAssertTrue(MarkdownRenderShadowComparator.shouldShadow(
            context: context(profile: .scientificMarkdown, renderer: .legacyMarkdownIt),
            flags: flags
        ))
        XCTAssertFalse(MarkdownRenderShadowComparator.shouldShadow(
            context: context(profile: .pdfOCRScientific, renderer: .legacyMarkdownIt),
            flags: flags
        ))
        XCTAssertFalse(MarkdownRenderShadowComparator.shouldShadow(
            context: context(profile: .authoredMarkdown, renderer: .unified),
            flags: flags
        ))
        XCTAssertFalse(MarkdownRenderShadowComparator.shouldShadow(
            context: context(profile: .authoredMarkdown, renderer: .legacyMarkdownIt),
            flags: .disabled
        ))
    }

    func testComparatorReportsStructuralSignalsAndWarnings() {
        let primary = output(
            renderer: .legacyMarkdownIt,
            html: #"<a href="/x">x</a><pre><code>a</code></pre><table><tr></tr></table><span class="katex"></span>"#,
            mathCount: 1
        )
        let shadow = output(
            renderer: .unified,
            html: #"<a href="/x">x</a><pre><code>a</code></pre><script src="https://cdn.example.test/x.js"></script>"#,
            mathCount: 0
        )

        let report = MarkdownRenderShadowComparator.compare(
            primary: primary,
            shadow: shadow,
            source: "[x](/x)",
            context: context(profile: .authoredMarkdown, renderer: .legacyMarkdownIt)
        )

        XCTAssertTrue(report.hasMismatch)
        XCTAssertEqual(report.primary.linkCount, 1)
        XCTAssertEqual(report.primary.codeBlockCount, 1)
        XCTAssertEqual(report.primary.tableCount, 1)
        XCTAssertEqual(report.primary.mathCount, 1)
        XCTAssertEqual(report.shadow.externalAssetReferenceCount, 1)
        XCTAssertTrue(report.warnings.contains("table count differs: primary=1, shadow=0"))
        XCTAssertTrue(report.warnings.contains("math count differs: primary=1, shadow=0"))
        XCTAssertTrue(report.warnings.contains("shadow html references external assets"))
    }

    func testFacadeShadowModeKeepsPrimaryLegacyOutput() {
        let markdown = "# Title\n\n[doc](/Users/alice/file.md:12)\n\n| a | b |\n| --- | --- |\n| 1 | 2 |"
        let flags = MarkdownRendererFlagSet(
            forceLegacy: false,
            forceUnified: false,
            unifiedSafeProfilesEnabled: false,
            unifiedScientificEnabled: false,
            shadowUnifiedEnabled: true
        )
        let renderContext = context(profile: .authoredMarkdown, renderer: .legacyMarkdownIt)

        let output = MarkdownPreviewRendererFacade.render(
            markdown: markdown,
            context: renderContext,
            flags: flags
        )

        XCTAssertEqual(output.diagnostics.renderer, .legacyMarkdownIt)
        XCTAssertTrue(output.html.contains("markdown-it.min.js"))
        XCTAssertFalse(output.html.contains("scopy-unified-renderer.iife.js"))
    }

    private func context(
        profile: MarkdownSourceProfile,
        renderer: MarkdownRendererKind
    ) -> MarkdownRenderContext {
        MarkdownRenderContext(
            renderer: renderer,
            profile: profile,
            policy: MarkdownRepairPolicy.legacyCompatible(for: profile),
            policyVersion: MarkdownRenderContextResolver.legacyPolicyVersion,
            cacheNamespace: MarkdownRenderContextResolver.legacyCacheNamespace,
            layoutScale: MarkdownRenderLayoutConstants.defaultChatGPTLayoutScale
        )
    }

    private func output(
        renderer: MarkdownRendererKind,
        html: String,
        mathCount: Int
    ) -> MarkdownRenderOutput {
        let profile: MarkdownSourceProfile = .authoredMarkdown
        let context = context(profile: profile, renderer: renderer)
        let diagnostics: MarkdownRenderDiagnostics
        switch renderer {
        case .legacyMarkdownIt:
            diagnostics = .legacy(
                context: context,
                protectedIslandCount: 0,
                explicitMathCount: mathCount
            )
        case .unified:
            diagnostics = MarkdownRenderDiagnostics(
                renderer: .unified,
                profile: profile,
                policyVersion: context.policyVersion,
                protectedIslandCount: 0,
                explicitMathCount: mathCount,
                repairedMathCount: 0,
                fallbackReason: nil,
                warnings: []
            )
        }
        return MarkdownRenderOutput(html: html, diagnostics: diagnostics)
    }
}
