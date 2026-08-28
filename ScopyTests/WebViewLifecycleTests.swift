import XCTest
import WebKit

@testable import Scopy

@MainActor
final class WebViewLifecycleTests: XCTestCase {

    func testScrollConfigurationRetriesWhenWebKitScrollViewAppearsLate() {
        let resolvedScrollView = NSScrollView()
        var resolutionAttempts = 0
        let controller = MarkdownPreviewWebViewController(scrollViewResolver: { _ in
            resolutionAttempts += 1
            return resolutionAttempts == 1 ? nil : resolvedScrollView
        })

        controller.setShouldScroll(true)

        XCTAssertTrue(
            runMainLoopUntil(timeout: 2) { controller.scrollConfigurationCount == 1 },
            "Expected a failed first resolver pass to retry the same desired scroll state"
        )
        XCTAssertGreaterThanOrEqual(resolutionAttempts, 2)
        XCTAssertTrue(resolvedScrollView.hasVerticalScroller)
    }

    func testStaleReusableOwnerCannotDetachCurrentPopover() {
        let controller = MarkdownPreviewWebViewController()
        let firstOwner = UUID()
        let currentOwner = UUID()

        controller.beginOwnership(firstOwner)
        controller.beginOwnership(currentOwner)
        controller.endOwnership(firstOwner)

        XCTAssertTrue(controller.owns(currentOwner))
        XCTAssertTrue(controller.webView.navigationDelegate === controller)
        XCTAssertTrue(controller.webView.uiDelegate === controller)

        controller.endOwnership(currentOwner)
        XCTAssertNil(controller.webView.navigationDelegate)
        XCTAssertNil(controller.webView.uiDelegate)
    }

    func testStaleOwnerCannotCancelCurrentOwnersFirstNavigation() {
        let scrollView = NSScrollView()
        let controller = MarkdownPreviewWebViewController(scrollViewResolver: { _ in scrollView })
        let staleOwner = UUID()
        let currentOwner = UUID()
        let html = "<html><body>first navigation</body></html>"

        controller.beginOwnership(staleOwner)
        controller.setShouldScroll(true)
        controller.loadHTMLIfNeeded(html)
        controller.beginOwnership(currentOwner)
        controller.endOwnership(staleOwner)

        for _ in 0..<100 {
            controller.setShouldScroll(true)
            controller.loadHTMLIfNeeded(html)
        }

        XCTAssertTrue(controller.owns(currentOwner))
        XCTAssertTrue(controller.webView.navigationDelegate === controller)
        XCTAssertTrue(controller.webView.uiDelegate === controller)
        XCTAssertEqual(controller.bridgeAttachmentCount, 1)
        XCTAssertEqual(controller.scrollConfigurationCount, 1)
        XCTAssertEqual(controller.navigationStartCount, 1)
        controller.endOwnership(currentOwner)
    }

    func testRepeatedIdenticalUpdatesDoNotRestartNavigationOrReconfigureBridge() {
        let scrollView = NSScrollView()
        let controller = MarkdownPreviewWebViewController(scrollViewResolver: { _ in scrollView })
        let owner = UUID()
        let html = "<html><body>stable</body></html>"

        controller.beginOwnership(owner)
        for _ in 0..<100 {
            controller.setShouldScroll(true)
            controller.loadHTMLIfNeeded(html)
        }

        XCTAssertEqual(controller.bridgeAttachmentCount, 1)
        XCTAssertEqual(controller.scrollConfigurationCount, 1)
        XCTAssertEqual(controller.navigationStartCount, 1)
    }

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

    private func runMainLoopUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
