import XCTest
import WebKit

@testable import Scopy

@MainActor
final class WebViewLifecycleTests: XCTestCase {

    func testMarkdownPreviewWebViewControllerDeinitializesAfterRelease() {
        weak var weakController: MarkdownPreviewWebViewController?

        autoreleasepool {
            let controller = MarkdownPreviewWebViewController()
            controller.onContentSizeChange = { _ in }
            controller.loadHTMLIfNeeded("<html><body>hi</body></html>")
            weakController = controller
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(weakController, "Expected controller to deinit (no retain cycle via script message handler)")
    }
}

