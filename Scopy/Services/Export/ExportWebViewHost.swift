import AppKit
import Darwin
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers
import WebKit

final class ExportCoordinator: NSObject, WKNavigationDelegate {
    enum ExportEnv {
        static let disablePDFExport = "SCOPY_EXPORT_DISABLE_PDF"
        static let uiTestEnablePDFExport = "SCOPY_UITEST_ENABLE_PDF_EXPORT"
        static let requirePDFExport = "SCOPY_EXPORT_REQUIRE_PDF"
        static let dumpPDFPath = "SCOPY_EXPORT_PDF_DUMP_PATH"
    }

    let html: String
    let layoutWidthPixels: CGFloat
    let layoutWidthPoints: CGFloat
    let outputScale: CGFloat
    let targetWidthPixels: CGFloat
    let viewportWidthPoints: CGFloat
    let pngquantOptions: PngquantService.Options?
    var preservesArtworkColors = false
    let completion: (Result<MarkdownExportService.ExportOutcome, Error>) -> Void
    let targetScreen: NSScreen?
    let backingScaleFactor: CGFloat
    var webView: WKWebView?
    var hostWindow: NSWindow?
    var timeoutTask: Task<Void, Never>?
    var isCompleted = false
    var loadTask: Task<Void, Never>?
    var exportTask: Task<Void, Never>?
    var stage: MarkdownExportService.ExportStage = .loadHTML {
        didSet {
            MarkdownExportService.logger.info("Export stage \(oldValue.rawValue, privacy: .public) -> \(self.stage.rawValue, privacy: .public)")
            if let progress = stage.progress { reportProgress(progress) }
        }
    }
    let onProgress: @MainActor (MarkdownExportService.ExportProgress) -> Void
    private var lastProgress: MarkdownExportService.ExportProgress?
    var layoutPhases = ExportLayoutPhases()
    var layoutWaiter: ExportLayoutWaiter?

#if DEBUG
    /// Test seams: the xctest runner has no app resource directory, and ordering the host panel out once the
    /// document is ready reproduces a host that becomes occluded mid-export (animation frames stop).
    static var markdownPreviewResourceURLForTesting: URL?
    static var ordersOutHostWindowForTesting = false
#endif
    var didDumpTableMetrics = false
    let concurrencyID = UUID()

    // Keep a strong reference to self until export completes
    static var activeCoordinators: Set<ExportCoordinator> = []
    static let concurrencyGate = MarkdownExportConcurrencyGate(
        limit: 2,
        maximumPendingCount: 8
    )

    init(
        html: String,
        targetWidthPixels: CGFloat,
        resolutionScale: CGFloat,
        pngquantOptions: PngquantService.Options?,
        onProgress: @escaping @MainActor (MarkdownExportService.ExportProgress) -> Void,
        completion: @escaping (Result<MarkdownExportService.ExportOutcome, Error>) -> Void
    ) {
        self.html = html
        self.onProgress = onProgress
        self.completion = completion
        let screen = Self.activeScreen()
        self.targetScreen = screen
        self.backingScaleFactor = screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        self.layoutWidthPoints = Self.preferredLayoutWidthPoints(for: screen)
        self.layoutWidthPixels = max(1, self.layoutWidthPoints * max(1, self.backingScaleFactor))
        self.outputScale = Self.sanitizeOutputScale(resolutionScale)
        self.targetWidthPixels = max(1, targetWidthPixels * self.outputScale)
        self.viewportWidthPoints = max(1, self.layoutWidthPoints)
        self.pngquantOptions = pngquantOptions
        super.init()
    }

    static func preferredLayoutWidthPoints(for _: NSScreen?) -> CGFloat {
        CGFloat(MarkdownRenderLayoutConstants.chatGPTOutputSurfaceWidth)
    }

