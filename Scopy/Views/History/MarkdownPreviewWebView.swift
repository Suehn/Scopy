import Foundation
import SwiftUI
import AppKit
import WebKit

struct MarkdownPreviewWebView: NSViewRepresentable {
    let html: String
    let shouldScroll: Bool
    let onContentHeightChange: @MainActor (CGFloat) -> Void

    private static let blockNetworkRuleListIdentifier = "ScopyMarkdownPreviewBlockNetwork"
    private static let heightMessageHandlerName = "scopyHeight"
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
        config.userContentController.add(context.coordinator, name: Self.heightMessageHandlerName)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        configureScrollers(for: webView, shouldScroll: shouldScroll)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onContentHeightChange = onContentHeightChange
        configureScrollers(for: webView, shouldScroll: shouldScroll)

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
        guard let scrollView = webView.enclosingScrollView else { return }
        scrollView.hasVerticalScroller = shouldScroll
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
    }

    private static func installNetworkBlocker(into controller: WKUserContentController) {
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
        var onContentHeightChange: (@MainActor (CGFloat) -> Void)?
        private var lastReportedHeight: CGFloat = 0

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

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == MarkdownPreviewWebView.heightMessageHandlerName else { return }
            let value: CGFloat?
            if let n = message.body as? NSNumber {
                value = CGFloat(truncating: n)
            } else if let d = message.body as? Double {
                value = CGFloat(d)
            } else if let i = message.body as? Int {
                value = CGFloat(i)
            } else {
                value = nil
            }
            guard let value, value.isFinite, value > 0 else { return }
            if abs(value - lastReportedHeight) < 1 { return }
            lastReportedHeight = value
            Task { @MainActor in
                self.onContentHeightChange?(value)
            }
        }
    }
}
