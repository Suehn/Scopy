import Foundation
import WebKit

/// The one WebKit configuration shared by the Markdown preview WebView and the PNG export WebView:
/// local source-icon scheme, non-persistent data store, no script-opened windows, and a compiled
/// content rule list that blocks every HTTP(S) load.
@MainActor
public enum MarkdownWebKitEnvironment {
    private static let ruleListIdentifier = "ScopyMarkdownBlockNetwork"
    private static let rulesJSON = """
    [
      {
        "trigger": { "url-filter": "https?://.*" },
        "action": { "type": "block" }
      }
    ]
    """
    private static var ruleList: WKContentRuleList?
    private static var compileTask: Task<WKContentRuleList?, Never>?
    private static let controllersAwaitingRules = NSHashTable<WKUserContentController>.weakObjects()

    /// Compiles the network-blocking rule list once and returns it; `nil` if WebKit rejected it.
    @discardableResult
    public static func prepareRules() async -> WKContentRuleList? {
        if let ruleList { return ruleList }
        return await (compileTask ?? startCompiling()).value
    }

    /// A configuration with an empty `WKUserContentController`. When the rule list is still
    /// compiling, it is attached to that controller as soon as compilation finishes.
    public static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        SourceIconSchemeHandler.install(in: configuration)
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let controller = WKUserContentController()
        configuration.userContentController = controller
        if let ruleList {
            controller.add(ruleList)
        } else {
            controllersAwaitingRules.add(controller)
            if compileTask == nil { _ = startCompiling() }
        }
        return configuration
    }

    private static func startCompiling() -> Task<WKContentRuleList?, Never> {
        let task = Task { @MainActor () -> WKContentRuleList? in
            let compiled = await withCheckedContinuation { continuation in
                WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: ruleListIdentifier,
                    encodedContentRuleList: rulesJSON
                ) { ruleList, _ in
                    continuation.resume(returning: ruleList)
                }
            }
            ruleList = compiled
            compileTask = nil
            if let compiled {
                for controller in controllersAwaitingRules.allObjects {
                    controller.add(compiled)
                }
                controllersAwaitingRules.removeAllObjects()
            }
            return compiled
        }
        compileTask = task
        return task
    }
}
