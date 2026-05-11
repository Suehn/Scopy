import XCTest

final class UnifiedMarkdownRendererTests: XCTestCase {
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
}
