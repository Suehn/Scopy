import XCTest

final class UnifiedMarkdownRendererTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UnifiedMarkdownRenderer.bundleAvailabilityOverride = { true }
    }

    override func tearDown() {
        UnifiedMarkdownRenderer.bundleAvailabilityOverride = nil
        super.tearDown()
    }

    func testUnifiedRendererBuildsStandaloneHTMLDocument() {
        let base = MarkdownRenderContextResolver.defaultContext(for: "# Title\n\n$x_1$")
        let context = base.withRenderer(.unified)

        let output = MarkdownHTMLRenderer.render(markdown: "# Title\n\n$x_1$", context: context)

        XCTAssertEqual(output.diagnostics.renderer, .unified)
        XCTAssertTrue(output.html.contains("contrib/scopy-unified-renderer.iife.js"))
        XCTAssertTrue(output.html.contains("window.__scopyIsRenderReady"))
        XCTAssertTrue(output.html.contains("window.__scopyRenderMath"))
        XCTAssertTrue(output.html.contains("katex.min.css"))
        XCTAssertFalse(output.html.contains("markdown-it.min.js"))
    }

    func testUnifiedDocumentFallsBackWhenBundleAPIIsMissing() {
        let base = MarkdownRenderContextResolver.defaultContext(for: "# Title")
        let context = base.withRenderer(.unified)

        let output = MarkdownHTMLRenderer.render(markdown: "# Title", context: context)

        XCTAssertTrue(output.html.contains("maxUnifiedRenderAttempts"))
        XCTAssertTrue(output.html.contains("unifiedFallbackReason = 'unified api missing'"))
        XCTAssertTrue(output.html.contains("finish();"))
    }

    func testUnifiedRendererFallsBackToLegacyWhenBundleIsMissing() {
        UnifiedMarkdownRenderer.bundleAvailabilityOverride = { false }
        defer { UnifiedMarkdownRenderer.bundleAvailabilityOverride = nil }
        let base = MarkdownRenderContextResolver.defaultContext(for: "# Title")
        let context = base.withRenderer(.unified)

        let output = MarkdownHTMLRenderer.render(markdown: "# Title", context: context)

        XCTAssertEqual(output.diagnostics.renderer, .legacyMarkdownIt)
        XCTAssertEqual(output.diagnostics.fallbackReason, "unified bundle missing")
        XCTAssertTrue(output.html.contains("markdown-it.min.js"))
        XCTAssertFalse(output.html.contains("scopy-unified-renderer.iife.js"))
    }
}
