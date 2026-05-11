import XCTest

final class MarkdownPreviewRendererFacadeTests: XCTestCase {
    func testDefaultRendererReturnsLegacyOutputAndDiagnostics() {
        let input = "Inline math: $x_1$ and [doc](/Users/alice/a.md:1)"
        let context = MarkdownRenderContextResolver.defaultContext(for: input)

        let directHTML = MarkdownHTMLRenderer.render(markdown: input)
        let output = MarkdownHTMLRenderer.render(markdown: input, context: context)

        XCTAssertFalse(directHTML.isEmpty)
        XCTAssertFalse(output.html.isEmpty)
        XCTAssertTrue(output.html.contains("markdown-it.min.js"))
        XCTAssertTrue(output.html.contains("window.__scopyIsRenderReady"))
        XCTAssertTrue(output.html.contains("[doc](/Users/alice/a.md:1)"))
        XCTAssertEqual(output.diagnostics.renderer, .legacyMarkdownIt)
        XCTAssertEqual(output.diagnostics.profile, .chatGPTMarkdown)
        XCTAssertGreaterThan(output.diagnostics.protectedIslandCount, 0)
        XCTAssertGreaterThan(output.diagnostics.explicitMathCount, 0)
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
}
