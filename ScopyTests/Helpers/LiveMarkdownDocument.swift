import AppKit
import WebKit
import XCTest

/// A real WebKit load of the production Markdown document against a temporary copy of the checked-in
/// atomic asset set (the standalone xctest runner has no app resource directory).
@MainActor
final class LiveMarkdownDocument {
    let webView: WKWebView
    let window: NSWindow
    let assetRoot: URL

    init(webView: WKWebView? = nil) throws {
        let webView = webView ?? WKWebView(frame: CGRect(x: 0, y: 0, width: 816, height: 900))
        self.webView = webView
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        // Occluded windows get no animation frames, and readiness waits for two paint frames; float above other
        // apps like the export host panel does.
        window.level = .statusBar
        window.orderFrontRegardless()
        let checkedInAssets = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scopy/Resources/MarkdownPreview", isDirectory: true)
        assetRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-live-markdown-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: checkedInAssets, to: assetRoot)
    }

    func close() {
        window.close()
        try? FileManager.default.removeItem(at: assetRoot)
    }

    /// Loads `html` as `name` beside the assets and waits until the document reaches a terminal render state
    /// (success or failure). Returns false on timeout.
    @discardableResult
    func load(_ html: String, name: String = "document.html", timeout: TimeInterval = 15) throws -> Bool {
        let url = assetRoot.appendingPathComponent(name)
        try html.write(to: url, atomically: true, encoding: .utf8)
        webView.navigationDelegate = nil
        webView.loadFileURL(url, allowingReadAccessTo: assetRoot)
        return wait(
            until: "Boolean(location.pathname.endsWith('\(name)') && window.ScopyDocument && window.ScopyDocument.state.renderComplete)",
            timeout: timeout
        )
    }

    var isRenderReady: Bool {
        evaluate("Boolean(window.ScopyDocument && window.ScopyDocument.isRenderReady())") as? Bool == true
    }

    func wait(until condition: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if evaluate(condition) as? Bool == true { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    func evaluate(_ script: String, file: StaticString = #filePath, line: UInt = #line) -> Any? {
        var finished = false
        var result: Any?
        webView.evaluateJavaScript(script) { value, error in
            XCTAssertNil(error, file: file, line: line)
            result = value
            finished = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !finished && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(finished, "JavaScript evaluation timed out", file: file, line: line)
        return result
    }
}
