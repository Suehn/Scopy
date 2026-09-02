import Foundation
import SwiftUI
import AppKit
import WebKit
import ScopyUISupport

enum MarkdownPreviewRenderIdentity {
    static let placeholder = "__SCOPY_RENDER_ID__"

    static func injecting(_ renderID: String, into html: String) -> String {
        guard let markerRange = html.range(of: placeholder) else { return html }
        var document = html
        document.replaceSubrange(markerRange, with: renderID)
        return document
    }
}

@MainActor
private enum MarkdownPreviewScrollViewResolver {
    private final class WeakScrollViewBox {
        weak var value: NSScrollView?
        init(_ value: NSScrollView?) {
            self.value = value
        }
    }

    private static var cache: [ObjectIdentifier: WeakScrollViewBox] = [:]

    static func resolve(for view: NSView) -> NSScrollView? {
        if PerfFeatureFlags.markdownResolverCacheEnabled {
            let key = ObjectIdentifier(view)
            if let cached = cache[key]?.value {
                return cached
            }
            // Opportunistic pruning for deallocated views.
            if cache.count > 256 {
                cache = cache.filter { $0.value.value != nil }
            }
        }

        let resolved: NSScrollView?
        if let sv = view as? NSScrollView {
            resolved = sv
        } else if let sv = view.enclosingScrollView {
            resolved = sv
        } else {
            resolved = findFirstScrollView(in: view)
        }

        if PerfFeatureFlags.markdownResolverCacheEnabled {
            cache[ObjectIdentifier(view)] = WeakScrollViewBox(resolved)
        }
        return resolved
    }

    private static func findFirstScrollView(in view: NSView) -> NSScrollView? {
        for subview in view.subviews {
            if let sv = subview as? NSScrollView { return sv }
            if let found = findFirstScrollView(in: subview) { return found }
        }
        return nil
    }
}

@MainActor
private enum MarkdownPreviewMessageParser {
    static func metrics(from message: WKScriptMessage) -> MarkdownContentMetrics? {
        guard message.name == MarkdownPreviewWebView.sizeMessageHandlerName else { return nil }

        var size: CGSize?
        var overflowX: Bool = false
        var renderSucceeded: Bool = true
        var renderErrorReason: String?
        var renderID: String?
        if let dict = message.body as? [String: Any] {
            size = parseSize(from: dict)
            overflowX = parseOverflow(from: dict["overflowX"])
            renderSucceeded = parseRenderSucceeded(from: dict["renderSucceeded"])
            renderErrorReason = parseString(from: dict["renderErrorReason"])
            renderID = parseString(from: dict["renderID"])
        } else if let dict = message.body as? NSDictionary {
            size = CGSize(width: cgFloat(from: dict["width"]), height: cgFloat(from: dict["height"]))
            overflowX = parseOverflow(from: dict["overflowX"])
            renderSucceeded = parseRenderSucceeded(from: dict["renderSucceeded"])
            renderErrorReason = parseString(from: dict["renderErrorReason"])
            renderID = parseString(from: dict["renderID"])
        }

        guard let size, let renderID else { return nil }
        guard size.width.isFinite, size.height.isFinite else { return nil }
        guard size.height > 0 else { return nil }
        return MarkdownContentMetrics(
            size: size,
            hasHorizontalOverflow: overflowX,
            renderSucceeded: renderSucceeded,
            renderErrorReason: renderErrorReason,
            renderID: renderID
        )
    }

    private static func parseSize(from dict: [String: Any]) -> CGSize {
        let w = dict["width"]
        let h = dict["height"]
        return CGSize(width: cgFloat(from: w), height: cgFloat(from: h))
    }

    private static func parseOverflow(from value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String { return s == "true" || s == "1" }
        return false
    }

    private static func parseRenderSucceeded(from value: Any?) -> Bool {
        guard let value else { return true }
        return parseOverflow(from: value)
    }

    private static func parseString(from value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        return s.isEmpty ? nil : s
    }

    private static func cgFloat(from any: Any?) -> CGFloat {
        if let n = any as? NSNumber {
            return CGFloat(truncating: n)
        }
        if let d = any as? Double {
            return CGFloat(d)
        }
        if let i = any as? Int {
            return CGFloat(i)
        }
        if let s = any as? String, let d = Double(s) {
            return CGFloat(d)
        }
        return 0
    }
}

enum MarkdownPreviewNavigationPolicy {
    enum Decision: Equatable {
        case allowInWebView
        case openExternally(URL)
        case cancel
    }

