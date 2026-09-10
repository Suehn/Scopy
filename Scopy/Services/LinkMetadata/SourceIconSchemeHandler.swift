import Foundation
import WebKit

/// An image-only native resource adapter. It cannot proxy an arbitrary URL or page path.
/// Both WebViews register this same handler and use the same cache and terminal fallback.
@MainActor
public final class SourceIconSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "scopy-source-icon"
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let load: @Sendable (URL) async -> Data?

    public override init() {
        self.load = { origin in
            let settings = await SettingsStore.shared.load()
            let environment = ProcessInfo.processInfo.environment
            let testing = ProcessInfo.processInfo.arguments.contains("--uitesting")
                || NSClassFromString("XCTestCase") != nil
            let allowNetwork = settings.siteIconsEnabled
                && (!testing || environment["SCOPY_SITE_ICONS_NETWORK"] == "1")
            return await SourceIconService.shared.icon(origin: origin, allowNetwork: allowNetwork)
        }
        super.init()
    }

    init(load: @escaping @Sendable (URL) async -> Data?) {
        self.load = load
        super.init()
    }

    public static func install(in configuration: WKWebViewConfiguration) {
        configuration.setURLSchemeHandler(SourceIconSchemeHandler(), forURLScheme: scheme)
    }

    static func origin(for url: URL) -> URL? {
        guard url.scheme == scheme, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.port == nil,
              let host = url.host, !host.isEmpty,
              ["/https", "/http"].contains(url.path),
              host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }),
              let origin = URL(string: "\(url.path.dropFirst())://\(host)/") else { return nil }
        return origin
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard tasks.count < 256, let url = urlSchemeTask.request.url, let origin = Self.origin(for: url) else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL)); return
        }
        let loader = load
        tasks[id] = Task { [weak self] in
            let data = await loader(origin)
            guard !Task.isCancelled, let self, self.tasks.removeValue(forKey: id) != nil else { return }
            if let data {
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } else {
                urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
            }
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    deinit { for task in tasks.values { task.cancel() } }
}
