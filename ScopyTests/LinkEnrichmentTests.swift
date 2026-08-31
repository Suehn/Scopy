import Foundation
import XCTest
@testable import Scopy
@testable import ScopyKit

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

    func testStoreMemoryCacheStaysWithinDiskEntryLimit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-enrichment-memory-tests-\(UUID().uuidString)")
        let store = LinkEnrichmentStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0...LinkEnrichmentStore.maximumEntries {
            store.write(
                LinkEnrichmentPayload(
                    version: LinkEnrichmentPayload.formatVersion,
                    fetchedAt: Date(),
                    entries: ["https://example.com/\(index)": .init(title: "Entry \(index)")]
                ),
                forContentKey: "key-\(index)"
            )
        }

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count,
            LinkEnrichmentStore.maximumEntries
        )
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("key-0.json"))
        XCTAssertNil(
            store.payload(forContentKey: "key-0"),
            "the oldest memory entry must be evicted when the shared 500-entry limit is exceeded"
        )
    }

    func testURLValidationRejectsNumericIPv4BypassAndPrivateDNSAnswers() {
        let numericFetcher = makeFetcher { _ in ["93.184.216.34"] }
        XCTAssertFalse(numericFetcher.isSafePublicURL("http://2130706433/secret"))
        XCTAssertFalse(numericFetcher.isSafePublicURL("http://198.18.0.6/secret"))
        XCTAssertFalse(numericFetcher.isSafePublicURL("https://198.19.255.254/secret"))

        let privateFetcher = makeFetcher { host in
            host == "private.example" ? ["192.168.1.20"] : ["93.184.216.34"]
        }
        XCTAssertFalse(privateFetcher.isSafePublicURL("https://private.example/secret"))

        let mixedFetcher = makeFetcher { _ in ["93.184.216.34", "192.168.1.20"] }
        XCTAssertFalse(mixedFetcher.isSafePublicURL("https://mixed.example/secret"))

        let unresolvedFetcher = makeFetcher { _ in nil }
        XCTAssertFalse(unresolvedFetcher.isSafePublicURL("https://unresolved.example/secret"))
        XCTAssertTrue(numericFetcher.isSafePublicURL("https://public.example/article"))

        let fakeIPFetcher = makeFetcher { _ in ["198.18.0.6"] }
        XCTAssertTrue(fakeIPFetcher.isSafePublicURL("http://public.example/article"))
        XCTAssertTrue(fakeIPFetcher.isSafePublicURL("https://public.example/article"))

        let fakeIPAndPrivateFetcher = makeFetcher { _ in ["198.18.0.6", "192.168.1.20"] }
        XCTAssertFalse(fakeIPAndPrivateFetcher.isSafePublicURL("https://mixed.example/secret"))

        let fakeIPAndPublicFetcher = makeFetcher { _ in ["198.18.0.6", "93.184.216.34"] }
        XCTAssertTrue(fakeIPAndPublicFetcher.isSafePublicURL("https://mixed.example/article"))
    }

    func testRedirectHookRejectsPrivatelyResolvedTarget() {
        let fetcher = makeFetcher { host in
            host == "private.example" ? ["192.168.1.20"] : ["93.184.216.34"]
        }

        XCTAssertFalse(fetcher.isSafeRedirectURL("http://private.example/secret"))
        XCTAssertTrue(fetcher.isSafeRedirectURL("https://public.example/article"))

        let fakeIPFetcher = makeFetcher { _ in ["198.18.0.6"] }
        XCTAssertTrue(fakeIPFetcher.isSafeRedirectURL("https://public.example/article"))
        XCTAssertFalse(fakeIPFetcher.isSafeRedirectURL("https://198.18.0.6/secret"))
    }

    func testHTMLLimitCancelsTransferBeforeAllChunksArrive() async {
        let stopped = expectation(description: "oversized transfer cancelled")
        let totalChunks = 12
        LinkEnrichmentURLProtocolStub.state.configure(
            .oversized(totalChunks: totalChunks, chunkSize: 64 * 1_024),
            stopped: stopped
        )
        let fetcher = makeFetcher { _ in ["93.184.216.34"] }

        let entries = await fetcher.enrich(urls: ["https://public.example/oversized"])
        await fulfillment(of: [stopped], timeout: 2)

        XCTAssertTrue(entries.isEmpty)
        XCTAssertLessThan(LinkEnrichmentURLProtocolStub.state.chunksSent, totalChunks)
    }

    func testCancelledQueuedContentDoesNotStartNetworkOrFreezeEmptyPayload() async {
        let firstRequestStarted = expectation(description: "first request started")
        LinkEnrichmentURLProtocolStub.state.configure(.neverCompletes, started: firstRequestStarted)
        let fetcher = makeFetcher { _ in ["93.184.216.34"] }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-enrichment-cancel-tests-\(UUID().uuidString)")
        let store = LinkEnrichmentStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workPool = AsyncPermitPool(limit: 1, maxPending: 1)
        let coordinator = LinkEnrichmentCoordinator(
            store: store,
            fetcher: fetcher,
            workPool: workPool
        )
        let firstMarkdown = "# News\n\n- [One](https://public.example/one?utm_source=chatgpt.com)"
        let secondMarkdown = "# News\n\n- [Two](https://public.example/two?utm_source=chatgpt.com)"

        let first = Task { await coordinator.ensureEnrichment(markdown: firstMarkdown) }
        await fulfillment(of: [firstRequestStarted], timeout: 2)
        let second = Task { await coordinator.ensureEnrichment(markdown: secondMarkdown) }
        while await workPool.queuedWaiterCount() == 0 {
            await Task.yield()
        }
        second.cancel()
        await second.value

        XCTAssertEqual(LinkEnrichmentURLProtocolStub.state.requestedHosts, ["public.example"])
        XCTAssertNil(store.payload(forContentKey: LinkEnrichmentContentKey.make(for: secondMarkdown)))

        first.cancel()
        await first.value
        XCTAssertNil(store.payload(forContentKey: LinkEnrichmentContentKey.make(for: firstMarkdown)))
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

    private func makeFetcher(
        resolver: @escaping LinkEnrichmentFetcher.HostResolver
    ) -> LinkEnrichmentFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LinkEnrichmentURLProtocolStub.self]
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return LinkEnrichmentFetcher(configuration: configuration, hostResolver: resolver)
    }
}