    static func decision(
        navigationType: WKNavigationType,
        targetFrameIsNil: Bool,
        url: URL?,
        currentURL: URL? = nil
    ) -> Decision {
        if navigationType == .linkActivated {
            if isSameDocumentFragmentNavigation(url: url, currentURL: currentURL) {
                return .allowInWebView
            }
            if let url, let fileURL = validatedLocalFileURL(from: url) {
                return .openExternally(fileURL)
            }
            if let url, isValidExternalURL(url) {
                return .openExternally(url)
            }
            return .cancel
        }

        if targetFrameIsNil { return .cancel }
        guard let url else { return .cancel }
        if url.isFileURL { return .allowInWebView }
        if url.scheme?.lowercased() == "about", url.absoluteString == "about:blank" {
            return .allowInWebView
        }
        return .cancel
    }

    @MainActor
    static func handle(
        _ navigationAction: WKNavigationAction,
        in webView: WKWebView,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let targetFrameIsNil = navigationAction.targetFrame == nil
        let policyDecision = decision(
            navigationType: navigationAction.navigationType,
            targetFrameIsNil: targetFrameIsNil,
            url: navigationAction.request.url,
            currentURL: webView.url
        )

        switch policyDecision {
        case .allowInWebView:
            if targetFrameIsNil {
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        case .openExternally(let url):
            _ = NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        case .cancel:
            decisionHandler(.cancel)
        }
    }

    private static func isSameDocumentFragmentNavigation(url: URL?, currentURL: URL?) -> Bool {
        guard let target = url,
              let fragment = target.fragment,
              !fragment.isEmpty
        else {
            return false
        }

        if target.scheme == nil, target.host == nil, target.path.isEmpty {
            return true
        }

        guard let current = currentURL,
              let targetWithoutFragment = removingFragment(from: target),
              let currentWithoutFragment = removingFragment(from: current)
        else {
            return false
        }
        return targetWithoutFragment == currentWithoutFragment
    }

    private static func removingFragment(from url: URL) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url
    }

