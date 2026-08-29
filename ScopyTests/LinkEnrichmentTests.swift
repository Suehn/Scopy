import XCTest
@testable import Scopy

final class LinkEnrichmentTests: XCTestCase {
    func testAssistantContentGateRecognizesChatGPTCodexAndCitationShapes() {
        XCTAssertTrue(LinkEnrichmentEligibility.isAssistantContent(
            "看这里。\n\n- [OpenAI](https://openai.com/index/a/?utm_source=chatgpt.com)\n"
        ), "ChatGPT copy rewrites links with utm_source=chatgpt.com")
        XCTAssertTrue(LinkEnrichmentEligibility.isAssistantContent(
            "# Plan\n\nSee [render.js](/Users/hh/code/render.js:12) for details."
        ), "Codex output uses absolute local file destinations")
        XCTAssertTrue(LinkEnrichmentEligibility.isAssistantContent(
            "# 今日要闻\n\n结论如上。([AP News][1])\n\n[1]: https://apnews.com/article/x\n"
        ), "assistant markdown with reference citations and headings")
        XCTAssertFalse(LinkEnrichmentEligibility.isAssistantContent(
            "随手记的一段话，带一个链接 https://example.com 而已。"
        ))
        XCTAssertFalse(LinkEnrichmentEligibility.isAssistantContent(
            "- [OpenAI](https://openai.com/index/a/)\n- [OpenAI](https://openai.com/index/b/)\n"
        ), "bare link lists without any assistant signal stay ineligible")
    }

    func testCandidateURLExtractionMatchesOnlyBareLinkLines() {
        let markdown = """
        # 新闻

        - [OpenAI](https://openai.com/index/a/?utm_source=chatgpt.com)
        - [OpenAI](https://openai.com/index/b/?utm_source=chatgpt.com)

        [Solo article](https://example.com/story)

        正文里的 [inline link](https://example.com/inline) 不算。
        - [Video](https://www.youtube.com/watch?v=abc) 已有视频卡，不抓取。
        """
        let urls = LinkEnrichmentEligibility.candidateURLs(in: markdown)
        XCTAssertEqual(urls, [
            "https://openai.com/index/a/?utm_source=chatgpt.com",
            "https://openai.com/index/b/?utm_source=chatgpt.com",
            "https://example.com/story"
        ])
    }

    func testCandidateURLsUnescapeMarkdownPunctuationSoFetchedAndParsedURLsMatch() {
        let markdown = """
        # 图

        - [Image](https://images.example.com/a.png?fm=webp\\&q=90\\&w=3840&utm_source=chatgpt.com)
        - [Image](https://images.example.com/b.png?fm=webp\\&q=90&utm_source=chatgpt.com)
        """
        XCTAssertEqual(LinkEnrichmentEligibility.candidateURLs(in: markdown), [
            "https://images.example.com/a.png?fm=webp&q=90&w=3840&utm_source=chatgpt.com",
            "https://images.example.com/b.png?fm=webp&q=90&utm_source=chatgpt.com"
        ], "backslash-escaped ampersands must unescape to match the parsed AST URL")
    }

    func testPayloadFingerprintIsOrderIndependentAndContentSensitive() {
        let a = LinkEnrichmentPayload(
            version: 1, fetchedAt: Date(timeIntervalSince1970: 0),
            entries: ["u1": .init(title: "A"), "u2": .init(title: "B")]
        )
        let b = LinkEnrichmentPayload(
            version: 1, fetchedAt: Date(timeIntervalSince1970: 999),
            entries: ["u2": .init(title: "B"), "u1": .init(title: "A")]
        )
        var c = a
        c.entries["u1"] = .init(title: "Changed")
        XCTAssertEqual(a.fingerprint, b.fingerprint)
        XCTAssertNotEqual(a.fingerprint, c.fingerprint)
    }

    func testStoreRoundTripAndMissReturnsNil() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-enrichment-tests-\(UUID().uuidString)")
        let store = LinkEnrichmentStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNil(store.payload(forContentKey: "missing"))
        let payload = LinkEnrichmentPayload(
            version: LinkEnrichmentPayload.formatVersion,
            fetchedAt: Date(),
            entries: ["https://example.com": .init(title: "Example", source: "example.com")]
        )
        store.write(payload, forContentKey: "key1")
        XCTAssertEqual(store.payload(forContentKey: "key1"), payload)

        let fresh = LinkEnrichmentStore(directory: directory)
        XCTAssertEqual(fresh.payload(forContentKey: "key1"), payload)
    }

    func testDecodeEntitiesHandlesNamedAndNumericForms() {
        XCTAssertEqual(
            LinkEnrichmentFetcher.decodeEntities("Apple&#8217;s &#x201C;M5&#x201D; &amp; beyond&nbsp;&#8212; a&#32;test"),
            "Apple\u{2019}s \u{201C}M5\u{201D} & beyond\u{00A0}\u{2014} a test"
        )
        XCTAssertEqual(
            LinkEnrichmentFetcher.decodeEntities("&lt;tag&gt; &quot;q&quot; &#39;a&#39; &#xh; &#; &#2000000000;"),
            "<tag> \"q\" 'a' &#xh; &#; &#2000000000;",
            "malformed or out-of-range references stay literal"
        )
    }

    /// Live-network verification, excluded from regular suites.
    /// Run manually with TEST_RUNNER_SCOPY_NETWORK_TESTS=1 on the focused xcodebuild test
    /// invocation (xcodebuild forwards only TEST_RUNNER_-prefixed variables to XCTest).
    func testLiveFetchProducesFrozenEntriesForRealArticle() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SCOPY_NETWORK_TESTS"] == "1"
                || ProcessInfo.processInfo.environment["TEST_RUNNER_SCOPY_NETWORK_TESTS"] == "1",
            "network-gated; set SCOPY_NETWORK_TESTS=1 to run"
        )
        let fetcher = LinkEnrichmentFetcher()
        let entries = await fetcher.enrich(urls: ["https://openai.com/index/introducing-chatgpt-search/"])
        let entry = try XCTUnwrap(entries["https://openai.com/index/introducing-chatgpt-search/"])
        XCTAssertFalse(entry.title.isEmpty)
        if let image = entry.image {
            XCTAssertTrue(image.hasPrefix("data:image/"))
        }
    }
}
