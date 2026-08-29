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

    func testDeferredMetricsCannotCrossOwnerRenderOrRenderKeyBoundary() {
        let controller = MarkdownPreviewWebViewController()
        let firstOwner = UUID()
        let secondOwner = UUID()
        var deliveries: [String] = []

        controller.beginOwnership(firstOwner)
        controller.loadHTMLIfNeeded("<html><body>first</body></html>")
        let firstIdentity = controller.metricDeliveryIdentity
        controller.onContentSizeChange = { _ in deliveries.append("first") }
        controller.scheduleMetricsDelivery(
            MarkdownContentMetrics(
                size: CGSize(width: 320, height: 200),
                hasHorizontalOverflow: false,
                renderID: firstIdentity.renderID
            ),
            capturedIdentity: firstIdentity
        )

        controller.beginOwnership(secondOwner)
        let ownershipTransferIdentity = controller.metricDeliveryIdentity
        controller.scheduleMetricsDelivery(
            MarkdownContentMetrics(
                size: CGSize(width: 320, height: 220),
                hasHorizontalOverflow: false,
                renderID: ownershipTransferIdentity.renderID
            ),
            capturedIdentity: ownershipTransferIdentity
        )
        controller.onContentSizeChange = { _ in deliveries.append("second") }
        controller.loadHTMLIfNeeded("<html><body>second</body></html>")
        let secondIdentity = controller.metricDeliveryIdentity
        controller.scheduleMetricsDelivery(
            MarkdownContentMetrics(
                size: CGSize(width: 320, height: 240),
                hasHorizontalOverflow: false,
                renderID: secondIdentity.renderID
            ),
            capturedIdentity: secondIdentity
        )

        XCTAssertTrue(runMainLoopUntil(timeout: 1) { deliveries.count == 1 })
        XCTAssertEqual(deliveries, ["second"])
        XCTAssertNotEqual(firstIdentity.ownerID, secondIdentity.ownerID)
        XCTAssertNotEqual(firstIdentity.renderID, secondIdentity.renderID)
        XCTAssertNotEqual(firstIdentity.renderKey, secondIdentity.renderKey)
    }

    func testOneShotDeferredMetricsCannotCrossRenderOrCallbackBoundary() {
        let coordinator = MarkdownPreviewWebView.Coordinator()
        let webView = WKWebView()
        var deliveries: [String] = []

        coordinator.onContentSizeChange = { _ in deliveries.append("first") }
        coordinator.load(html: "<html><body>first</body></html>", in: webView, baseURL: nil)
        let firstIdentity = coordinator.metricDeliveryIdentity
        coordinator.scheduleMetricsDelivery(
            MarkdownContentMetrics(
                size: CGSize(width: 320, height: 200),
                hasHorizontalOverflow: false,
                renderID: firstIdentity.renderID
            ),
            capturedIdentity: firstIdentity
        )

        coordinator.onContentSizeChange = { _ in deliveries.append("second") }
        coordinator.load(html: "<html><body>second</body></html>", in: webView, baseURL: nil)
        let secondIdentity = coordinator.metricDeliveryIdentity
        coordinator.scheduleMetricsDelivery(
            MarkdownContentMetrics(
                size: CGSize(width: 320, height: 240),
                hasHorizontalOverflow: false,
                renderID: secondIdentity.renderID
            ),
            capturedIdentity: secondIdentity
        )

        XCTAssertTrue(runMainLoopUntil(timeout: 1) { deliveries.count == 1 })
        XCTAssertEqual(deliveries, ["second"])
        XCTAssertNotEqual(firstIdentity.renderID, secondIdentity.renderID)
        XCTAssertNotEqual(firstIdentity.callbackID, secondIdentity.callbackID)
    }

    func testWebContentProcessTerminationEmitsFailureAndOnlyNewOwnerCanRetry() {
        let controller = MarkdownPreviewWebViewController()
        let firstOwner = UUID()
        let html = "<html><body>terminates</body></html>"
        var receivedMetrics: MarkdownContentMetrics?

        controller.beginOwnership(firstOwner)
        controller.onContentSizeChange = { receivedMetrics = $0 }
        controller.loadHTMLIfNeeded(html)
        XCTAssertEqual(controller.navigationStartCount, 1)

        controller.webViewWebContentProcessDidTerminate(controller.webView)

        XCTAssertTrue(runMainLoopUntil(timeout: 1) { receivedMetrics != nil })
        XCTAssertEqual(receivedMetrics?.renderSucceeded, false)
        XCTAssertEqual(receivedMetrics?.renderErrorReason, "Web content process terminated")

        controller.loadHTMLIfNeeded(html)
        XCTAssertEqual(controller.navigationStartCount, 1, "A terminal failure must not spin the same owner into a retry loop")

        controller.beginOwnership(UUID())
        controller.loadHTMLIfNeeded(html)
        XCTAssertEqual(controller.navigationStartCount, 2, "A new owner may explicitly retry the failed document")
    }

    func testScrollbarIgnoresLayoutBoundsChangesAndShowsForOriginScroll() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        scrollView.hasVerticalScroller = true
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 480))
        scrollView.layoutSubtreeIfNeeded()
        let hider = ScrollbarAutoHider()
        hider.attach(to: scrollView)
        hider.applyHiddenState()
        let verticalScroller = try XCTUnwrap(scrollView.verticalScroller)
        let clipView = scrollView.contentView

        clipView.setFrameSize(NSSize(width: 220, height: 120))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clipView)
        XCTAssertTrue(verticalScroller.isHidden)
        XCTAssertEqual(verticalScroller.alphaValue, 0)

        clipView.setBoundsOrigin(NSPoint(x: 0, y: 24))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clipView)
        XCTAssertFalse(verticalScroller.isHidden)
        XCTAssertEqual(verticalScroller.alphaValue, 1)

        hider.detach()
    }

    func testMetricsReconciliationDoesNotHideScrollersDuringActiveScroll() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 480))
        scrollView.layoutSubtreeIfNeeded()
        let controller = MarkdownPreviewWebViewController(scrollViewResolver: { _ in scrollView })
        controller.setShouldScroll(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        let verticalScroller = try XCTUnwrap(scrollView.verticalScroller)
        let clipView = scrollView.contentView
        clipView.setBoundsOrigin(NSPoint(x: 0, y: 24))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clipView)
        XCTAssertFalse(verticalScroller.isHidden)
        XCTAssertEqual(verticalScroller.alphaValue, 1)

        controller.reconcileScrollbarAttachmentAfterMetrics()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        XCTAssertFalse(verticalScroller.isHidden)
        XCTAssertEqual(verticalScroller.alphaValue, 1)
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
