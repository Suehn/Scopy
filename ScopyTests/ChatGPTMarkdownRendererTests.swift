import XCTest
import ScopyKit

final class ChatGPTMarkdownRendererTests: XCTestCase {
    func testRendererBuildsOneLocalStandaloneDocument() {
        let html = MarkdownHTMLRenderer.render(markdown: "# Title\n\n\\(x + y\\)")

        XCTAssertTrue(html.contains("contrib/scopy-unified-renderer.iife.js"))
        XCTAssertTrue(html.contains("katex.min.css"))
        XCTAssertTrue(html.contains("window.__scopyIsRenderReady"))
        XCTAssertTrue(html.contains("data-scopy-render-id=\"\(MarkdownPreviewRenderIdentity.placeholder)\""))
        XCTAssertTrue(html.contains("renderID: document.documentElement.getAttribute('data-scopy-render-id')"))
        XCTAssertFalse(html.contains("markdown-it"))
        XCTAssertFalse(html.contains("renderMarkdownItFallback"))
        XCTAssertFalse(html.contains("window.markdownit"))
        XCTAssertFalse(html.contains("auto-render.min.js"))
        XCTAssertFalse(html.contains("katex.min.js"))
    }

    func testRendererNormalizesATXHeadingsWithoutTouchingCode() {
        let markdown = """
        #一级标题 `# H1`

            #indented code stays code

        ```markdown
        ###fenced code stays code
        ```
        """

        let html = MarkdownHTMLRenderer.render(markdown: markdown)

        XCTAssertTrue(html.contains("# 一级标题 `# H1`"))
        XCTAssertTrue(html.contains("#indented code stays code"))
        XCTAssertTrue(html.contains("###fenced code stays code"))
        XCTAssertFalse(html.contains("#一级标题 `# H1`"))
    }

    func testScriptBreakingSourceIsEncodedAsData() {
        let source = "</script><script>globalThis.pwned=true</script>"
        let html = MarkdownHTMLRenderer.render(markdown: source)

        XCTAssertFalse(html.contains(source))
        XCTAssertTrue(html.contains("<\\/script>"))
        XCTAssertTrue(html.contains("globalThis.pwned=true"))
    }

    func testChatGPTTypographyAndBlockRhythmContract() {
        let html = MarkdownHTMLRenderer.render(markdown: "# H1\n\n## H2\n\nText")

        XCTAssertTrue(html.contains("--scopy-chatgpt-body-font-size: calc(16px"))
        XCTAssertTrue(html.contains("--scopy-chatgpt-body-line-height: calc(26px"))
        XCTAssertTrue(html.contains("--scopy-chatgpt-h1-font-size: calc(24px"))
        XCTAssertTrue(html.contains("--scopy-chatgpt-h1-line-height: calc(32px"))
        XCTAssertTrue(html.contains("--scopy-chatgpt-h2-font-size: calc(20px"))
        XCTAssertTrue(html.contains("--scopy-chatgpt-h2-line-height: calc(28px"))
        XCTAssertTrue(html.contains("--scopy-chatgpt-h3-font-size: calc(18px"))
        XCTAssertTrue(html.contains("--scopy-chatgpt-h4-line-height: calc(24px"))
        XCTAssertTrue(html.contains("margin: 4px 0;"))
        XCTAssertTrue(html.contains("p + p {"))
        XCTAssertTrue(html.contains("margin: 16px 0;"))
        XCTAssertTrue(html.contains("padding-inline-start: 26px;"))
        XCTAssertTrue(html.contains("padding-block: 8px;"))
        XCTAssertTrue(html.contains("padding-inline-start: 24px;"))
        XCTAssertFalse(html.contains("margin: 8px 0 4px 0;"))
        XCTAssertFalse(html.contains("h3 code {"))
    }

