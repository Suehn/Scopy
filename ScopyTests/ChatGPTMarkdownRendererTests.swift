import XCTest
import ScopyKit

final class ChatGPTMarkdownRendererTests: XCTestCase {
    func testDelimiterFixtureReachesSharedRuntimeWithoutRewritingMoneyOrCode() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "markdown_delimiter_repro", withExtension: "md"))
        let source = try String(contentsOf: url, encoding: .utf8)
        let html = MarkdownHTMLRenderer.render(markdown: source)
        let literal = try String(decoding: JSONEncoder().encode(source), as: UTF8.self)

        XCTAssertTrue(html.contains("window.ScopyUnifiedMarkdown.render(\(literal),"))
        XCTAssertTrue(source.contains("这是**$E=mc^2$**对应的公式"))
        XCTAssertTrue(source.contains("价格 $5 和 $10"))
        XCTAssertTrue(source.contains("`**粗体** $x$`"))
    }

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

    func testRendererWaitsForImagesToReachATerminalState() {
        let html = MarkdownHTMLRenderer.render(markdown: "![diagram](data:image/png;base64,broken)")

        XCTAssertTrue(html.contains("function settleRenderedImages(root, completion)"))
        XCTAssertTrue(html.contains("image.decode().then("))
        XCTAssertTrue(html.contains("data-scopy-image-state"))
        XCTAssertTrue(html.contains("scopy-image-terminal-fallback"))
        XCTAssertTrue(html.contains("img:not([data-scopy-deferred-image])"))
        XCTAssertTrue(html.contains("function awaitTerminalReadiness(root)"))
        XCTAssertTrue(html.contains("state.imagesReady = true"))
        XCTAssertTrue(html.contains("awaitTerminalReadiness(el)"))
        XCTAssertFalse(html.contains("content-visibility: auto"))
    }

    func testRendererPublishesReadinessOnlyAfterLocalAssetsFontsAndPaint() {
        let html = MarkdownHTMLRenderer.render(markdown: "$$E=mc^2$$")

        XCTAssertTrue(html.contains("id=\"scopy-katex-stylesheet\""))
        XCTAssertTrue(html.contains("function awaitStylesheetReady(completion)"))
        XCTAssertTrue(html.contains("function awaitFontsReady(completion)"))
        XCTAssertTrue(html.contains("function awaitTwoPaintFrames(completion)"))
        XCTAssertTrue(html.contains("KaTeX font failed:"))
        XCTAssertTrue(html.contains("completion('paint timeout')"))
        XCTAssertTrue(html.contains("var pending = 3"))
        XCTAssertTrue(html.contains("!!state.stylesheetReady && !!state.fontsReady && !!state.imagesReady && !!state.paintReady"))
        XCTAssertTrue(html.contains("state.paintReady = true;"))
        XCTAssertTrue(html.contains("finish(true);"))
        XCTAssertTrue(html.contains("window.syncChatGPTZoomShell = syncChatGPTZoomShell"))
    }

    func testRichHydrationFailureCannotReplaceSuccessfullyRenderedStaticDOM() {
        let html = MarkdownHTMLRenderer.render(markdown: "```scopy-rich\n{\"version\":2,\"type\":\"currency\",\"state\":\"ready\",\"from\":{\"code\":\"USD\"},\"to\":{\"code\":\"CNY\"},\"amount\":1,\"rate\":7}\n```")

        XCTAssertTrue(html.contains("el.innerHTML = result.html;"))
        XCTAssertTrue(html.contains("window.__scopyRenderState.hydrationWarning"))
        XCTAssertTrue(html.contains("rich hydration failed"))
        XCTAssertTrue(html.contains("awaitTerminalReadiness(el)"))
    }

    func testClosedSafeHTMLExtensionHasOneResponsiveStyleAndExportContract() {
        let html = MarkdownHTMLRenderer.render(markdown: "<u>u</u> <kbd>K</kbd> <mark>m</mark> H<sub>2</sub> x<sup>2</sup>\n\n<details><summary>More</summary>\n\nBody\n\n</details>")

        XCTAssertTrue(html.contains("u.scopy-safe-html-u"))
        XCTAssertTrue(html.contains("kbd.scopy-safe-html-kbd"))
        XCTAssertTrue(html.contains("mark.scopy-safe-html-mark"))
        XCTAssertTrue(html.contains("sub.scopy-safe-html-sub"))
        XCTAssertTrue(html.contains("details.scopy-safe-details"))
        XCTAssertTrue(html.contains("summary.scopy-safe-summary"))
        XCTAssertTrue(html.contains("html.scopy-export-mode summary.scopy-safe-summary"))
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
        XCTAssertTrue(html.contains(".scopy-math-inline-host {"))
        XCTAssertTrue(html.contains("display: inline-block;"))
        XCTAssertTrue(html.contains(".scopy-math-inline-host::-webkit-scrollbar"))
        XCTAssertTrue(html.contains("white-space: nowrap;"))
        XCTAssertTrue(html.contains("overflow-wrap: anywhere;"))
        XCTAssertFalse(html.contains("overflow-wrap: break-word;"))
    }

    func testRichSurfacesUseOneOfflineResponsiveStyleContract() {
        let html = MarkdownHTMLRenderer.render(markdown: "```scopy-rich\n{\"version\":2,\"type\":\"currency\",\"state\":\"ready\",\"from\":{\"code\":\"USD\"},\"to\":{\"code\":\"CNY\"},\"amount\":100,\"rate\":6.7199,\"fractionDigits\":2}\n```")

        XCTAssertTrue(html.contains(".scopy-rich {"))
        XCTAssertTrue(html.contains("#content > .scopy-rich"))
        XCTAssertTrue(html.contains("width: min(var(--scopy-chatgpt-thread-content-max-width)"))
        XCTAssertTrue(html.contains("container-type: inline-size;"))
        XCTAssertTrue(html.contains("border-radius: var(--scopy-rich-card-radius);"))
        XCTAssertTrue(html.contains(".scopy-rich-news-card"))
        XCTAssertTrue(html.contains("--scopy-rich-news-card-ideal-width: 15.33rem;"))
        XCTAssertTrue(html.contains("flex: 0 0 min(var(--scopy-rich-news-card-ideal-width), calc(100% - 24px));"))
        XCTAssertTrue(html.contains("@container (min-width: 48rem)"))
        XCTAssertTrue(html.contains("flex-basis: calc((100% - (var(--scopy-rich-column-gap) * 2)) / 3);"))
        XCTAssertFalse(html.contains("min-height: 293px;"))
        XCTAssertTrue(html.contains(".scopy-rich-image-layout-search"))
        XCTAssertTrue(html.contains(".scopy-rich-image-layout-carousel"))
        XCTAssertTrue(html.contains("@container (min-width: 24.5rem)"))
        XCTAssertTrue(html.contains("flex-basis: calc((100% - (var(--scopy-rich-image-gap) * 2)) / 3);"))
        XCTAssertTrue(html.contains(".scopy-rich-weather-card"))
        XCTAssertTrue(html.contains(".scopy-rich-weather-days"))
        XCTAssertTrue(html.contains("flex: 1 0 90px;"))
        XCTAssertTrue(html.contains(".scopy-rich-weather-chart-title .scopy-icon"))
        XCTAssertTrue(html.contains(".scopy-rich-finance-ranges"))
        XCTAssertTrue(html.contains("grid-auto-columns: minmax(var(--scopy-rich-range-min-width), 1fr);"))
        XCTAssertTrue(html.contains("--scopy-rich-range-min-width: 4.5rem;"))
        XCTAssertTrue(html.contains(".scopy-rich-finance-chart svg"))
        XCTAssertTrue(html.contains("height: clamp(200px, 31.25cqi, 240px);"))
        XCTAssertTrue(html.contains("grid-template-columns: repeat(auto-fit, minmax(min(12rem, 100%), 1fr));"))
        XCTAssertTrue(html.contains(".scopy-rich-currency-card"))
        XCTAssertTrue(html.contains("min-height: 199px;"))
        XCTAssertTrue(html.contains("window.ScopyUnifiedMarkdown.hydrateRich"))
        XCTAssertTrue(html.contains("{ exportMode: exportMode }"))
        XCTAssertTrue(html.contains("html.scopy-export-mode .scopy-rich-lightbox"))
        XCTAssertTrue(html.contains("unicode-bidi: isolate;"))
        XCTAssertTrue(html.contains("overflow-x: auto;"))
        XCTAssertFalse(html.contains("content-visibility: auto"))
        XCTAssertFalse(html.contains(".scopy-rich-weather-daily"))
        XCTAssertFalse(html.contains(".scopy-rich-currency-pair"))
    }

    func testCitationCountAndSupportingSourcesAreRealAccessibleDOM() {
        let html = MarkdownHTMLRenderer.render(markdown: "([Primary][p], [Secondary][s])\n\n[p]: https://primary.example/a\n[s]: https://secondary.example/b")

        XCTAssertTrue(html.contains(".scopy-source-citation-count"))
        XCTAssertTrue(html.contains(".scopy-source-citation-supporting"))
        XCTAssertTrue(html.contains("left: var(--scopy-source-popup-left, 0px);"))
        XCTAssertTrue(html.contains("--scopy-source-popup-max-width"))
        XCTAssertTrue(html.contains("inset-block-start: calc(100% - 1px);"))
        XCTAssertTrue(html.contains(":focus-within"))
        XCTAssertTrue(html.contains("inset-block-start: calc(100% - 1px);"))
        XCTAssertTrue(html.contains("width: min(320px, var(--scopy-source-popup-max-width, calc(100vw - 24px)));"))
        XCTAssertFalse(html.contains("content: attr(data-scopy-source-count)"))
        XCTAssertFalse(html.contains("function normalizeSourceCitations"))
        XCTAssertFalse(html.contains("extractScopySourceCitations"))
    }

    func testThreadWidthUsesLogicalLayoutViewportThreshold() {
        let narrowContext = MarkdownRenderContextResolver.defaultContext(
            for: "Text",
            layoutScale: .percent125
        )
        let wideContext = MarkdownRenderContextResolver.defaultContext(
            for: "Text",
            layoutScale: .percent100
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
        // The 816px output surface is the canonical wide desktop state: 100% scale renders the
        // 48rem column, and only zooming in (logical viewport < 816) selects the 40rem column.
        XCTAssertEqual(
            MarkdownRenderLayoutConstants.chatGPTWideThreadMinimumViewportWidth,
            MarkdownRenderLayoutConstants.chatGPTOutputSurfaceWidth
        )
        XCTAssertEqual(
            MarkdownRenderLayoutConstants.threadContentWidth(forLayoutViewportWidth: 815.999),
            640
        )
        XCTAssertEqual(
            MarkdownRenderLayoutConstants.threadContentWidth(forLayoutViewportWidth: 816),
            768
        )
        XCTAssertEqual(
            MarkdownRenderLayoutConstants.threadContentWidth(
                forLayoutViewportWidth: MarkdownChatGPTLayoutScalePercent.percent125
                    .layoutViewportWidth(outputSurfaceWidth: 816)
            ),
            640
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

    func testAuthoredAndChatGPTSourcesBypassScientificMathPreprocessing() throws {
        let source = #"Literal $\text{drop_last}$, $\label{kept}$, $\mathbb{R}\setminus\{0\}$, and \\text stay byte-for-byte."#
        let contexts = [MarkdownSourceProfile.authoredMarkdown, .chatGPTMarkdown].map { profile in
            MarkdownRenderContext(
                profile: profile,
                policy: .conservativeDefault(for: profile),
                layoutScale: MarkdownRenderLayoutConstants.defaultChatGPTLayoutScale
            )
        }
        let sourceLiteral = String(data: try JSONEncoder().encode(source), encoding: .utf8)!

        for context in contexts {
            let html = MarkdownHTMLRenderer.render(markdown: source, context: context).html
            XCTAssertTrue(html.contains("ScopyUnifiedMarkdown.render(\(sourceLiteral),"), "profile=\(context.profile)")
        }
    }

    func testCacheKeyHasOneRendererVersionAndLayoutScale() {
        let context = MarkdownRenderContextResolver.defaultContext(
            for: "[doc](/Users/alice/a.md:1)",
            layoutScale: .percent125
        )

        let key = MarkdownRenderCacheKey.make(contentHash: "hash-z", context: context)

        XCTAssertEqual(
            key,
            "md|\(MarkdownRenderContextResolver.rendererVersion)|chatGPTMarkdown|chatgpt-layout-125|plain|hash-z"
        )
        XCTAssertFalse(key.contains("legacy"))
        XCTAssertEqual(MarkdownRenderCacheKey.make(contentHash: "", context: context), "")

        var enriched = context
        enriched.linkEnrichment = LinkEnrichmentPayload(
            version: LinkEnrichmentPayload.formatVersion,
            fetchedAt: Date(),
            entries: ["https://example.com": .init(title: "T")]
        )
        let enrichedKey = MarkdownRenderCacheKey.make(contentHash: "hash-z", context: enriched)
        XCTAssertNotEqual(enrichedKey, key, "the enrichment fingerprint participates in the cache key")
        XCTAssertFalse(enrichedKey.contains("|plain|"))
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

    func testMetricsScriptCoalescesGenerationScopedLayoutAndInteractionReports() {
        let html = MarkdownHTMLRenderer.render(markdown: "<details><summary>More</summary>Body</details>")

        XCTAssertTrue(html.contains("if (!state.renderComplete) { return; }"))
        XCTAssertTrue(html.contains("pendingHeightReportForce = pendingHeightReportForce || !!force"))
        XCTAssertTrue(html.contains("window.requestAnimationFrame(deliver)"))
        XCTAssertTrue(html.contains("currentRenderGeneration() !== scheduledGeneration"))
        XCTAssertTrue(html.contains("new window.ResizeObserver"))
        XCTAssertTrue(html.contains("currentRenderGeneration() !== observedGeneration"))
        XCTAssertTrue(html.contains("el.addEventListener('toggle'"))
        XCTAssertTrue(html.contains("el.addEventListener('keydown'"))
        XCTAssertTrue(html.contains("document.fonts.ready.then"))
    }

    func testAnswerDirectionAndDirectionalSpacingUseLogicalCSS() {
        let html = MarkdownHTMLRenderer.render(markdown: "> مرحبا\n\n- שלום")

        XCTAssertTrue(html.contains("id=\"content\" dir=\"auto\""))
        XCTAssertTrue(html.contains("padding-inline-start: 26px;"))
        XCTAssertTrue(html.contains("padding-inline-start: 24px;"))
        XCTAssertTrue(html.contains("inset-inline-start: 0;"))
        XCTAssertFalse(html.contains("padding-left: 26px;"))
    }

    func testPreviewLinksAreInteractiveButExportsRemainInert() {
        let html = MarkdownHTMLRenderer.render(markdown: "[OpenAI](https://openai.com)")

        XCTAssertTrue(html.contains("a.scopy-link--external,"))
        XCTAssertTrue(html.contains("a.scopy-link--file-resolvable,"))
        XCTAssertTrue(html.contains("pointer-events: auto;"))
        XCTAssertTrue(html.contains("--scopy-link-color: rgb(46, 131, 210);"))
        XCTAssertTrue(html.contains("a.scopy-link:focus-visible"))
        XCTAssertTrue(html.contains(".scopy-link-origin-icon"))
        XCTAssertTrue(html.contains(".scopy-mention-icon > svg"))
        XCTAssertTrue(html.contains("a[data-footnote-backref]"))
        XCTAssertTrue(html.contains("html.scopy-export-mode a"))
        XCTAssertTrue(html.contains("pointer-events: none;"))
        XCTAssertFalse(html.contains("content: \"↗\""))
        XCTAssertFalse(html.contains("a.scopy-external-link"))
        XCTAssertTrue(html.contains("base-uri 'none'"))
        XCTAssertTrue(html.contains("connect-src 'none'"))
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
