import XCTest

final class MarkdownPreviewRendererFacadeTests: XCTestCase {
    func testLegacyContextReturnsMarkdownItOutputAndDiagnostics() {
        let input = "Inline math: $x_1$ and [doc](/Users/alice/a.md:1)"
        let context = MarkdownRenderContextResolver.defaultContext(for: input, flags: .disabled)

        let output = MarkdownHTMLRenderer.render(markdown: input, context: context)

        XCTAssertFalse(output.html.isEmpty)
        XCTAssertTrue(output.html.contains("markdown-it.min.js"))
        XCTAssertTrue(output.html.contains("window.__scopyIsRenderReady"))
        XCTAssertTrue(output.html.contains("[doc](/Users/alice/a.md:1)"))
        XCTAssertEqual(output.diagnostics.renderer, .legacyMarkdownIt)
        XCTAssertEqual(output.diagnostics.profile, .chatGPTMarkdown)
        XCTAssertGreaterThan(output.diagnostics.protectedIslandCount, 0)
        XCTAssertGreaterThan(output.diagnostics.explicitMathCount, 0)
    }

    func testDefaultResolverCutsChatGPTMarkdownToUnified() {
        let input = "Inline math: $x_1$ and [doc](/Users/alice/a.md:1)"

        let context = MarkdownRenderContextResolver.defaultContext(for: input)
        let directHTML = MarkdownHTMLRenderer.render(markdown: input)
        let output = MarkdownHTMLRenderer.render(markdown: input, context: context)

        XCTAssertFalse(directHTML.isEmpty)
        XCTAssertEqual(output.diagnostics.renderer, .unified)
        XCTAssertEqual(output.diagnostics.profile, .chatGPTMarkdown)
        XCTAssertTrue(output.html.contains("scopy-unified-renderer.iife.js"))
        XCTAssertFalse(output.html.contains("markdown-it.min.js"))
    }

    func testUnifiedContextUsesUnifiedShellWhenRequested() {
        let input = "# Title\n\nText"
        let base = MarkdownRenderContextResolver.defaultContext(for: input)
        let unifiedContext = MarkdownRenderContext(
            renderer: .unified,
            profile: base.profile,
            policy: base.policy,
            policyVersion: base.policyVersion,
            cacheNamespace: base.cacheNamespace
        )

        let output = MarkdownHTMLRenderer.render(markdown: input, context: unifiedContext)

        XCTAssertFalse(output.html.isEmpty)
        XCTAssertEqual(output.diagnostics.renderer, .unified)
        XCTAssertNil(output.diagnostics.fallbackReason)
        XCTAssertTrue(output.html.contains("scopy-unified-renderer.iife.js"))
    }

    func testDefaultResolverCutsAuthoredMarkdownToUnified() {
        let input = """
        # Title

        - item
        """

        let context = MarkdownRenderContextResolver.defaultContext(for: input)
        let directHTML = MarkdownHTMLRenderer.render(markdown: input)
        let output = MarkdownHTMLRenderer.render(markdown: input, context: context)

        XCTAssertFalse(directHTML.isEmpty)
        XCTAssertEqual(output.diagnostics.renderer, .unified)
        XCTAssertEqual(output.diagnostics.profile, .authoredMarkdown)
        XCTAssertTrue(output.html.contains("scopy-unified-renderer.iife.js"))
        XCTAssertFalse(output.html.contains("markdown-it.min.js"))
    }

    func testUnifiedContextResolverUsesConservativePolicyAndNamespace() {
        let input = """
        # Title

        - item
        """
        let flags = MarkdownRendererFlagSet(
            forceLegacy: false,
            forceUnified: false,
            unifiedSafeProfilesEnabled: true,
            unifiedScientificEnabled: false,
            shadowUnifiedEnabled: false
        )

        let context = MarkdownRenderContextResolver.defaultContext(for: input, flags: flags)

        XCTAssertEqual(context.renderer, .unified)
        XCTAssertEqual(context.profile, .authoredMarkdown)
        XCTAssertFalse(context.policy.allowLooseMathRepair)
        XCTAssertFalse(context.policy.allowLatexDocumentNormalize)
        XCTAssertEqual(context.policyVersion, MarkdownRenderContextResolver.unifiedPolicyVersion)
        XCTAssertEqual(context.cacheNamespace, MarkdownRenderContextResolver.unifiedCacheNamespace)
    }
}