    static func sanitizeOutputScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return 1 }
        guard scale > 0 else { return 1 }
        return max(0.5, min(4, scale))
    }

    var snapshotWidthPoints: CGFloat {
        // On macOS, WKWebView snapshotWidth can increase the output canvas width without scaling the rendered
        // contents, which leaves a blank right margin when exporting at >1x. Keep snapshots at viewport width and
        // scale the resulting CGImage to `targetWidthPixels` in Swift for deterministic results.
        max(1, viewportWidthPoints)
    }

    var outputPixelScaleFactor: CGFloat {
        let viewportWidth = max(1, viewportWidthPoints)
        return max(1, targetWidthPixels / viewportWidth)
    }

    func start() {
        let submission = Self.concurrencyGate.submit(id: concurrencyID) {
            self.startAfterAcquiringConcurrencySlot()
        }
        if submission == .rejected {
            completeWithError(
                MarkdownExportService.ExportError.exportLimitExceeded(
                    reason: "Too many Markdown exports are already active or queued"
                )
            )
        }
    }

    func cancel() {
        completeWithError(CancellationError())
    }

    func startAfterAcquiringConcurrencySlot() {
        guard !isCompleted else {
            Self.concurrencyGate.finish(id: concurrencyID)
            return
        }
        // Retain self
        Self.activeCoordinators.insert(self)

        // Set timeout (long exports may require multiple tiles; keep a generous budget but still fail-fast).
        timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.completeWithError(MarkdownExportService.ExportError.renderingTimeout(stage: self.stage))
            }
        }

        loadTask = Task { @MainActor in
            await self.startWebViewAndLoadHTML()
        }
    }

    func startWebViewAndLoadHTML() async {
        guard !isCompleted else { return }

        await MarkdownWebKitEnvironment.prepareRules()
        // A cancel or timeout during the await must not build a WebView and window afterwards.
        guard !isCompleted, !Task.isCancelled else { return }

        // Create offscreen WebView with an explicit viewport size to make layout deterministic.
        let config = MarkdownWebKitEnvironment.makeConfiguration()
        config.userContentController.add(ExportLayoutMessageProxy(owner: self), name: ExportLayoutMessageProxy.name)
        let wv = WKWebView(
            frame: CGRect(
                x: 0,
                y: 0,
                width: viewportWidthPoints,
                height: MarkdownExportRenderConstants.exportViewportHeightPoints
            ),
            configuration: config
        )
        wv.navigationDelegate = self
        wv.setValue(false, forKey: "drawsBackground")
        wv.wantsLayer = true
        wv.layer?.contentsScale = backingScaleFactor
        self.webView = wv

        // Host the web view in an invisible on-screen (non-activating) window so WebKit renders reliably (and in Retina scale).
        let screenFrame = (targetScreen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let safeX = screenFrame.minX + 8
        let safeY = screenFrame.minY + 8
        let rect = CGRect(
            x: safeX,
            y: safeY,
            width: viewportWidthPoints,
            height: MarkdownExportRenderConstants.exportViewportHeightPoints
        )
        let window = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.contentView = wv
        window.orderFront(nil)
        self.hostWindow = window

        // Inject export styles into HTML
        let exportHTML = injectExportStyles(html)

        // Load HTML
        var baseURL = Bundle.main.resourceURL?.appendingPathComponent("MarkdownPreview", isDirectory: true)
#if DEBUG
        baseURL = Self.markdownPreviewResourceURLForTesting ?? baseURL
#endif
        wv.loadHTMLString(exportHTML, baseURL: baseURL)
    }

    func injectExportStyles(_ html: String) -> String {
        // Insert export-specific styles before </head>
        let exportStyles = """
        <style id="scopy-export-style">
            /* Layout variables come from the document itself; export adds only its own rules. */
            :root {
                color-scheme: light !important;
            }
            @page { margin: 0 !important; }
            html, body {
                background: #FFFFFF !important;
                color: #000000 !important;
                margin: 0 !important;
                padding: 0 !important;
                -webkit-text-size-adjust: 100% !important;
                -webkit-print-color-adjust: exact !important;
                print-color-adjust: exact !important;
                overflow-x: visible !important;
            }

            #content {
                background: #FFFFFF !important;
                display: block;
                width: var(--scopy-chatgpt-render-width) !important;
                max-width: none !important;
                opacity: 1 !important;
                transition: none !important;
            }

            /* During export we may scroll programmatically for tiled snapshots; always keep inner scrollbars hidden. */
            html.scopy-scrollbars-visible pre::-webkit-scrollbar,
            html.scopy-scrollbars-visible table::-webkit-scrollbar,
            html.scopy-scrollbars-visible .scopy-math-inline-host::-webkit-scrollbar,
            html.scopy-scrollbars-visible .katex-display::-webkit-scrollbar,
            html.scopy-scrollbars-visible .footnotes::-webkit-scrollbar,
            html.scopy-scrollbars-visible details::-webkit-scrollbar {
                width: 0px !important;
                height: 0px !important;
            }
        </style>
        """

        if let headEndRange = html.range(of: "</head>", options: .caseInsensitive) {
            var modifiedHTML = html
            modifiedHTML.insert(contentsOf: exportStyles, at: headEndRange.lowerBound)
            return modifiedHTML
        }

        // Fallback: prepend styles
        return exportStyles + html
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.onNavigationFinished()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.completeWithError(MarkdownExportService.ExportError.stageFailed(stage: .loadHTML, underlying: error))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.completeWithError(MarkdownExportService.ExportError.stageFailed(stage: .loadHTML, underlying: error))
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.completeWithError(MarkdownExportService.ExportError.stageFailed(stage: self.stage, underlying: nil))
        }
    }

    func onNavigationFinished() {
        guard webView != nil, !isCompleted else { return }

        exportTask?.cancel()
        exportTask = Task { @MainActor [weak self] in
            guard let self, let webView = self.webView, !self.isCompleted else { return }

            do {
                let outcome = try await self.exportPNG(webView: webView)
                self.completeWithSuccess(outcome)
            } catch {
                self.completeWithError(error)
            }
        }
    }

    func evaluateJavaScript<T: Sendable>(
        webView: WKWebView,
        javaScriptString: String,
        transform: @escaping (Any?) -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(javaScriptString) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: transform(value))
            }
        }
    }

    func evaluateJavaScriptBool(webView: WKWebView, javaScriptString: String) async throws -> Bool {
        try await evaluateJavaScript(webView: webView, javaScriptString: javaScriptString) { value in
            if let boolValue = value as? Bool { return boolValue }
            if let num = value as? NSNumber { return num.boolValue }
            if let str = value as? String { return str == "true" || str == "1" }
            return false
        }
    }

    func evaluateJavaScriptString(webView: WKWebView, javaScriptString: String) async throws -> String {
        try await evaluateJavaScript(webView: webView, javaScriptString: javaScriptString) { value in
            if let str = value as? String { return str }
            if let num = value as? NSNumber { return num.stringValue }
            if value == nil { return "" }
            return String(describing: value)
        }
    }

    static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    }

    // MARK: - Completion

    func completeWithSuccess(_ outcome: MarkdownExportService.ExportOutcome) {
        guard !isCompleted else { return }
        isCompleted = true
        cleanup()
        completion(.success(outcome))
    }

    func completeWithError(_ error: Error) {
        guard !isCompleted else { return }
        isCompleted = true
        cleanup()
        completion(.failure(error))
    }

    func cleanup() {
        loadTask?.cancel()
        loadTask = nil
        exportTask?.cancel()
        exportTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        layoutWaiter?.resume(nil)
        layoutWaiter = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: ExportLayoutMessageProxy.name)
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        hostWindow?.orderOut(nil)
        hostWindow = nil
        Self.activeCoordinators.remove(self)
        Self.concurrencyGate.finish(id: concurrencyID)
    }

    func reportProgress(_ progress: MarkdownExportService.ExportProgress) {
        guard progress != lastProgress, !isCompleted else { return }
        lastProgress = progress
        onProgress(progress)
    }
}

/// Receives the page watcher's `scopyExportLayout` pushes without the user content controller retaining the export.
@MainActor
private final class ExportLayoutMessageProxy: NSObject, WKScriptMessageHandler {
    static let name = "scopyExportLayout"
    private weak var owner: ExportCoordinator?

    init(owner: ExportCoordinator) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let layoutMessage = ExportLayoutMessage(body: message.body) else { return }
        owner?.receiveLayoutMessage(layoutMessage)
    }
}