private final class LinkEnrichmentURLProtocolStub: URLProtocol, @unchecked Sendable {
    enum Behavior {
        case oversized(totalChunks: Int, chunkSize: Int)
        case neverCompletes
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var behavior: Behavior = .neverCompletes
        private var hosts: [String] = []
        private var sentChunks = 0
        private var stoppedExpectation: XCTestExpectation?
        private var startedExpectation: XCTestExpectation?

        var requestedHosts: [String] {
            lock.withLock { hosts }
        }

        var chunksSent: Int {
            lock.withLock { sentChunks }
        }

        func configure(
            _ behavior: Behavior,
            stopped: XCTestExpectation? = nil,
            started: XCTestExpectation? = nil
        ) {
            lock.withLock {
                self.behavior = behavior
                hosts = []
                sentChunks = 0
                stoppedExpectation = stopped
                startedExpectation = started
            }
        }

        func begin(request: URLRequest) -> Behavior {
            let started = lock.withLock {
                if let host = request.url?.host { hosts.append(host) }
                let expectation = startedExpectation
                startedExpectation = nil
                return expectation
            }
            started?.fulfill()
            return lock.withLock { behavior }
        }

        func recordChunk() {
            lock.withLock { sentChunks += 1 }
        }

        func recordStop() {
            let stopped = lock.withLock {
                let expectation = stoppedExpectation
                stoppedExpectation = nil
                return expectation
            }
            stopped?.fulfill()
        }
    }

    static let state = State()

    private let stopLock = NSLock()
    private var isStopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        switch Self.state.begin(request: request) {
        case .oversized(let totalChunks, let chunkSize):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/html"]
                  )
            else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            sendChunk(index: 0, totalChunks: totalChunks, chunkSize: chunkSize)
        case .neverCompletes:
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/html"]
                  )
            else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
    }

    override func stopLoading() {
        let shouldRecord = stopLock.withLock {
            guard !isStopped else { return false }
            isStopped = true
            return true
        }
        if shouldRecord { Self.state.recordStop() }
    }

    private func sendChunk(index: Int, totalChunks: Int, chunkSize: Int) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in
            guard let self, !self.stopLock.withLock({ self.isStopped }) else { return }
            guard index < totalChunks else {
                self.client?.urlProtocolDidFinishLoading(self)
                return
            }
            var chunk = Data(repeating: 0x78, count: chunkSize)
            if index == 0 {
                chunk.replaceSubrange(0..<24, with: Data("<title>Oversized</title>".utf8))
            }
            Self.state.recordChunk()
            self.client?.urlProtocol(self, didLoad: chunk)
            self.sendChunk(index: index + 1, totalChunks: totalChunks, chunkSize: chunkSize)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
