import XCTest
import WebKit
import ScopyKit

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

    func testSourceIconsLoadAndFailedFrozenIconKeepsCompactFallback() throws {
        let controller = MarkdownPreviewWebViewController()
        let owner = UUID()
        controller.beginOwnership(owner)
        defer { controller.endOwnership(owner) }
        controller.webView.frame = CGRect(x: 0, y: 0, width: 816, height: 900)
        let document = try LiveMarkdownDocument(webView: controller.webView)
        defer { document.close() }
        let source = """
        正文 [大象官方说明](https://support.platform.elebank.com/personal/zh-hk) 与 [汇丰 FPS 常见问题](https://www.hsbc.com.hk/campaigns/fps/faq/)。

        ```scopy-rich
        {"version":2,"type":"news","items":[{"title":"损坏图标仍保留正文","url":"https://example.org/","favicon":{"src":"data:image/png;base64,AAAA"}}]}
        ```
        """
        let mentions = "[PDF](/tmp/report.pdf) [Word](/tmp/report.docx) [Word again](/tmp/report.docx) [图片](/tmp/image.png) [视频](/tmp/movie.mp4) [音频](/tmp/audio.wav) [Google Sheets](app://google-sheets) [Google Sheets again](app://google-sheets)"
        try document.load(MarkdownHTMLRenderer.render(markdown: source + "\n\n" + mentions), timeout: 20)
        guard document.isRenderReady else {
            XCTFail("Real WebKit document did not reach terminal success: \(document.evaluate("JSON.stringify(window.ScopyDocument.state)") ?? "no response")")
            return
        }
        let checks = """
        (() => {
          const root = document.getElementById('content');
          const images = [...root.querySelectorAll('img.scopy-link-origin-icon')];
          const first = images[0];
          const label = first.nextElementSibling;
          const range = document.createRange();
          range.selectNodeContents(label);
          const iconBox = first.getBoundingClientRect(), labelBox = range.getClientRects()[0];
          const loaded = images.length === 2 && images.every(i => i.complete && i.naturalWidth > 0);
          const aligned = iconBox.width > 0 && iconBox.width <= 32 && iconBox.left < labelBox.left && Math.abs(iconBox.top - labelBox.top) < 8;
          const fallback = root.querySelector('svg.scopy-rich-origin-icon[data-scopy-image-state="error"]');
          const mentions = [...root.querySelectorAll('.scopy-mention-icon')];
          const mentionGeometry = mentions.length === 8 && mentions.every(box => {
            const svg = box.querySelector('svg'), b = box.getBoundingClientRect(), g = svg.getBoundingClientRect();
            return Math.abs(g.width - 16) < 0.1 && Math.abs(g.height - 16) < 0.1 && Math.abs(g.top + g.height / 2 - b.top - b.height / 2) < 0.5;
          });
          const ids = [...root.querySelectorAll('[id]')].map(n => n.id);
          const uniquePaintIDs = new Set(ids).size === ids.length;
          const gradients = root.querySelectorAll('.scopy-mention-icon linearGradient').length > 0;
          const masks = root.querySelectorAll('.scopy-mention-icon mask').length > 0;
          const originalMediaColor = getComputedStyle(root.querySelector('.scopy-codex-icon--video path')).fill === 'rgb(146, 79, 247)';
          window.ScopyDocument.export.prepare();
          const afterIcons = root.querySelectorAll('img.scopy-link-origin-icon');
          return JSON.stringify({loaded, aligned, mentionGeometry, uniquePaintIDs, gradients, masks, originalMediaColor, fallback: !!fallback, noErrorText: !root.textContent.includes('图片无法显示'), exportPreservesIcons: afterIcons.length === images.length});
        })()
        """
        let json = try XCTUnwrap(document.evaluate(checks) as? String).data(using: .utf8)!
        let outcomes = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Bool])
        for (name, passed) in outcomes { XCTAssertTrue(passed, name) }
        XCTAssertEqual(outcomes.count, 10)
    }

    func testPreviewResizingPreservesCanonicalLineBreaksAndFitsDisplayWithoutReloading() throws {
        let controller = MarkdownPreviewWebViewController()
        let owner = UUID()
        controller.beginOwnership(owner)
        defer { controller.endOwnership(owner) }
        controller.webView.frame = CGRect(x: 0, y: 0, width: 360, height: 600)
        let document = try LiveMarkdownDocument(webView: controller.webView)
        defer { document.close() }
        let window = document.window
        let source = "# Stable preview\n\n" + String(repeating: "窗口调整大小时保留原有排版与缩放规则，表格和代码只在自身范围滚动。", count: 15)
            + "\n\n```text\n" + String(repeating: "long_code_", count: 150) + "\n```"
        // Cover both overlay and space-reserving scrollbars independently of the host's preference.
        for (scale, scrollbarWidth) in [(80, 0), (115, 0), (200, 0), (80, 15), (115, 15), (200, 15)] {
            let context = MarkdownRenderContextResolver.defaultContext(for: source, layoutScale: MarkdownChatGPTLayoutScalePercent(settingsValue: scale))
            let html = MarkdownHTMLRenderer.render(markdown: source, context: context)
                .replacingOccurrences(of: "</head>", with: "<style>html { overflow-y: scroll; } ::-webkit-scrollbar { width: \(scrollbarWidth)px; height: \(scrollbarWidth)px; }</style></head>")
            try document.load(html, name: "layout-\(scale)-\(scrollbarWidth).html")
            XCTAssertTrue(document.isRenderReady, "Live document at \(scale)% must render")
            let initialParagraphHeight = try XCTUnwrap(document.evaluate("document.querySelector('#content p').offsetHeight") as? Double)
            _ = document.evaluate("window.__scopyLayoutRegressionIdentity = document.getElementById('content'); true")
            for width in [360, 640, 816, 900, 1500, 360] {
                window.setContentSize(CGSize(width: width, height: 600))
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                let checks = """
                (() => {
                  const root = document.documentElement, content = document.getElementById('content');
                  window.ScopyDocument.probeLayoutHeight();
                  const paragraph = content.querySelector('p').getBoundingClientRect();
                  const shell = document.getElementById('content-scale-shell').getBoundingClientRect();
                  const contentBox = content.getBoundingClientRect();
                  const viewport = innerWidth;
                  const code = content.querySelector('.scopy-code-card-scroll') || content.querySelector('pre');
                  return {
                    geometry: JSON.stringify({ viewport, clientWidth: root.clientWidth, paragraph: paragraph.toJSON(), shell: shell.toJSON(), content: contentBox.toJSON(), scrollX, shellMargin: getComputedStyle(document.getElementById('content-scale-shell')).marginLeft }),
                    shellCentered: Math.abs(shell.left - Math.max(0, (root.clientWidth - shell.width) / 2)) < 2,
                    paragraphCentered: Math.abs(paragraph.left + paragraph.width / 2 - shell.left - shell.width / 2) < 2,
                    scrollbarWidth: Math.abs(viewport - root.clientWidth - \(scrollbarWidth)) < 1,
                    fits: Math.abs(shell.width - Math.min(816, viewport)) < 2 && root.scrollWidth <= viewport + 1,
                    scale: Math.abs(parseFloat(getComputedStyle(root).getPropertyValue('--scopy-chatgpt-preview-scale')) - \(Double(scale) / 100) * Math.min(1, viewport / 816)) < 0.001,
                    layoutWidth: Math.abs(content.offsetWidth - 816 / \(Double(scale) / 100)) < 1,
                    lineBreaks: content.querySelector('p').offsetHeight === \(initialParagraphHeight),
                    sameDocument: content === window.__scopyLayoutRegressionIdentity,
                    localOverflow: code.scrollWidth > code.clientWidth
                  };
                })()
                """
                let values = try XCTUnwrap(document.evaluate(checks) as? [String: Any])
                let geometry = try XCTUnwrap(values["geometry"] as? String)
                for (name, value) in values where name != "geometry" {
                    let passed = try XCTUnwrap(value as? Bool)
                    XCTAssertTrue(passed, "\(name), width \(width), scale \(scale), scrollbar \(scrollbarWidth): \(geometry)")
                }
            }
        }
    }

    func testBrokenImageReachesTerminalFallbackWithoutFailingTheDocument() throws {
        let document = try LiveMarkdownDocument()
        defer { document.close() }
        XCTAssertTrue(try document.load(MarkdownHTMLRenderer.render(markdown: "正文\n\n![示意图](missing-diagram.png)")))

        XCTAssertTrue(document.isRenderReady)
        XCTAssertEqual(document.evaluate("window.ScopyDocument.state.imagesReady") as? Bool, true)
        XCTAssertEqual(
            document.evaluate("document.querySelector('.scopy-image-terminal-fallback[data-scopy-image-state=\"error\"]').textContent") as? String,
            "示意图 · 图片无法显示"
        )
    }

    func testMissingKaTeXStylesheetIsATerminalFailure() throws {
        let document = try LiveMarkdownDocument()
        defer { document.close() }
        try FileManager.default.removeItem(at: document.assetRoot.appendingPathComponent("katex.min.css"))
        XCTAssertTrue(try document.load(MarkdownHTMLRenderer.render(markdown: "$$E=mc^2$$")))

        XCTAssertFalse(document.isRenderReady)
        XCTAssertEqual(document.evaluate("window.ScopyDocument.state.renderFailed") as? Bool, true)
        // A missing file-URL stylesheet never fires `error` in WebKit; the stylesheet deadline ends it instead.
        XCTAssertEqual(document.evaluate("window.ScopyDocument.state.unifiedErrorReason") as? String, "stylesheet timeout")
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
