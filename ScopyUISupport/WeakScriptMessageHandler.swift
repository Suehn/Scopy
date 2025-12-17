import Foundation
import WebKit

/// A WKScriptMessageHandler proxy that weakly forwards messages to the real handler.
///
/// Rationale:
/// - WKUserContentController retains registered handlers strongly.
/// - Registering a controller (`self`) as the handler while also owning the WKWebView often forms a retain cycle.
public final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    public weak var delegate: WKScriptMessageHandler?

    public init(delegate: WKScriptMessageHandler? = nil) {
        self.delegate = delegate
        super.init()
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

