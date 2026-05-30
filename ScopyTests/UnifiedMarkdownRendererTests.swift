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
        XCTAssertTrue(output.html.contains("--scopy-code-bg"))
        XCTAssertTrue(output.html.contains(".hljs-keyword"))
        XCTAssertFalse(output.html.contains("markdown-it.min.js"))
        XCTAssertFalse(output.html.contains("contrib/highlight.min.js"))
        XCTAssertFalse(output.html.contains("highlight-github.min.css"))
    }

    func testUnifiedRendererNormalizesATXHeadingsBeforeEmbeddingSource() {
        let markdown = """
        #一级标题 `# H1`

        ##二级标题 `## H2`

            #indented code stays code

        ```markdown
        ###fenced code stays code
        ```
        """
        let base = MarkdownRenderContextResolver.defaultContext(for: markdown)
        let context = base.withRenderer(.unified)

        let output = MarkdownHTMLRenderer.render(markdown: markdown, context: context)

        XCTAssertEqual(output.diagnostics.renderer, .unified)
        XCTAssertTrue(output.html.contains("# 一级标题 `# H1`"))
        XCTAssertTrue(output.html.contains("## 二级标题 `## H2`"))
        XCTAssertTrue(output.html.contains("#indented code stays code"))
        XCTAssertTrue(output.html.contains("###fenced code stays code"))
        XCTAssertFalse(output.html.contains("#一级标题 `# H1`"))
        XCTAssertFalse(output.html.contains("##二级标题 `## H2`"))
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

    func testUnifiedDocumentInstallsSourceCitationNormalizer() {
        let markdown = """
        **今天要闻**

        1. **美国在印太对华措辞转温和**：美国防长重申印太承诺。([AP News][1], [Reuters][2])

        [1]: https://apnews.com/article/d6cf2b964940f47a83f0a6f587c7e0c3?utm_source=chatgpt.com "Hegseth reassures Pacific allies"
        [2]: https://www.reuters.com/markets/example?utm_source=chatgpt.com "Reuters source"
        """
        let base = MarkdownRenderContextResolver.defaultContext(for: markdown)
        let context = base.withRenderer(.unified)

        let output = MarkdownHTMLRenderer.render(markdown: markdown, context: context)

        XCTAssertTrue(output.html.contains("normalizeSourceCitations(el,"))
        XCTAssertTrue(output.html.contains("extractScopySourceCitations(markdown)"))
        XCTAssertTrue(output.html.contains("scopy-source-citation-link"))
        XCTAssertTrue(output.html.contains("data-scopy-source-citation"))
        XCTAssertTrue(output.html.contains("data-scopy-source-count"))
        XCTAssertTrue(output.html.contains("AP News"))
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
