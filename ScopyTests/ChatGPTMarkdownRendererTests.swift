import XCTest
import ScopyKit

final class ChatGPTMarkdownRendererTests: XCTestCase {
    /// The shell is data plus references: two local stylesheets, one deferred local bundle, the render input as
    /// inert JSON, and a CSP that forbids inline script.
    func testRendererBuildsOneLocalStandaloneDocument() throws {
        let html = MarkdownHTMLDocumentBuilder.document(source: "# Title\n\n\\(x + y\\)")

        XCTAssertTrue(html.contains("<html data-scopy-render-id=\"\(MarkdownPreviewRenderIdentity.placeholder)\">"))
        XCTAssertEqual(tagMatches(#"<link [^>]*>"#, in: html), [
            #"<link id="scopy-katex-stylesheet" rel="stylesheet" href="katex.min.css">"#,
            #"<link id="scopy-document-stylesheet" rel="stylesheet" href="scopy-document.css">"#
        ])
        XCTAssertEqual(tagMatches(#"<script[^>]*>"#, in: html), [
            #"<script type="application/json" id="scopy-render-input">"#,
            #"<script defer src="contrib/scopy-unified-renderer.iife.js">"#
        ])
        let policy = try XCTUnwrap(tagMatches(#"content="default-src[^"]*""#, in: html).first)
        XCTAssertTrue(policy.contains("script-src 'self' file:;"))
        XCTAssertFalse(policy.contains("script-src 'self' 'unsafe-inline'"))
        XCTAssertTrue(policy.contains("connect-src 'none'"))
        XCTAssertTrue(policy.contains("base-uri 'none'"))
        XCTAssertTrue(html.contains(#"<div id="content-scale-shell"><div id="content" dir="auto"></div></div>"#))
        XCTAssertEqual(try renderInput(in: html).source, "# Title\n\n\\(x + y\\)")
    }

    func testScriptBreakingSourceIsEncodedAsData() throws {
        let source = "</script><script>globalThis.pwned=true</script> <!--<script>"
        let html = MarkdownHTMLDocumentBuilder.document(source: source)

        XCTAssertFalse(html.contains("</script><script>globalThis"))
        XCTAssertFalse(html.contains("<!--"))
        XCTAssertEqual(try renderInput(in: html).source, source)
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
        let narrowOutput = MarkdownHTMLDocumentBuilder.document(source: "Text", context: narrowContext)
        let wideOutput = MarkdownHTMLDocumentBuilder.document(source: "Text", context: wideContext)

        XCTAssertTrue(narrowOutput.contains("--scopy-chatgpt-thread-content-max-width: 640.0px;"))
        XCTAssertFalse(narrowOutput.contains("--scopy-chatgpt-thread-content-max-width: 768.0px;"))
        XCTAssertTrue(wideOutput.contains("--scopy-chatgpt-thread-content-max-width: 768.0px;"))
        XCTAssertFalse(wideOutput.contains("--scopy-chatgpt-thread-content-max-width: 640.0px;"))
        XCTAssertTrue(narrowOutput.contains("--scopy-chatgpt-output-surface-width: 816.0px;"))
        XCTAssertTrue(narrowOutput.contains("--scopy-chatgpt-browser-zoom: 1.25;"))
        XCTAssertEqual(narrowContext.layoutScale, .percent125)
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

    func testCacheKeyHasOneRendererVersionAndLayoutScale() {
        let context = MarkdownRenderContextResolver.defaultContext(
            for: "[doc](/Users/alice/a.md:1)",
            layoutScale: .percent125
        )

        let key = MarkdownRenderCacheKey.make(input: context, itemKey: "hash-z")

        XCTAssertEqual(
            key,
            "md|\(MarkdownRenderContextResolver.rendererVersion)|chatGPTMarkdown|chatgpt-layout-125|plain|hash-z"
        )
        XCTAssertFalse(key.contains("legacy"))
        XCTAssertEqual(MarkdownRenderCacheKey.make(input: context, itemKey: ""), "")

        var enriched = context
        enriched.linkEnrichment = LinkEnrichmentPayload(
            version: LinkEnrichmentPayload.formatVersion,
            fetchedAt: Date(),
            entries: ["https://example.com": .init(title: "T")]
        )
        let enrichedKey = MarkdownRenderCacheKey.make(input: enriched, itemKey: "hash-z")
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

    func testEveryProfileEmbedsSourceVerbatim() throws {
        let casesData = try TestFixture.data("MarkdownRenderingCorpus/cases.json")
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: casesData) as? [[String: Any]])
        let fixtures = ["markdown_delimiter_repro.md"]
            + cases.compactMap { $0["file"] as? String }.map { "MarkdownRenderingCorpus/\($0)" }
        var checked = 0
        for fixture in fixtures {
            let source = try String(contentsOf: TestFixture.url(fixture), encoding: .utf8)
            let context = MarkdownRenderContextResolver.defaultContext(for: source)
            let html = MarkdownHTMLDocumentBuilder.document(source: source, context: context)
            XCTAssertEqual(Data(try renderInput(in: html).source.utf8), Data(source.utf8), fixture)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 12)
    }

    /// The `</head>` ruling: embedded source can never close the shell's own elements because
    /// JSONEncoder escapes `/` by default. `.withoutEscapingSlashes` must never be added.
    func testEmbeddedSourceKeepsDefaultSlashEscaping() throws {
        let html = MarkdownHTMLDocumentBuilder.document(source: "</head></script><script>x</script>")

        XCTAssertTrue(html.contains(#""source":"<\/head><\/script><script>x<\/script>""#))
        XCTAssertEqual(html.components(separatedBy: "</head>").count, 2, "only the shell's own head closes")
    }

    private struct RenderInput: Decodable {
        let source: String
    }

    private func renderInput(in html: String) throws -> RenderInput {
        let open = #"<script type="application/json" id="scopy-render-input">"#
        let start = try XCTUnwrap(html.range(of: open)).upperBound
        let end = try XCTUnwrap(html.range(of: "</script>", range: start..<html.endIndex)).lowerBound
        return try JSONDecoder().decode(RenderInput.self, from: Data(html[start..<end].utf8))
    }

    private func tagMatches(_ pattern: String, in html: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range, in: html).map { String(html[$0]) }
        }
    }
}
