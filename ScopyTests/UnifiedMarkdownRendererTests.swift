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
        XCTAssertTrue(output.html.contains("failUnifiedRender('unified api missing')"))
        XCTAssertTrue(output.html.contains("finish(false);"))
        XCTAssertTrue(output.html.contains("renderFailed"))
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

    func testUnifiedDocumentDoesNotFallbackToMarkdownItRuntime() {
        let base = MarkdownRenderContextResolver.defaultContext(for: referenceStyleNote)
        let context = base.withRenderer(.unified)

        let output = MarkdownHTMLRenderer.render(markdown: referenceStyleNote, context: context)

        XCTAssertFalse(output.html.contains("contrib/markdown-it.min.js"))
        XCTAssertFalse(output.html.contains("renderMarkdownItFallback"))
        XCTAssertFalse(output.html.contains("window.markdownit"))
        XCTAssertTrue(output.html.contains("failUnifiedRender('unified api missing')"))
        XCTAssertTrue(output.html.contains("failUnifiedRender('unified render exception')"))
        XCTAssertTrue(output.html.contains("window.__scopyRenderState.unifiedErrorReason"))
        XCTAssertTrue(output.html.contains("renderSucceeded"))
    }

    private var referenceStyleNote: String {
        """
        # 笔记：为什么宽基指数长期往往优于大多数主动投资

        **先把结论说准确。**
        更严谨的说法不是“宽基指数在大多数年份都赢主动投资”，而是：**在足够长的持有期里，传统、低成本、宽分散的指数基金，通常会跑赢大多数主动基金。**([投资者.gov][1])

        ## 一、先把概念讲清楚

        这份笔记里，我把“宽基指数”限定为：**跟踪传统、覆盖面较广、分散程度较高的市场指数基金**。

        [1]: https://www.investor.gov/introduction-investing/investing-basics/glossary/index-fund "Index Fund | Investor.gov"
        """
    }
}