    func testCodeTableMathAndOverflowContract() {
        let html = MarkdownHTMLRenderer.render(markdown: "```swift\nlet x = 1\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n\\[x+y\\]")

        XCTAssertTrue(html.contains("--scopy-chatgpt-code-card-font-size: calc(14px"))
        XCTAssertTrue(html.contains("--scopy-chatgpt-code-card-line-height: calc(20px"))
        XCTAssertTrue(html.contains("overflow-x: auto;"))
        XCTAssertTrue(html.contains("white-space: pre;"))
        XCTAssertTrue(html.contains("min-width: max-content;"))
        XCTAssertTrue(html.contains("table {"))
        XCTAssertTrue(html.contains("font-size: calc(14px * var(--scopy-chatgpt-layout-font-scale));"))
        XCTAssertTrue(html.contains("line-height: calc(24px * var(--scopy-chatgpt-layout-font-scale));"))
        XCTAssertTrue(html.contains("th {"))
        XCTAssertTrue(html.contains("line-height: calc(16px * var(--scopy-chatgpt-layout-font-scale));"))
        XCTAssertTrue(html.contains("padding-block: 8px;"))
        XCTAssertTrue(html.contains("font-size: 1.21em;"))
        XCTAssertTrue(html.contains("line-height: 1.2;"))
        XCTAssertTrue(html.contains("unicode-bidi: isolate;"))
        XCTAssertTrue(html.contains("white-space: nowrap;"))
        XCTAssertTrue(html.contains("overflow-wrap: anywhere;"))
        XCTAssertFalse(html.contains("overflow-wrap: break-word;"))
    }

    func testThreadWidthUsesLogicalLayoutViewportThreshold() {
        let narrowContext = MarkdownRenderContextResolver.defaultContext(
            for: "Text",
            layoutScale: .percent125
        )
        let wideContext = MarkdownRenderContextResolver.defaultContext(
            for: "Text",
            layoutScale: MarkdownChatGPTLayoutScalePercent(rawValue: 95)
        )
        let narrowOutput = MarkdownHTMLRenderer.render(markdown: "Text", context: narrowContext)
        let wideOutput = MarkdownHTMLRenderer.render(markdown: "Text", context: wideContext)

        XCTAssertTrue(narrowOutput.html.contains("--scopy-chatgpt-thread-content-max-width: 640.0px;"))
        XCTAssertFalse(narrowOutput.html.contains("--scopy-chatgpt-thread-content-max-width: 768.0px;"))
        XCTAssertTrue(wideOutput.html.contains("--scopy-chatgpt-thread-content-max-width: 768.0px;"))
        XCTAssertFalse(wideOutput.html.contains("--scopy-chatgpt-thread-content-max-width: 640.0px;"))
        XCTAssertFalse(narrowOutput.html.contains("@media (min-width: 856.0px)"))
        XCTAssertFalse(wideOutput.html.contains("@media (min-width: 856.0px)"))
        XCTAssertTrue(narrowOutput.html.contains("--scopy-chatgpt-output-surface-width: 816.0px;"))
        XCTAssertTrue(narrowOutput.html.contains("margin-inline: auto;"))
        XCTAssertTrue(narrowOutput.html.contains("min-width: var(--scopy-chatgpt-thread-content-width);"))
        XCTAssertTrue(narrowOutput.html.contains("--scopy-chatgpt-browser-zoom: 1.25;"))
        XCTAssertEqual(narrowContext.layoutScale, .percent125)
        XCTAssertEqual(MarkdownRenderLayoutConstants.renderWidth(for: .percent125), 816)
        XCTAssertEqual(
            MarkdownRenderLayoutConstants.threadContentWidth(forLayoutViewportWidth: 855.999),
            640
        )
        XCTAssertEqual(
            MarkdownRenderLayoutConstants.threadContentWidth(forLayoutViewportWidth: 856),
            768
        )
        XCTAssertEqual(
            MarkdownRenderLayoutConstants.threadContentWidth(forLayoutViewportWidth: .infinity),
            640
        )
    }

    func testSourceProfilesOnlyControlBoundedInputRepair() {
        let chatGPT = MarkdownRenderContextResolver.defaultContext(for: "[doc](/Users/alice/a.md:1)")
        let latex = MarkdownRenderContextResolver.defaultContext(
            for: "\\documentclass{article}\n\\begin{document}\n\\section{A}\n\\end{document}"
        )
        let ocr = MarkdownRenderContextResolver.defaultContext(
            for: "(\\mathcal{A}) (\\mathcal{B}) (\\mathcal{C})"
        )

        XCTAssertEqual(chatGPT.profile, .chatGPTMarkdown)
        XCTAssertFalse(chatGPT.policy.allowLatexDocumentNormalize)
        XCTAssertFalse(chatGPT.policy.allowLooseMathRepair)
        XCTAssertEqual(latex.profile, .latexDocumentLike)
        XCTAssertTrue(latex.policy.allowLatexDocumentNormalize)
        XCTAssertTrue(latex.policy.allowLooseMathRepair)
        XCTAssertEqual(ocr.profile, .pdfOCRScientific)
        XCTAssertTrue(ocr.policy.allowLooseMathRepair)
    }

