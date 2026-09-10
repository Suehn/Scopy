import Foundation
import WebKit
import XCTest
@testable import ScopyKit
@testable import Scopy

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

    func testSiteIconSettingPreservesSaveCancelTransactionsAndPersistence() async {
        let baseline = SettingsDTO.default
        XCTAssertTrue(baseline.siteIconsEnabled)
        var draft = baseline
        draft.siteIconsEnabled = false
        let patch = SettingsPatch.from(baseline: baseline, draft: draft)
        XCTAssertFalse(patch.isEmpty)
        XCTAssertTrue(baseline.siteIconsEnabled)
        XCTAssertFalse(baseline.applying(patch).siteIconsEnabled)
        let suite = "Scopy.SourceIconTests." + UUID().uuidString
        let store = SettingsStore(suiteName: suite)
        await store.save(draft)
        let saved = await SettingsStore(suiteName: suite).load()
        XCTAssertFalse(saved.siteIconsEnabled)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @MainActor
    func testSlowNativeIconSettlesBeforeFontReadinessAndKeepsInlineGeometry() async throws {
        let png = Self.png
        let handler = SourceIconSchemeHandler(load: { _ in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            return png
        })
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: SourceIconSchemeHandler.scheme)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 816, height: 500), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFront(nil)
        defer { window.close() }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scopy/Resources/MarkdownPreview")
        let assets = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: root, to: assets)
        defer { try? FileManager.default.removeItem(at: assets) }
        let document = assets.appendingPathComponent("test.html")
        try MarkdownHTMLRenderer.render(markdown: "正文 [站点标题](https://new-site.example/private?token=secret) 与后续文字。")
            .write(to: document, atomically: true, encoding: .utf8)
        webView.loadFileURL(document, allowingReadAccessTo: assets)
        let deadline = Date().addingTimeInterval(12)
        var ready = false
        while !ready && Date() < deadline {
            ready = (try? await webView.evaluateJavaScript("Boolean(window.__scopyIsRenderReady && window.__scopyIsRenderReady())")) as? Bool == true
            if !ready { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        XCTAssertTrue(ready, "a slow native icon must not become a font timeout")
        let checks = try await webView.evaluateJavaScript("""
        (() => {
          const image = document.querySelector('img[data-scopy-native-source-icon]');
          const label = document.querySelector('.scopy-link__label');
          return !!image && image.naturalWidth > 0 && image.dataset.scopyImageState === 'ready'
            && image.getBoundingClientRect().width <= 20 && label.textContent === '站点标题';
        })()
        """)
        XCTAssertEqual(checks as? Bool, true)
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