    private static func isValidExternalURL(_ url: URL) -> Bool {
        let absoluteString = url.absoluteString
        guard absoluteString.utf8.count <= 8_192,
              !containsControlCharacters(absoluteString),
              let decodedAbsoluteString = absoluteString.removingPercentEncoding,
              !containsControlCharacters(decodedAbsoluteString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              host.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (
                      CharacterSet.alphanumerics.contains(scalar) ||
                          scalar == "." || scalar == "-" || scalar == ":"
                  )
              }),
              host.unicodeScalars.contains(where: { $0.isASCII && CharacterSet.alphanumerics.contains($0) }),
              components.user == nil,
              components.password == nil
        else {
            return false
        }
        return true
    }

    private static func validatedLocalFileURL(from url: URL) -> URL? {
        let absoluteString = url.absoluteString
        guard absoluteString.utf8.count <= 8_192,
              !containsControlCharacters(absoluteString),
              let decodedAbsoluteString = absoluteString.removingPercentEncoding,
              !containsControlCharacters(decodedAbsoluteString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "scopy-file",
              components.host == nil,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil
        else {
            return nil
        }

        var path = strippingTextPosition(from: components.path)
        guard path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }

        if path == "/~" {
            path = FileManager.default.homeDirectoryForCurrentUser.path
        } else if path.hasPrefix("/~/") {
            path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(3)))
                .path
        }

        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func strippingTextPosition(from path: String) -> String {
        guard let positionRange = path.range(
            of: #":[1-9][0-9]*(?::[1-9][0-9]*)?$"#,
            options: .regularExpression
        ) else {
            return path
        }
        return String(path[..<positionRange.lowerBound])
    }

    private static func containsControlCharacters(_ string: String) -> Bool {
        string.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

struct MarkdownContentMetrics: Equatable {
    let size: CGSize
    let hasHorizontalOverflow: Bool
    let renderSucceeded: Bool
    let renderErrorReason: String?
    let renderID: String

    init(
        size: CGSize,
        hasHorizontalOverflow: Bool,
        renderSucceeded: Bool = true,
        renderErrorReason: String? = nil,
        renderID: String = ""
    ) {
        self.size = size
        self.hasHorizontalOverflow = hasHorizontalOverflow
        self.renderSucceeded = renderSucceeded
        self.renderErrorReason = renderErrorReason
        self.renderID = renderID
    }

    func isEquivalent(to other: MarkdownContentMetrics) -> Bool {
        abs(size.width - other.size.width) < 1 &&
            abs(size.height - other.size.height) < 1 &&
            hasHorizontalOverflow == other.hasHorizontalOverflow &&
            renderSucceeded == other.renderSucceeded &&
            renderErrorReason == other.renderErrorReason &&
            renderID == other.renderID
    }
}

struct MarkdownPreviewMetricDeliveryIdentity: Equatable {
    let ownerID: UUID?
    let renderID: String
    let renderKey: String
}

struct MarkdownPreviewOneShotMetricDeliveryIdentity: Equatable {
    let renderID: String
    let callbackID: UUID
}

struct MarkdownPreviewWebView: NSViewRepresentable {
    let html: String
    let shouldScroll: Bool
    let onContentSizeChange: @MainActor (MarkdownContentMetrics) -> Void

    private static let blockNetworkRuleListIdentifier = "ScopyMarkdownPreviewBlockNetwork"
    fileprivate static let sizeMessageHandlerName = "scopySize"
    private static let blockNetworkRulesJSON = """
    [
      {
        "trigger": { "url-filter": "https?://.*" },
        "action": { "type": "block" }
      }
    ]
    """
    private static var cachedBlockNetworkRuleList: WKContentRuleList?
    private static var isCompilingRuleList: Bool = false
    private static let ruleListLock = NSLock()
    private static let pendingControllers = NSHashTable<WKUserContentController>.weakObjects()

    @MainActor
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController = WKUserContentController()

        Self.installNetworkBlocker(into: config.userContentController)
        config.userContentController.add(context.coordinator.sizeMessageHandlerProxy, name: Self.sizeMessageHandlerName)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        configureScrollers(for: webView, shouldScroll: shouldScroll)
        context.coordinator.attachScrollbarAutoHiderIfPossible(for: webView)
        return webView
    }

    @MainActor
    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onContentSizeChange = onContentSizeChange
        configureScrollers(for: webView, shouldScroll: shouldScroll)
        context.coordinator.attachScrollbarAutoHiderIfPossible(for: webView)

        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            let baseURL = Bundle.main.resourceURL?.appendingPathComponent("MarkdownPreview", isDirectory: true)
            context.coordinator.load(html: html, in: webView, baseURL: baseURL)
        }
    }

    @MainActor
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: Self.sizeMessageHandlerName)
        coordinator.scrollbarAutoHider.detach()
    }

    @MainActor
    private func configureScrollers(for webView: WKWebView, shouldScroll: Bool) {
        guard let scrollView = MarkdownPreviewScrollViewResolver.resolve(for: webView) else { return }
        scrollView.hasVerticalScroller = shouldScroll
        // Keep the outer horizontal scroller disabled. Horizontal overflow is handled inside HTML (e.g. KaTeX/code)
        // so we don't show a persistent bottom bar under the system "always show scroll bars" setting.
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
    }

    fileprivate static func installNetworkBlocker(into controller: WKUserContentController) {
        ruleListLock.lock()
        if let cached = cachedBlockNetworkRuleList {
            ruleListLock.unlock()
            controller.add(cached)
            return
        }
        pendingControllers.add(controller)
        if isCompilingRuleList {
            ruleListLock.unlock()
            return
        }
        isCompilingRuleList = true
        ruleListLock.unlock()

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: blockNetworkRuleListIdentifier,
            encodedContentRuleList: blockNetworkRulesJSON
        ) { ruleList, _ in
            ruleListLock.lock()
            isCompilingRuleList = false
            if let ruleList {
                cachedBlockNetworkRuleList = ruleList
            }
            ruleListLock.unlock()

            guard let ruleList else { return }
            DispatchQueue.main.async {
                for pending in pendingControllers.allObjects {
                    pending.add(ruleList)
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var lastHTML: String = ""
        var onContentSizeChange: (@MainActor (MarkdownContentMetrics) -> Void)?
        private var lastReportedMetrics: MarkdownContentMetrics = MarkdownContentMetrics(size: .zero, hasHorizontalOverflow: false)
        private var currentRenderID: String = ""
        private var currentCallbackID = UUID()
        private var currentNavigation: WKNavigation?
        let scrollbarAutoHider = ScrollbarAutoHider()
        let sizeMessageHandlerProxy = WeakScriptMessageHandler()

        override init() {
            super.init()
            sizeMessageHandlerProxy.delegate = self
        }

        func load(html: String, in webView: WKWebView, baseURL: URL?) {
            currentRenderID = UUID().uuidString
            currentCallbackID = UUID()
            lastReportedMetrics = MarkdownContentMetrics(size: .zero, hasHorizontalOverflow: false)
            webView.alphaValue = 0
            let document = MarkdownPreviewRenderIdentity.injecting(currentRenderID, into: html)
            currentNavigation = webView.loadHTMLString(document, baseURL: baseURL)
        }

        func attachScrollbarAutoHiderIfPossible(for webView: WKWebView) {
            if let scrollView = MarkdownPreviewScrollViewResolver.resolve(for: webView) {
                scrollbarAutoHider.attach(to: scrollView)
            } else {
                Task { @MainActor [weak self, weak webView] in
                    await Task.yield()
                    guard let self, let webView else { return }
                    if let scrollView = MarkdownPreviewScrollViewResolver.resolve(for: webView) {
                        self.scrollbarAutoHider.attach(to: scrollView)
                    }
                }
            }
        }

        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            MarkdownPreviewNavigationPolicy.handle(
                navigationAction,
                in: webView,
                decisionHandler: decisionHandler
            )
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === currentNavigation else { return }
            currentNavigation = nil
            // Best-effort: ensure math render runs even if DOMContentLoaded timing varies.
            attachScrollbarAutoHiderIfPossible(for: webView)
            webView.evaluateJavaScript("typeof window.__scopyRenderMath === 'function'") { result, _ in
                guard let ok = result as? Bool, ok else { return }
                webView.evaluateJavaScript("window.__scopyRenderMath()") { _, _ in }
            }
            webView.evaluateJavaScript("typeof window.__scopyReportHeight === 'function'") { result, _ in
                guard let ok = result as? Bool, ok else { return }
                webView.evaluateJavaScript("window.__scopyReportHeight()") { _, _ in }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleNavigationFailure(navigation, in: webView, reason: error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleNavigationFailure(navigation, in: webView, reason: error.localizedDescription)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            handleNavigationFailure(nil, in: webView, reason: "Web content process terminated")
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let metrics = MarkdownPreviewMessageParser.metrics(from: message) else { return }
            guard message.frameInfo.isMainFrame, metrics.renderID == currentRenderID else { return }
            if metrics.isEquivalent(to: lastReportedMetrics) { return }
            lastReportedMetrics = metrics
            if let wk = message.webView {
                wk.alphaValue = metrics.renderSucceeded ? 1 : 0
                attachScrollbarAutoHiderIfPossible(for: wk)
            }
            scheduleMetricsDelivery(metrics, capturedIdentity: metricDeliveryIdentity)
        }

        private func handleNavigationFailure(_ navigation: WKNavigation?, in webView: WKWebView, reason: String) {
            if let navigation {
                guard navigation === currentNavigation else { return }
            }
            currentNavigation = nil
            webView.alphaValue = 0
            let metrics = MarkdownContentMetrics(
                size: CGSize(width: max(1, webView.bounds.width), height: max(1, webView.bounds.height)),
                hasHorizontalOverflow: false,
                renderSucceeded: false,
                renderErrorReason: reason,
                renderID: currentRenderID
            )
            guard !metrics.isEquivalent(to: lastReportedMetrics) else { return }
            lastReportedMetrics = metrics
            scheduleMetricsDelivery(metrics, capturedIdentity: metricDeliveryIdentity)
        }

        var metricDeliveryIdentity: MarkdownPreviewOneShotMetricDeliveryIdentity {
            MarkdownPreviewOneShotMetricDeliveryIdentity(
                renderID: currentRenderID,
                callbackID: currentCallbackID
            )
        }

        func scheduleMetricsDelivery(
            _ metrics: MarkdownContentMetrics,
            capturedIdentity: MarkdownPreviewOneShotMetricDeliveryIdentity
        ) {
            guard metrics.renderID == capturedIdentity.renderID,
                  let callback = onContentSizeChange
            else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self, self.metricDeliveryIdentity == capturedIdentity else { return }
                callback(metrics)
            }
        }
    }
}

@MainActor
final class MarkdownPreviewWebViewController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let webView: WKWebView

    var onContentSizeChange: (@MainActor (MarkdownContentMetrics) -> Void)?
    private var lastHTML: String = ""
    private var lastKnownMetrics: MarkdownContentMetrics?
    private var lastDeliveredMetrics: MarkdownContentMetrics = MarkdownContentMetrics(size: .zero, hasHorizontalOverflow: false)
    private var lastLoadFinished: Bool = false
    private var currentRenderID: String = ""
    private var currentRenderKey: String = ""
    private var currentNavigation: WKNavigation?
    private var failedOwnerID: UUID?
    private var pendingContentRefreshTask: Task<Void, Never>?
    private var pendingScrollConfigurationTask: Task<Void, Never>?
    private var bridgeIsAttached = false
    private var currentOwnerID: UUID?
    private var desiredShouldScroll: Bool?
    private var lastShouldScroll: Bool?
    private(set) var bridgeAttachmentCount = 0
    private(set) var scrollConfigurationCount = 0
    private(set) var navigationStartCount = 0
    private let scrollViewResolver: @MainActor (NSView) -> NSScrollView?
    private let scrollbarAutoHider = ScrollbarAutoHider()
    private let sizeMessageHandlerProxy = WeakScriptMessageHandler()

    init(
        scrollViewResolver: @escaping @MainActor (NSView) -> NSScrollView? = {
            MarkdownPreviewScrollViewResolver.resolve(for: $0)
        }
    ) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController = WKUserContentController()

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsMagnification = false
        wv.setValue(false, forKey: "drawsBackground")
        self.webView = wv
        self.scrollViewResolver = scrollViewResolver
        super.init()

        // Reuse the same network blocker & message handler semantics as the one-shot web view.
        MarkdownPreviewWebView.installNetworkBlocker(into: config.userContentController)
        sizeMessageHandlerProxy.delegate = self
        config.userContentController.add(sizeMessageHandlerProxy, name: MarkdownPreviewWebView.sizeMessageHandlerName)

        attachWebViewIfNeeded()
    }

    func beginOwnership(_ ownerID: UUID) {
        if currentOwnerID != ownerID {
            // A callback is part of the ownership lease. Leave an ownership-transfer gap silent until the new
            // representable installs its callback in updateNSView.
            onContentSizeChange = nil
            lastDeliveredMetrics = MarkdownContentMetrics(size: .zero, hasHorizontalOverflow: false)
        }
        currentOwnerID = ownerID
        attachWebViewIfNeeded()
    }

    func owns(_ ownerID: UUID) -> Bool {
        currentOwnerID == ownerID
    }

    func endOwnership(_ ownerID: UUID) {
        guard currentOwnerID == ownerID else { return }
        detachWebView()
    }

    private func attachWebViewIfNeeded() {
        guard !bridgeIsAttached else { return }
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: MarkdownPreviewWebView.sizeMessageHandlerName)
        controller.add(sizeMessageHandlerProxy, name: MarkdownPreviewWebView.sizeMessageHandlerName)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        bridgeIsAttached = true
        bridgeAttachmentCount += 1
    }

    func detachWebView() {
        pendingContentRefreshTask?.cancel()
        pendingContentRefreshTask = nil
        pendingScrollConfigurationTask?.cancel()
        pendingScrollConfigurationTask = nil
        if currentNavigation != nil { lastLoadFinished = false }
        currentNavigation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: MarkdownPreviewWebView.sizeMessageHandlerName)
        scrollbarAutoHider.detach()
        onContentSizeChange = nil
        bridgeIsAttached = false
        currentOwnerID = nil
        desiredShouldScroll = nil
        lastShouldScroll = nil
        // Allow the next consumer (popover / measurer) to receive a fresh metrics callback even if the size is unchanged.
        lastDeliveredMetrics = MarkdownContentMetrics(size: .zero, hasHorizontalOverflow: false)
    }

    func setShouldScroll(_ shouldScroll: Bool) {
        attachWebViewIfNeeded()
        desiredShouldScroll = shouldScroll
        guard lastShouldScroll != shouldScroll else { return }
        if applyScrollConfigurationIfPossible(shouldScroll) { return }

        pendingScrollConfigurationTask?.cancel()
        pendingScrollConfigurationTask = Task { @MainActor [weak self] in
            for _ in 0..<60 {
                guard let self,
                      !Task.isCancelled,
                      self.desiredShouldScroll == shouldScroll
                else {
                    return
                }
                if self.applyScrollConfigurationIfPossible(shouldScroll) {
                    self.pendingScrollConfigurationTask = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            self?.pendingScrollConfigurationTask = nil
        }
    }

    private func applyScrollConfigurationIfPossible(_ shouldScroll: Bool) -> Bool {
        guard lastShouldScroll != shouldScroll,
              let scrollView = scrollViewResolver(webView)
        else {
            return lastShouldScroll == shouldScroll
        }
        lastShouldScroll = shouldScroll
        scrollConfigurationCount += 1
        scrollView.hasVerticalScroller = shouldScroll
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollbarAutoHider.attach(to: scrollView)
        return true
    }

    private var prewarmRenderCacheKey: String?

    /// Loads a document into the shared WebView before any popover owns it, at the width the
    /// popover will use, so the first presentation replays finished metrics instead of navigating.
    func prewarm(html: String, renderCacheKey: String, width: CGFloat) {
        guard currentOwnerID == nil else { return }
        if webView.window == nil, webView.bounds.width != width {
            webView.frame = NSRect(x: 0, y: 0, width: width, height: max(webView.bounds.height, 600))
        }
        prewarmRenderCacheKey = renderCacheKey
        HistoryHoverPreviewPipeline.logHoverStage("webview prewarm")
        loadHTMLIfNeeded(html)
    }

    func loadHTMLIfNeeded(_ html: String) {
        attachWebViewIfNeeded()
        // SwiftUI's popover measurement pass hands the view over at zero size; a navigation laid
        // out at width 0 reports nothing usable and is redone once the popover is on screen.
        if webView.window == nil, webView.bounds.width < 1 {
            webView.frame = NSRect(
                x: 0, y: 0,
                width: HoverPreviewScreenMetrics.maxMarkdownPopoverWidthPoints(),
                height: max(webView.bounds.height, 600)
            )
        }

        if lastHTML == html {
            if !lastLoadFinished {
                // A terminal failure remains visible for the current owner. A new owner may retry the same document.
                guard failedOwnerID != currentOwnerID else { return }
                // Repeated SwiftUI updates while the same navigation is in flight must not restart it.
                // A restart is only needed after an owner detached and stopped that navigation.
                if currentNavigation != nil { return }
                pendingContentRefreshTask?.cancel()
                pendingContentRefreshTask = nil
                lastKnownMetrics = nil
                lastDeliveredMetrics = MarkdownContentMetrics(size: .zero, hasHorizontalOverflow: false)
                // A detached consumer may have stopped the prior navigation after an early metrics message.
                // Restart before considering any cached metrics from that incomplete document.
                let baseURL = Bundle.main.resourceURL?.appendingPathComponent("MarkdownPreview", isDirectory: true)
                beginLoad(html: html, baseURL: baseURL)
                return
            }

            // Important: When reusing the same WKWebView across hovers, WebKit may not re-run load callbacks and the
            // page may not automatically re-post the same size message. Prefer replaying the cached metrics to the
            // current consumer (popover / measurer) to avoid expensive JS re-measurement during transient layout.
            if let metrics = lastKnownMetrics,
               metrics.size.height > 0,
               !metrics.isEquivalent(to: lastDeliveredMetrics)
            {
                lastDeliveredMetrics = metrics
                scheduleMetricsDelivery(metrics, capturedIdentity: metricDeliveryIdentity)
                // Do not force JS re-measurement here; the cached metrics are sufficient to size the popover/measurer.
                return
            }

            // If WebKit finished but no metrics arrived, explicitly request a fresh report.
            if lastKnownMetrics == nil {
                scheduleContentRefresh(for: webView, forceSizeReport: true)
            }
            return
        }

        lastHTML = html
        lastLoadFinished = false
        pendingContentRefreshTask?.cancel()
        pendingContentRefreshTask = nil
        lastKnownMetrics = nil
        lastDeliveredMetrics = MarkdownContentMetrics(size: .zero, hasHorizontalOverflow: false)
        let baseURL = Bundle.main.resourceURL?.appendingPathComponent("MarkdownPreview", isDirectory: true)
        beginLoad(html: html, baseURL: baseURL)
    }

    // MARK: - WKNavigationDelegate / WKUIDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        MarkdownPreviewNavigationPolicy.handle(
            navigationAction,
            in: webView,
            decisionHandler: decisionHandler
        )
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === currentNavigation else { return }
        HistoryHoverPreviewPipeline.logHoverStage("webview navigation finished")
        currentNavigation = nil
        lastLoadFinished = true
        failedOwnerID = nil
        if let desiredShouldScroll {
            _ = applyScrollConfigurationIfPossible(desiredShouldScroll)
        }
        scheduleContentRefresh(for: webView, forceSizeReport: false)
        if currentOwnerID == nil, let key = prewarmRenderCacheKey, !key.isEmpty {
            probePrewarmLayout(renderID: currentRenderID, renderCacheKey: key)
        }
    }

    private var prewarmProbeTask: Task<Void, Never>?

    /// Offscreen, animation frames never run, so the page cannot report terminal metrics. Ask it
    /// for its laid-out height instead and seed the metrics cache with it; the popover then opens
    /// at that size and the real report after presentation confirms or corrects it.
    private func probePrewarmLayout(renderID: String, renderCacheKey: String) {
        prewarmProbeTask?.cancel()
        prewarmProbeTask = Task { @MainActor [weak self] in
            for _ in 0..<40 {
                guard let self, !Task.isCancelled, self.currentRenderID == renderID, self.currentOwnerID == nil else { return }
                if self.lastKnownMetrics != nil { return }
                let result = try? await self.webView.evaluateJavaScript(
                    "window.__scopyProbeLayoutHeight ? window.__scopyProbeLayoutHeight() : null"
                )
                if let dict = result as? [String: Any], let height = dict["height"] as? Double, height > 0 {
                    let width = HoverPreviewScreenMetrics.maxMarkdownPopoverWidthPoints()
                    let metrics = MarkdownContentMetrics(
                        size: CGSize(width: width, height: height),
                        hasHorizontalOverflow: false,
                        renderSucceeded: true
                    )
                    MarkdownPreviewCache.shared.setMetrics(metrics, forKey: renderCacheKey)
                    HistoryHoverPreviewPipeline.logHoverStage("prewarm layout height=\(Int(height)) fontsReady=\(dict["fontsReady"] as? Bool ?? false)")
                    return
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(navigation, in: webView, reason: error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(navigation, in: webView, reason: error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        handleNavigationFailure(nil, in: webView, reason: "Web content process terminated")
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let metrics = MarkdownPreviewMessageParser.metrics(from: message) else { return }
        guard message.frameInfo.isMainFrame, metrics.renderID == currentRenderID else { return }
        // A layout at zero width (SwiftUI's popover measurement pass) describes nothing.
        guard webView.bounds.width >= 1 else { return }
        if lastKnownMetrics == nil {
            HistoryHoverPreviewPipeline.logHoverStage("webview rendered height=\(Int(metrics.size.height)) ok=\(metrics.renderSucceeded)")
        }
        lastKnownMetrics = metrics
        webView.alphaValue = metrics.renderSucceeded ? 1 : 0
        if currentOwnerID == nil, metrics.renderSucceeded, let key = prewarmRenderCacheKey, !key.isEmpty {
            MarkdownPreviewCache.shared.setMetrics(
                HistoryHoverPreviewPipeline.stableMetrics(from: metrics, text: ""),
                forKey: key
            )
        }

        if metrics.isEquivalent(to: lastDeliveredMetrics) { return }
        lastDeliveredMetrics = metrics

        reconcileScrollbarAttachmentAfterMetrics()
        scheduleMetricsDelivery(metrics, capturedIdentity: metricDeliveryIdentity)
    }

    func reconcileScrollbarAttachmentAfterMetrics() {
        guard let scrollView = MarkdownPreviewScrollViewResolver.resolve(for: webView) else { return }
        scrollbarAutoHider.attach(to: scrollView)
    }

    private func beginLoad(html: String, baseURL: URL?) {
        currentRenderID = UUID().uuidString
        currentRenderKey = html
        failedOwnerID = nil
        lastLoadFinished = false
        navigationStartCount += 1
        webView.alphaValue = 0
        let document = MarkdownPreviewRenderIdentity.injecting(currentRenderID, into: html)
        HistoryHoverPreviewPipeline.logHoverStage("webview navigation start width=\(Int(webView.bounds.width)) window=\(webView.window != nil)")
        currentNavigation = webView.loadHTMLString(document, baseURL: baseURL)
    }

    var metricDeliveryIdentity: MarkdownPreviewMetricDeliveryIdentity {
        MarkdownPreviewMetricDeliveryIdentity(
            ownerID: currentOwnerID,
            renderID: currentRenderID,
            renderKey: currentRenderKey
        )
    }

    func scheduleMetricsDelivery(
        _ metrics: MarkdownContentMetrics,
        capturedIdentity: MarkdownPreviewMetricDeliveryIdentity
    ) {
        guard metrics.renderID == capturedIdentity.renderID,
              let callback = onContentSizeChange
        else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self, self.metricDeliveryIdentity == capturedIdentity else { return }
            callback(metrics)
        }
    }

    private func handleNavigationFailure(_ navigation: WKNavigation?, in webView: WKWebView, reason: String) {
        if let navigation {
            guard navigation === currentNavigation else { return }
        }
        guard !currentRenderID.isEmpty else { return }

        pendingContentRefreshTask?.cancel()
        pendingContentRefreshTask = nil
        currentNavigation = nil
        lastLoadFinished = false
        failedOwnerID = currentOwnerID
        lastKnownMetrics = nil
        webView.alphaValue = 0

        let metrics = MarkdownContentMetrics(
            size: CGSize(width: max(1, webView.bounds.width), height: max(1, webView.bounds.height)),
            hasHorizontalOverflow: false,
            renderSucceeded: false,
            renderErrorReason: reason,
            renderID: currentRenderID
        )
        guard !metrics.isEquivalent(to: lastDeliveredMetrics) else { return }
        lastDeliveredMetrics = metrics
        scheduleMetricsDelivery(metrics, capturedIdentity: metricDeliveryIdentity)
    }

    private func scheduleContentRefresh(for webView: WKWebView, forceSizeReport: Bool) {
        pendingContentRefreshTask?.cancel()
        pendingContentRefreshTask = Task { @MainActor in
            // SwiftUI can call `updateNSView` before the representable receives its final size.
            // Avoid forcing `__scopyReportHeight` while the web view is still in a transient 0-width layout state,
            // otherwise we may cache a bogus tiny width and poison future popover sizing.
            var attempts = 0
            while attempts < 60 {
                if webView.bounds.width > 1 { break }
                attempts += 1
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard !Task.isCancelled else { return }
            }
            guard webView.bounds.width > 1 else { return }
            requestContentRefresh(for: webView, forceSizeReport: forceSizeReport)
        }
    }

    private func requestContentRefresh(for webView: WKWebView, forceSizeReport: Bool) {
        // Best-effort: ensure math render & size reporting run even if DOMContentLoaded timing varies,
        // and for reuse cases where the web view is re-attached without a navigation finishing.
        webView.evaluateJavaScript("typeof window.__scopyRenderMath === 'function'") { result, _ in
            guard let ok = result as? Bool, ok else { return }
            webView.evaluateJavaScript("window.__scopyRenderMath()") { _, _ in }
        }
        webView.evaluateJavaScript("typeof window.__scopyReportHeight === 'function'") { result, _ in
            guard let ok = result as? Bool, ok else { return }
            let force = forceSizeReport ? "true" : "false"
            webView.evaluateJavaScript("window.__scopyReportHeight(\(force))") { _, _ in }
        }
    }
}

struct ReusableMarkdownPreviewWebView: NSViewRepresentable {
    @ObservedObject var controller: MarkdownPreviewWebViewController
    let html: String
    let shouldScroll: Bool
    let onContentSizeChange: @MainActor (MarkdownContentMetrics) -> Void

    @MainActor
    final class Coordinator {
        let ownerID = UUID()
        weak var controller: MarkdownPreviewWebViewController?

        init(controller: MarkdownPreviewWebViewController) {
            self.controller = controller
        }
    }

    @MainActor
    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    @MainActor
    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.controller = controller
        controller.beginOwnership(context.coordinator.ownerID)
        return controller.webView
    }

    @MainActor
    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.controller = controller
        guard controller.owns(context.coordinator.ownerID) else { return }
        controller.onContentSizeChange = onContentSizeChange
        controller.setShouldScroll(shouldScroll)
        controller.loadHTMLIfNeeded(html)
        if ProcessInfo.processInfo.arguments.contains("--uitesting") {
            // XCUITest sometimes fails to discover SwiftUI overlay controls when WKWebView contributes its own
            // accessibility tree. Hide the web view from accessibility during UI tests to make overlay buttons
            // (e.g. export) reliably queryable/clickable.
            webView.setAccessibilityElement(false)
        }
    }

    @MainActor
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        // A stale SwiftUI representable may dismantle after the shared WKWebView has already moved
        // to a newer popover. Only the current ownership lease may stop or detach that WebView.
        coordinator.controller?.endOwnership(coordinator.ownerID)
    }
}