    func testCacheKeyHasOneRendererVersionAndLayoutScale() {
        let context = MarkdownRenderContextResolver.defaultContext(
            for: "[doc](/Users/alice/a.md:1)",
            layoutScale: .percent125
        )

        let key = MarkdownRenderCacheKey.make(contentHash: "hash-z", context: context)

        XCTAssertEqual(
            key,
            "md|\(MarkdownRenderContextResolver.rendererVersion)|chatGPTMarkdown|chatgpt-layout-125|hash-z"
        )
        XCTAssertFalse(key.contains("legacy"))
        XCTAssertEqual(MarkdownRenderCacheKey.make(contentHash: "", context: context), "")
    }

    func testRenderIdentityInjectionIsPerLoadAndEscapesNoContent() {
        let html = "<html data-scopy-render-id=\"\(MarkdownPreviewRenderIdentity.placeholder)\"><body>正文 \(MarkdownPreviewRenderIdentity.placeholder)</body></html>"
        let first = MarkdownPreviewRenderIdentity.injecting("render-a", into: html)
        let second = MarkdownPreviewRenderIdentity.injecting("render-b", into: html)

        XCTAssertTrue(first.contains("data-scopy-render-id=\"render-a\""))
        XCTAssertTrue(second.contains("data-scopy-render-id=\"render-b\""))
        XCTAssertTrue(first.contains("正文 \(MarkdownPreviewRenderIdentity.placeholder)"))
        XCTAssertNotEqual(first, second)
    }

    func testMetricsScriptTracksOverflowAndRenderOutcomeWithoutSizeChanges() {
        let html = MarkdownHTMLRenderer.render(markdown: "Inline \\(x\\)")

        XCTAssertTrue(html.contains("pre, .katex, .footnotes"))
        XCTAssertTrue(html.contains("overflowX === lastOverflowX"))
        XCTAssertTrue(html.contains("renderSucceeded === lastRenderSucceeded"))
        XCTAssertTrue(html.contains("renderErrorReason === lastRenderErrorReason"))
    }

    func testAnswerDirectionAndDirectionalSpacingUseLogicalCSS() {
        let html = MarkdownHTMLRenderer.render(markdown: "> مرحبا\n\n- שלום")

        XCTAssertTrue(html.contains("id=\"content\" dir=\"auto\""))
        XCTAssertTrue(html.contains("padding-inline-start: 26px;"))
        XCTAssertTrue(html.contains("padding-inline-start: 24px;"))
        XCTAssertTrue(html.contains("inset-inline-start: 0;"))
        XCTAssertFalse(html.contains("padding-left: 26px;"))
    }

    func testMetricsDedupeIncludesRenderOutcomeAndGeneration() {
        let base = MarkdownContentMetrics(
            size: CGSize(width: 640, height: 400),
            hasHorizontalOverflow: false,
            renderSucceeded: true,
            renderID: "a"
        )
        let withinPixel = MarkdownContentMetrics(
            size: CGSize(width: 640.5, height: 400.5),
            hasHorizontalOverflow: false,
            renderSucceeded: true,
            renderID: "a"
        )
        let failed = MarkdownContentMetrics(
            size: base.size,
            hasHorizontalOverflow: false,
            renderSucceeded: false,
            renderErrorReason: "renderer failed",
            renderID: "a"
        )
        let nextGeneration = MarkdownContentMetrics(
            size: base.size,
            hasHorizontalOverflow: false,
            renderSucceeded: true,
            renderID: "b"
        )

        XCTAssertTrue(base.isEquivalent(to: withinPixel))
        XCTAssertFalse(base.isEquivalent(to: failed))
        XCTAssertFalse(base.isEquivalent(to: nextGeneration))
    }
}
