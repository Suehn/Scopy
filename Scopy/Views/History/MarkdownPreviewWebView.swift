import Foundation
import SwiftUI
import AppKit
import WebKit
import ScopyUISupport

@MainActor
private enum MarkdownPreviewScrollViewResolver {
    static func resolve(for view: NSView) -> NSScrollView? {
        if let sv = view as? NSScrollView { return sv }
        if let sv = view.enclosingScrollView { return sv }
        return findFirstScrollView(in: view)
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
        if let dict = message.body as? [String: Any] {
            size = parseSize(from: dict)
            overflowX = parseOverflow(from: dict["overflowX"])
        } else if let dict = message.body as? NSDictionary {
            size = CGSize(width: cgFloat(from: dict["width"]), height: cgFloat(from: dict["height"]))
            overflowX = parseOverflow(from: dict["overflowX"])
        } else if let n = message.body as? NSNumber {
            // Backward-compatible: height-only payload.
            size = CGSize(width: 0, height: CGFloat(truncating: n))
        }

        guard let size else { return nil }
        guard size.width.isFinite, size.height.isFinite else { return nil }
        guard size.height > 0 else { return nil }
        return MarkdownContentMetrics(size: size, hasHorizontalOverflow: overflowX)
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

struct MarkdownContentMetrics: Equatable {
    let size: CGSize
    let hasHorizontalOverflow: Bool
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
            webView.loadHTMLString(html, baseURL: baseURL)
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
        let scrollbarAutoHider = ScrollbarAutoHider()
        let sizeMessageHandlerProxy = WeakScriptMessageHandler()

        override init() {
            super.init()
            sizeMessageHandlerProxy.delegate = self
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
            if navigationAction.targetFrame == nil {
                decisionHandler(.cancel)
                return
            }
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
                return
            }

            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https"
            {
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
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
            if abs(metrics.size.width - lastReportedMetrics.size.width) < 1,
               abs(metrics.size.height - lastReportedMetrics.size.height) < 1,
               metrics.hasHorizontalOverflow == lastReportedMetrics.hasHorizontalOverflow
            {
                return
            }
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
            // Important: When reusing the same WKWebView across hovers, WebKit may not re-run load callbacks and the
            // page may not automatically re-post the same size message. Prefer replaying the cached metrics to the
            // current consumer (popover / measurer) to avoid expensive JS re-measurement during transient layout.
            if let metrics = lastKnownMetrics,
               metrics.size.height > 0,
               abs(metrics.size.width - lastDeliveredMetrics.size.width) >= 1 ||
                abs(metrics.size.height - lastDeliveredMetrics.size.height) >= 1 ||
                metrics.hasHorizontalOverflow != lastDeliveredMetrics.hasHorizontalOverflow
            {
                lastDeliveredMetrics = metrics
                Task { @MainActor in
                    self.onContentSizeChange?(metrics)
                }
                // Do not force JS re-measurement here; the cached metrics are sufficient to size the popover/measurer.
                return
            }

            if !lastLoadFinished {
                pendingContentRefreshTask?.cancel()
                pendingContentRefreshTask = nil
                // If the last navigation never finished (e.g. hover exited mid-load), retry the load.
                let baseURL = Bundle.main.resourceURL?.appendingPathComponent("MarkdownPreview", isDirectory: true)
                webView.loadHTMLString(html, baseURL: baseURL)
            } else {
                // If we have no known metrics for this HTML (e.g. prior load was interrupted), request one.
                if lastKnownMetrics == nil {
                    scheduleContentRefresh(for: webView, forceSizeReport: true)
                }
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
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    // MARK: - WKNavigationDelegate / WKUIDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.navigationType == .linkActivated {
            decisionHandler(.cancel)
            return
        }

        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https"
        {
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
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
        lastLoadFinished = true
        scheduleContentRefresh(for: webView, forceSizeReport: false)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let metrics = MarkdownPreviewMessageParser.metrics(from: message) else { return }
        lastKnownMetrics = metrics

        if abs(metrics.size.width - lastDeliveredMetrics.size.width) < 1,
           abs(metrics.size.height - lastDeliveredMetrics.size.height) < 1,
           metrics.hasHorizontalOverflow == lastDeliveredMetrics.hasHorizontalOverflow
        {
            return
        }
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
    private weak var scrollView: NSScrollView?
    private weak var contentView: NSClipView?
    private nonisolated(unsafe) var hideTimer: DispatchSourceTimer?
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
        hideTimer?.cancel()
        hideTimer = nil
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
        guard hideTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.12, repeating: 0.12)
        timer.setEventHandler { [weak self] in
            self?.handleHideTimerTick()
        }
        hideTimer = timer
        timer.resume()
    }

    private func stopHideTimer() {
        hideTimer?.cancel()
        hideTimer = nil
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