/// Ensures scrollbars stay hidden when idle and only appear while scrolling.
/// This intentionally overrides the system "always show scroll bars" preference for hover-preview surfaces.
@MainActor
final class ScrollbarAutoHider: NSObject {
    private final class HideTimerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var timer: DispatchSourceTimer?

        func hasTimer() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return timer != nil
        }

        func set(_ timer: DispatchSourceTimer?) {
            lock.lock()
            defer { lock.unlock() }
            self.timer = timer
        }

        func take() -> DispatchSourceTimer? {
            lock.lock()
            defer { lock.unlock() }
            let value = timer
            timer = nil
            return value
        }
    }

    private weak var scrollView: NSScrollView?
    private weak var contentView: NSClipView?
    nonisolated private let hideTimerBox = HideTimerBox()
    private var hideDeadline: CFAbsoluteTime = 0
    private var scrollersVisible: Bool = false
    private var lastObservedScrollOrigin: NSPoint?

    func attach(to scrollView: NSScrollView) {
        if self.scrollView === scrollView { return }
        detach()
        self.scrollView = scrollView
        self.contentView = scrollView.contentView
        lastObservedScrollOrigin = scrollView.contentView.bounds.origin
        scrollView.contentView.postsBoundsChangedNotifications = true

        if let contentView = scrollView.contentView as NSClipView? {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAnyScroll(_:)),
                name: NSView.boundsDidChangeNotification,
                object: contentView
            )
        }

        applyHiddenState()
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !self.scrollersVisible else { return }
            self.applyHiddenState()
        }
    }

    func detach() {
        stopHideTimer()

        if let contentView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: contentView)
        }
        scrollView = nil
        contentView = nil
        lastObservedScrollOrigin = nil
        scrollersVisible = false
    }

    deinit {
        hideTimerBox.take()?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func applyHiddenState() {
        guard let scrollView else { return }
        if let vs = scrollView.verticalScroller {
            vs.isHidden = true
            vs.alphaValue = 0
        }
        if let hs = scrollView.horizontalScroller {
            hs.isHidden = true
            hs.alphaValue = 0
        }
        scrollersVisible = false
    }

    @objc private func handleAnyScroll(_ notification: Notification) {
        guard let contentView,
              let observedView = notification.object as? NSClipView,
              observedView === contentView
        else {
            return
        }
        let origin = contentView.bounds.origin
        defer { lastObservedScrollOrigin = origin }
        guard let previousOrigin = lastObservedScrollOrigin else { return }
        guard abs(origin.x - previousOrigin.x) > 0.5 || abs(origin.y - previousOrigin.y) > 0.5 else { return }
        showScrollersIfNeeded()
        hideDeadline = CFAbsoluteTimeGetCurrent() + 0.75
        startHideTimerIfNeeded()
    }

    private func showScrollersIfNeeded() {
        guard !scrollersVisible else { return }
        guard let scrollView else { return }
        if let vs = scrollView.verticalScroller {
            vs.isHidden = false
            vs.alphaValue = 1
        }
        if let hs = scrollView.horizontalScroller {
            hs.isHidden = false
            hs.alphaValue = 1
        }
        scrollersVisible = true
    }

    private func startHideTimerIfNeeded() {
        guard !hideTimerBox.hasTimer() else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.12, repeating: 0.12)
        timer.setEventHandler { [weak self] in
            self?.handleHideTimerTick()
        }
        hideTimerBox.set(timer)
        timer.resume()
    }

    private func stopHideTimer() {
        hideTimerBox.take()?.cancel()
    }

    private func handleHideTimerTick() {
        guard scrollersVisible else {
            stopHideTimer()
            return
        }
        guard CFAbsoluteTimeGetCurrent() >= hideDeadline else { return }
        applyHiddenState()
        stopHideTimer()
    }
}
