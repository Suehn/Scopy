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
    static func shouldAllow(
        navigationType: WKNavigationType,
        targetFrameIsNil: Bool,
        url: URL?,
        currentURL: URL? = nil
    ) -> Bool {
        if targetFrameIsNil { return false }
        if navigationType == .linkActivated {
            return isSameDocumentFragmentNavigation(url: url, currentURL: currentURL)
        }
        if let scheme = url?.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return false
        }
        return true
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
        private var currentNavigation: WKNavigation?
        let scrollbarAutoHider = ScrollbarAutoHider()
        let sizeMessageHandlerProxy = WeakScriptMessageHandler()

        override init() {
            super.init()
            sizeMessageHandlerProxy.delegate = self
        }

        func load(html: String, in webView: WKWebView, baseURL: URL?) {
            currentRenderID = UUID().uuidString
            lastReportedMetrics = MarkdownContentMetrics(size: .zero, hasHorizontalOverflow: false)
            let document = MarkdownPreviewRenderIdentity.injecting(currentRenderID, into: html)
            currentNavigation = webView.loadHTMLString(document, baseURL: baseURL)
        }

        func attachScrollbarAutoHiderIfPossible(for webView: WKWebView) {
            if let scrollView = MarkdownPreviewScrollViewResolver.resolve(for: webView) {
                scrollbarAutoHider.attach(to: scrollView)
                scrollbarAutoHider.applyHiddenState()
                Task { @MainActor [weak scrollbarAutoHider] in
                    await Task.yield()
                    scrollbarAutoHider?.applyHiddenState()
                }
            } else {
                Task { @MainActor [weak self, weak webView] in
                    await Task.yield()
                    guard let self, let webView else { return }
                    if let scrollView = MarkdownPreviewScrollViewResolver.resolve(for: webView) {
                        self.scrollbarAutoHider.attach(to: scrollView)
                        self.scrollbarAutoHider.applyHiddenState()
                        await Task.yield()
                        self.scrollbarAutoHider.applyHiddenState()
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
            let shouldAllow = MarkdownPreviewNavigationPolicy.shouldAllow(
                navigationType: navigationAction.navigationType,
                targetFrameIsNil: navigationAction.targetFrame == nil,
                url: navigationAction.request.url,
                currentURL: webView.url
            )
            decisionHandler(shouldAllow ? .allow : .cancel)
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

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let metrics = MarkdownPreviewMessageParser.metrics(from: message) else { return }
            guard message.frameInfo.isMainFrame, metrics.renderID == currentRenderID else { return }
            if metrics.isEquivalent(to: lastReportedMetrics) { return }
            lastReportedMetrics = metrics

            if let wk = message.webView {
                attachScrollbarAutoHiderIfPossible(for: wk)
            }
            Task { @MainActor in
                self.onContentSizeChange?(metrics)
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
    private var currentNavigation: WKNavigation?
    private var pendingContentRefreshTask: Task<Void, Never>?
    private let scrollbarAutoHider = ScrollbarAutoHider()
    private let sizeMessageHandlerProxy = WeakScriptMessageHandler()

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController = WKUserContentController()

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsMagnification = false
        wv.setValue(false, forKey: "drawsBackground")
        self.webView = wv
        super.init()

        // Reuse the same network blocker & message handler semantics as the one-shot web view.
        MarkdownPreviewWebView.installNetworkBlocker(into: config.userContentController)
        sizeMessageHandlerProxy.delegate = self
        config.userContentController.add(sizeMessageHandlerProxy, name: MarkdownPreviewWebView.sizeMessageHandlerName)

        attachWebViewIfNeeded()
    }

    func attachWebViewIfNeeded() {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: MarkdownPreviewWebView.sizeMessageHandlerName)
        controller.add(sizeMessageHandlerProxy, name: MarkdownPreviewWebView.sizeMessageHandlerName)

        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func detachWebView() {
        pendingContentRefreshTask?.cancel()
        pendingContentRefreshTask = nil
        if currentNavigation != nil { lastLoadFinished = false }
        currentNavigation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: MarkdownPreviewWebView.sizeMessageHandlerName)
        scrollbarAutoHider.detach()
        onContentSizeChange = nil
        // Allow the next consumer (popover / measurer) to receive a fresh metrics callback even if the size is unchanged.
        lastDeliveredMetrics = MarkdownContentMetrics(size: .zero, hasHorizontalOverflow: false)
    }

    func setShouldScroll(_ shouldScroll: Bool) {
        attachWebViewIfNeeded()
        guard let scrollView = MarkdownPreviewScrollViewResolver.resolve(for: webView) else { return }
        scrollView.hasVerticalScroller = shouldScroll
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollbarAutoHider.attach(to: scrollView)
        scrollbarAutoHider.applyHiddenState()
        Task { @MainActor [weak scrollbarAutoHider] in
            await Task.yield()
            scrollbarAutoHider?.applyHiddenState()
        }
    }

    func loadHTMLIfNeeded(_ html: String) {
        attachWebViewIfNeeded()

        if lastHTML == html {
            if !lastLoadFinished {
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
                Task { @MainActor in
                    self.onContentSizeChange?(metrics)
                }
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
        let shouldAllow = MarkdownPreviewNavigationPolicy.shouldAllow(
            navigationType: navigationAction.navigationType,
            targetFrameIsNil: navigationAction.targetFrame == nil,
            url: navigationAction.request.url,
            currentURL: webView.url
        )
        decisionHandler(shouldAllow ? .allow : .cancel)
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
        lastLoadFinished = true
        scheduleContentRefresh(for: webView, forceSizeReport: false)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let metrics = MarkdownPreviewMessageParser.metrics(from: message) else { return }
        guard message.frameInfo.isMainFrame, metrics.renderID == currentRenderID else { return }
        lastKnownMetrics = metrics

        if metrics.isEquivalent(to: lastDeliveredMetrics) { return }
        lastDeliveredMetrics = metrics

        if let scrollView = MarkdownPreviewScrollViewResolver.resolve(for: webView) {
            scrollbarAutoHider.attach(to: scrollView)
            scrollbarAutoHider.applyHiddenState()
            Task { @MainActor [weak scrollbarAutoHider] in
                await Task.yield()
                scrollbarAutoHider?.applyHiddenState()
            }
        }
        Task { @MainActor in
            self.onContentSizeChange?(metrics)
        }
    }

    private func beginLoad(html: String, baseURL: URL?) {
        currentRenderID = UUID().uuidString
        lastLoadFinished = false
        let document = MarkdownPreviewRenderIdentity.injecting(currentRenderID, into: html)
        currentNavigation = webView.loadHTMLString(document, baseURL: baseURL)
    }

    private func scheduleContentRefresh(for webView: WKWebView, forceSizeReport: Bool) {
        pendingContentRefreshTask?.cancel()
        pendingContentRefreshTask = Task { @MainActor in
            // SwiftUI can call `updateNSView` before the representable receives its final size.
            // Avoid forcing `__scopyReportHeight` while the web view is still in a transient 0-width layout state,
            // otherwise we may cache a bogus tiny width and poison future popover sizing.
            var attempts = 0
            while attempts < 12 {
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
    func makeNSView(context: Context) -> WKWebView {
        controller.attachWebViewIfNeeded()
        return controller.webView
    }

    @MainActor
    func updateNSView(_ webView: WKWebView, context: Context) {
        controller.attachWebViewIfNeeded()
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
    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) {
        // Ensure the controller does not keep WebKit delegates/handlers alive when the view is removed.
        if let controller = (nsView.navigationDelegate as? MarkdownPreviewWebViewController) {
            controller.detachWebView()
        } else {
            nsView.stopLoading()
            nsView.navigationDelegate = nil
            nsView.uiDelegate = nil
            nsView.configuration.userContentController.removeScriptMessageHandler(forName: MarkdownPreviewWebView.sizeMessageHandlerName)
        }
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

    func attach(to scrollView: NSScrollView) {
        if self.scrollView === scrollView { return }
        detach()
        self.scrollView = scrollView
        self.contentView = scrollView.contentView
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
            self?.applyHiddenState()
        }
    }

    func detach() {
        stopHideTimer()

        if let contentView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: contentView)
        }
        scrollView = nil
        contentView = nil
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
