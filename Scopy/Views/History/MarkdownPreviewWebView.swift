import Foundation
import SwiftUI
import AppKit
import WebKit

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

struct MarkdownContentMetrics: Equatable {
    let size: CGSize
    let hasHorizontalOverflow: Bool
}

struct MarkdownPreviewWebView: NSViewRepresentable {
    let html: String
    let shouldScroll: Bool
    let onContentSizeChange: @MainActor (MarkdownContentMetrics) -> Void

    private static let blockNetworkRuleListIdentifier = "ScopyMarkdownPreviewBlockNetwork"
    private static let sizeMessageHandlerName = "scopySize"
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

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController = WKUserContentController()

        Self.installNetworkBlocker(into: config.userContentController)
        config.userContentController.add(context.coordinator, name: Self.sizeMessageHandlerName)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        configureScrollers(for: webView, shouldScroll: shouldScroll)
        context.coordinator.attachScrollbarAutoHiderIfPossible(for: webView)
        return webView
    }

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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

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

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var lastHTML: String = ""
        var onContentSizeChange: (@MainActor (MarkdownContentMetrics) -> Void)?
        private var lastReportedMetrics: MarkdownContentMetrics = MarkdownContentMetrics(size: .zero, hasHorizontalOverflow: false)
        let scrollbarAutoHider = ScrollbarAutoHider()

        func attachScrollbarAutoHiderIfPossible(for webView: WKWebView) {
            if let scrollView = MarkdownPreviewScrollViewResolver.resolve(for: webView) {
                scrollbarAutoHider.attach(to: scrollView)
                scrollbarAutoHider.applyHiddenState()
                DispatchQueue.main.async { [weak scrollbarAutoHider] in
                    scrollbarAutoHider?.applyHiddenState()
                }
            } else {
                DispatchQueue.main.async { [weak self, weak webView] in
                    guard let self, let webView else { return }
                    if let scrollView = MarkdownPreviewScrollViewResolver.resolve(for: webView) {
                        self.scrollbarAutoHider.attach(to: scrollView)
                        self.scrollbarAutoHider.applyHiddenState()
                        DispatchQueue.main.async { [weak scrollbarAutoHider = self.scrollbarAutoHider] in
                            scrollbarAutoHider?.applyHiddenState()
                        }
                    }
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
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
            guard message.name == MarkdownPreviewWebView.sizeMessageHandlerName else { return }

            var size: CGSize?
            var overflowX: Bool = false
            if let dict = message.body as? [String: Any] {
                let w = dict["width"]
                let h = dict["height"]
                size = CGSize(width: Self.cgFloat(from: w), height: Self.cgFloat(from: h))
                if let b = dict["overflowX"] as? Bool {
                    overflowX = b
                } else if let n = dict["overflowX"] as? NSNumber {
                    overflowX = n.boolValue
                } else if let s = dict["overflowX"] as? String {
                    overflowX = (s == "true" || s == "1")
                }
            } else if let dict = message.body as? NSDictionary {
                let w = dict["width"]
                let h = dict["height"]
                size = CGSize(width: Self.cgFloat(from: w), height: Self.cgFloat(from: h))
                if let b = dict["overflowX"] as? Bool {
                    overflowX = b
                } else if let n = dict["overflowX"] as? NSNumber {
                    overflowX = n.boolValue
                } else if let s = dict["overflowX"] as? String {
                    overflowX = (s == "true" || s == "1")
                }
            } else if let n = message.body as? NSNumber {
                // Backward-compatible: height-only payload.
                size = CGSize(width: 0, height: CGFloat(truncating: n))
            }

            guard let size else { return }
            guard size.width.isFinite, size.height.isFinite else { return }
            guard size.height > 0 else { return }

            let metrics = MarkdownContentMetrics(size: size, hasHorizontalOverflow: overflowX)
            if abs(metrics.size.width - lastReportedMetrics.size.width) < 1,
               abs(metrics.size.height - lastReportedMetrics.size.height) < 1,
               metrics.hasHorizontalOverflow == lastReportedMetrics.hasHorizontalOverflow
            {
                return
            }
            lastReportedMetrics = metrics

            if let wk = message.webView as? WKWebView {
                attachScrollbarAutoHiderIfPossible(for: wk)
            }
            Task { @MainActor in
                self.onContentSizeChange?(metrics)
            }
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
}

@MainActor
final class MarkdownPreviewWebViewController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let webView: WKWebView

    var onContentSizeChange: (@MainActor (MarkdownContentMetrics) -> Void)?
    private var lastHTML: String = ""
    private var lastReportedMetrics: MarkdownContentMetrics = MarkdownContentMetrics(size: .zero, hasHorizontalOverflow: false)
    private let scrollbarAutoHider = ScrollbarAutoHider()

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
        config.userContentController.add(self, name: "scopySize")

        wv.navigationDelegate = self
        wv.uiDelegate = self
    }

    func setShouldScroll(_ shouldScroll: Bool) {
        guard let scrollView = MarkdownPreviewScrollViewResolver.resolve(for: webView) else { return }
        scrollView.hasVerticalScroller = shouldScroll
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollbarAutoHider.attach(to: scrollView)
        scrollbarAutoHider.applyHiddenState()
        DispatchQueue.main.async { [weak scrollbarAutoHider] in
            scrollbarAutoHider?.applyHiddenState()
        }
    }

    func loadHTMLIfNeeded(_ html: String) {
        if lastHTML == html { return }
        lastHTML = html
        lastReportedMetrics = MarkdownContentMetrics(size: .zero, hasHorizontalOverflow: false)
        let baseURL = Bundle.main.resourceURL?.appendingPathComponent("MarkdownPreview", isDirectory: true)
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    // MARK: - WKNavigationDelegate / WKUIDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
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
        webView.evaluateJavaScript("typeof window.__scopyRenderMath === 'function'") { result, _ in
            guard let ok = result as? Bool, ok else { return }
            webView.evaluateJavaScript("window.__scopyRenderMath()") { _, _ in }
        }
        webView.evaluateJavaScript("typeof window.__scopyReportHeight === 'function'") { result, _ in
            guard let ok = result as? Bool, ok else { return }
            webView.evaluateJavaScript("window.__scopyReportHeight()") { _, _ in }
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "scopySize" else { return }

        var size: CGSize?
        var overflowX: Bool = false
        if let dict = message.body as? [String: Any] {
            let w = dict["width"]
            let h = dict["height"]
            size = CGSize(width: Self.cgFloat(from: w), height: Self.cgFloat(from: h))
            if let b = dict["overflowX"] as? Bool {
                overflowX = b
            } else if let n = dict["overflowX"] as? NSNumber {
                overflowX = n.boolValue
            } else if let s = dict["overflowX"] as? String {
                overflowX = (s == "true" || s == "1")
            }
        } else if let dict = message.body as? NSDictionary {
            let w = dict["width"]
            let h = dict["height"]
            size = CGSize(width: Self.cgFloat(from: w), height: Self.cgFloat(from: h))
            if let b = dict["overflowX"] as? Bool {
                overflowX = b
            } else if let n = dict["overflowX"] as? NSNumber {
                overflowX = n.boolValue
            } else if let s = dict["overflowX"] as? String {
                overflowX = (s == "true" || s == "1")
            }
        } else if let n = message.body as? NSNumber {
            size = CGSize(width: 0, height: CGFloat(truncating: n))
        }

        guard let size else { return }
        guard size.width.isFinite, size.height.isFinite else { return }
        guard size.height > 0 else { return }

        let metrics = MarkdownContentMetrics(size: size, hasHorizontalOverflow: overflowX)
        if abs(metrics.size.width - lastReportedMetrics.size.width) < 1,
           abs(metrics.size.height - lastReportedMetrics.size.height) < 1,
           metrics.hasHorizontalOverflow == lastReportedMetrics.hasHorizontalOverflow
        {
            return
        }
        lastReportedMetrics = metrics

        if let scrollView = MarkdownPreviewScrollViewResolver.resolve(for: webView) {
            scrollbarAutoHider.attach(to: scrollView)
            scrollbarAutoHider.applyHiddenState()
            DispatchQueue.main.async { [weak scrollbarAutoHider] in
                scrollbarAutoHider?.applyHiddenState()
            }
        }
        Task { @MainActor in
            self.onContentSizeChange?(metrics)
        }
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

struct ReusableMarkdownPreviewWebView: NSViewRepresentable {
    @ObservedObject var controller: MarkdownPreviewWebViewController
    let html: String
    let shouldScroll: Bool
    let onContentSizeChange: @MainActor (MarkdownContentMetrics) -> Void

    func makeNSView(context: Context) -> WKWebView {
        controller.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        controller.onContentSizeChange = onContentSizeChange
        controller.setShouldScroll(shouldScroll)
        controller.loadHTMLIfNeeded(html)
    }
}

/// Ensures scrollbars stay hidden when idle and only appear while scrolling.
/// This intentionally overrides the system "always show scroll bars" preference for hover-preview surfaces.
final class ScrollbarAutoHider: NSObject {
    private weak var scrollView: NSScrollView?
    private weak var contentView: NSClipView?
    private var hideWorkItem: DispatchWorkItem?

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
        DispatchQueue.main.async { [weak self] in
            self?.applyHiddenState()
        }
    }

    func detach() {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        if let contentView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: contentView)
        }
        scrollView = nil
        contentView = nil
    }

    deinit {
        detach()
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
    }

    @objc private func handleAnyScroll(_ notification: Notification) {
        showScrollers()
        scheduleHide()
    }

    private func showScrollers() {
        guard let scrollView else { return }
        if let vs = scrollView.verticalScroller {
            vs.isHidden = false
            vs.alphaValue = 1
        }
        if let hs = scrollView.horizontalScroller {
            hs.isHidden = false
            hs.alphaValue = 1
        }
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applyHiddenState()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }
}
