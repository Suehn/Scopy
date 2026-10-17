import Foundation
import XCTest
@testable import ScopyKit

final class SourceIconTests: XCTestCase {
    private static let png = try! Data(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ScopyUITests/Fixtures/Assets/chatgpt-rich/favicon-hsbc-hk-32.png"))

    func testDiscoveryHandlesAttributeOrderRelativeURLsAndRelTokens() {
        let html = """
        <link href='/vector.svg' rel=icon>
        <link sizes='32x32' href='../logo.png?a=1&amp;b=2' rel='alternate ICON'>
        <link href="//cdn.example/apple.png" rel="apple-touch-icon">
        <link rel=stylesheet href=/no.css>
        """
        XCTAssertEqual(LinkEnrichmentFetcher.faviconCandidates(in: html, base: URL(string: "https://site.example/base/")!), [
            "https://site.example/logo.png?a=1&b=2", "https://cdn.example/apple.png", "https://site.example/vector.svg"
        ])
    }

    @MainActor
    func testNativeResourceOnlyAcceptsOriginAndDefaultWebPorts() {
        XCTAssertEqual(SourceIconSchemeHandler.origin(for: URL(string: "scopy-source-icon://example.com/https")!), URL(string: "https://example.com/"))
        for value in ["scopy-source-icon://example.com/https?secret=x", "scopy-source-icon://user@example.com/https",
                      "scopy-source-icon://example.com:9000/https", "scopy-source-icon://example.com/https/path",
                      "https://example.com/https", "scopy-source-icon://example.com/file"] {
            XCTAssertNil(SourceIconSchemeHandler.origin(for: URL(string: value)!), value)
        }
    }

    func testFaviconDiscoveryWorksWithoutPageTitleAndUsesBoundedRasterFallback() async {
        IconURLProtocol.state.reset(png: Self.png)
        let png = await fetcher().fetchFavicon(origin: URL(string: "https://site.example/")!)
        XCTAssertNotNil(png)
        XCTAssertLessThan(png?.count ?? Int.max, 32768)
        XCTAssertTrue(IconURLProtocol.state.paths.contains("/brand.png"))
        XCTAssertFalse(IconURLProtocol.state.paths.contains(where: { $0.contains("private") }))
    }

    func testOriginCacheCoalescesRequestsPersistsAndServesOffline() async throws {
        IconURLProtocol.state.reset(png: Self.png)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = SourceIconService(directory: directory, fetcher: fetcher())
        let origin = URL(string: "https://site.example/")!
        async let a = service.icon(origin: origin, allowNetwork: true)
        async let b = service.icon(origin: origin, allowNetwork: true)
        let (one, two) = await (a, b)
        XCTAssertNotNil(one)
        XCTAssertEqual(one, two)
        XCTAssertEqual(IconURLProtocol.state.paths.filter { $0 == "/" }.count, 1)
        let count = IconURLProtocol.state.paths.count
        let freshService = SourceIconService(directory: directory, fetcher: fetcher())
        let offline = await freshService.icon(origin: origin, allowNetwork: false)
        XCTAssertEqual(offline, one)
        XCTAssertEqual(IconURLProtocol.state.paths.count, count)
    }

    func testFailedOriginIsNegativeCachedAndPrivateDNSNeverRequested() async {
        IconURLProtocol.state.reset(png: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = SourceIconService(directory: directory, fetcher: fetcher())
        let origin = URL(string: "https://site.example/")!
        let first = await service.icon(origin: origin, allowNetwork: true)
        let count = IconURLProtocol.state.paths.count
        let second = await service.icon(origin: origin, allowNetwork: true)
        XCTAssertNil(first); XCTAssertNil(second)
        XCTAssertEqual(IconURLProtocol.state.paths.count, count)
        let blocked = await fetcher(address: "127.0.0.1").fetchFavicon(origin: origin)
        XCTAssertNil(blocked)
        XCTAssertEqual(IconURLProtocol.state.paths.count, count)
    }

    func testSiteIconSettingPreservesSaveCancelTransactionsAndPersistence() async throws {
        let baseline = SettingsDTO.default
        XCTAssertTrue(baseline.siteIconsEnabled)
        var draft = baseline
        draft.siteIconsEnabled = false
        let patch = SettingsPatch.from(baseline: baseline, draft: draft)
        XCTAssertFalse(patch.isEmpty)
        XCTAssertTrue(baseline.siteIconsEnabled)
        XCTAssertFalse(baseline.applying(patch).siteIconsEnabled)
        let settingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-source-icon-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: settingsDirectory) }
        let suite = settingsDirectory.appendingPathComponent("settings").path
        let store = SettingsStore(suiteName: suite)
        await store.save(draft)
        let saved = await SettingsStore(suiteName: suite).load()
        XCTAssertFalse(saved.siteIconsEnabled)
    }

    private func fetcher(address: String = "93.184.216.34") -> LinkEnrichmentFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IconURLProtocol.self]
        return LinkEnrichmentFetcher(configuration: configuration, hostResolver: { _ in [address] })
    }
}

private final class IconURLProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        private var image: Data?
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
        func reset(png: Data?) { lock.lock(); defer { lock.unlock() }; recorded = []; image = png }
        func response(path: String) -> (Int, Data, String) {
            lock.lock(); defer { lock.unlock() }
            recorded.append(path)
            if path == "/" {
                return (200, Data("<link href='/brand.png' rel='shortcut icon'>".utf8), "text/html")
            }
            if path == "/brand.png", let image { return (200, image, "image/png") }
            return (404, Data(), "text/plain")
        }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let (status, data, mime) = Self.state.response(path: url.path)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
