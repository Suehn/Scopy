import AppKit
import Darwin
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers
import WebKit

/// Renders one Markdown document in an offscreen WebView and captures it as PNG: layout preparation, the PDF,
/// single-snapshot and tiled capture strategies, and completion. All of its state is private to this file.
@MainActor
final class ExportCoordinator: NSObject, WKNavigationDelegate {
    private enum ExportEnv {
        static let disablePDFExport = "SCOPY_EXPORT_DISABLE_PDF"
    }

    private let html: String
    private let layoutWidthPixels: CGFloat
    private let layoutWidthPoints: CGFloat
    private let outputScale: CGFloat
    private let targetWidthPixels: CGFloat
    private let viewportWidthPoints: CGFloat
    private let pngquantOptions: PngquantService.Options?
    private var preservesArtworkColors = false
    private let completion: (Result<MarkdownExportService.ExportOutcome, Error>) -> Void
    private let targetScreen: NSScreen?
    private let backingScaleFactor: CGFloat
    var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var timeoutTask: Task<Void, Never>?
    private var isCompleted = false
    private var loadTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var stage: MarkdownExportService.ExportStage = .loadHTML {
        didSet {
            MarkdownExportService.logger.info("Export stage \(oldValue.rawValue, privacy: .public) -> \(self.stage.rawValue, privacy: .public)")
            if let progress = stage.progress { reportProgress(progress) }
        }
    }
    private let onProgress: @MainActor (MarkdownExportService.ExportProgress) -> Void
    private var lastProgress: MarkdownExportService.ExportProgress?
    private var layoutPhases = ExportLayoutPhases()
    private var layoutWaiter: ExportLayoutWaiter?

#if DEBUG
    /// Test seams: the xctest runner has no app resource directory, and ordering the host panel out once the
    /// document is ready reproduces a host that becomes occluded mid-export (animation frames stop).
    static var markdownPreviewResourceURLForTesting: URL?
    static var ordersOutHostWindowForTesting = false
#endif
    private var didDumpTableMetrics = false
    private let concurrencyID = UUID()

    // Keep a strong reference to self until export completes
    private static var activeCoordinators: Set<ExportCoordinator> = []
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

    private static func preferredLayoutWidthPoints(for _: NSScreen?) -> CGFloat {
        CGFloat(MarkdownRenderLayoutConstants.chatGPTOutputSurfaceWidth)
    }

    private static func sanitizeOutputScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return 1 }
        guard scale > 0 else { return 1 }
        return max(0.5, min(4, scale))
    }

    private var snapshotWidthPoints: CGFloat {
        // On macOS, WKWebView snapshotWidth can increase the output canvas width without scaling the rendered
        // contents, which leaves a blank right margin when exporting at >1x. Keep snapshots at viewport width and
        // scale the resulting CGImage to `targetWidthPixels` in Swift for deterministic results.
        max(1, viewportWidthPoints)
    }

    private var outputPixelScaleFactor: CGFloat {
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

    private func startAfterAcquiringConcurrencySlot() {
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

    private func startWebViewAndLoadHTML() async {
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

        // Load HTML
        var baseURL = Bundle.main.resourceURL?.appendingPathComponent("MarkdownPreview", isDirectory: true)
#if DEBUG
        baseURL = Self.markdownPreviewResourceURLForTesting ?? baseURL
#endif
        wv.loadHTMLString(html, baseURL: baseURL)
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

    private func onNavigationFinished() {
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

    private func evaluateJavaScript<T: Sendable>(
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

    private func evaluateJavaScriptBool(webView: WKWebView, javaScriptString: String) async throws -> Bool {
        try await evaluateJavaScript(webView: webView, javaScriptString: javaScriptString) { value in
            if let boolValue = value as? Bool { return boolValue }
            if let num = value as? NSNumber { return num.boolValue }
            if let str = value as? String { return str == "true" || str == "1" }
            return false
        }
    }

    private func evaluateJavaScriptString(webView: WKWebView, javaScriptString: String) async throws -> String {
        try await evaluateJavaScript(webView: webView, javaScriptString: javaScriptString) { value in
            if let str = value as? String { return str }
            if let num = value as? NSNumber { return num.stringValue }
            if value == nil { return "" }
            return String(describing: value)
        }
    }

    private static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    }

    // MARK: - Completion

    private func completeWithSuccess(_ outcome: MarkdownExportService.ExportOutcome) {
        guard !isCompleted else { return }
        isCompleted = true
        cleanup()
        completion(.success(outcome))
    }

    private func completeWithError(_ error: Error) {
        guard !isCompleted else { return }
        isCompleted = true
        cleanup()
        completion(.failure(error))
    }

    private func cleanup() {
        let runningWork = [loadTask, exportTask].compactMap { $0 }
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
        // The slot is released only once cancelled capture and encoding work has actually exited.
        let concurrencyID = concurrencyID
        Task { @MainActor in
            for work in runningWork { await work.value }
            Self.concurrencyGate.finish(id: concurrencyID)
        }
    }

    private func reportProgress(_ progress: MarkdownExportService.ExportProgress) {
        guard progress != lastProgress, !isCompleted else { return }
        lastProgress = progress
        onProgress(progress)
    }

    // MARK: - Capture strategies

    private func exportPNG(webView: WKWebView) async throws -> MarkdownExportService.ExportOutcome {
        try advance(to: .prepareLayout)
        let initialScrollHeightPoints = try await prepareForExportScrollHeightPoints(webView: webView)
#if DEBUG
        if Self.ordersOutHostWindowForTesting { hostWindow?.orderOut(nil) }
#endif
        if initialScrollHeightPoints <= 0 {
            let details = (try? await layoutDebugInfo(webView: webView)) ?? "No debug info"
            let underlying = NSError(
                domain: "Scopy.MarkdownExport",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid scroll height (0). \(details)"]
            )
            throw MarkdownExportService.ExportError.stageFailed(stage: .prepareLayout, underlying: underlying)
        }
        // The HTML shell is rendered by JavaScript; inspect the ready DOM instead
        // of searching the unrendered input for classes that do not exist yet.
        preservesArtworkColors = try await evaluateJavaScriptBool(
            webView: webView,
            javaScriptString: "window.ScopyDocument.export.preservesArtworkColors()"
        )
        var scrollHeightPoints = initialScrollHeightPoints

        try advance(to: .applyScale)
        // Target output width is fixed (pixels). We avoid downscaling unless we hit safe image-area constraints.
        var appliedScale: CGFloat = 1
        let widthPixels = max(1, targetWidthPixels)
        // Keep a small safety margin: rounding and PDF page box quantization can push the final pixel height slightly
        // over the computed budget, which would otherwise cause a hard failure at rasterization time.
        let maxHeightPixelsByAreaRaw: CGFloat = MarkdownExportRenderConstants.maxTotalPixels / widthPixels
        let maxHeightPixelsByArea: CGFloat = max(1, maxHeightPixelsByAreaRaw - 12)

        // Apply global scale iteratively. Under WebKit, applying scale can reflow content (e.g. line wrapping),
        // so a single pass based on the initial height may still exceed the safe area budget.
        for _ in 0..<6 {
            let heightPixels = scrollHeightPoints * outputPixelScaleFactor
            let scaleFactor: CGFloat = min(1, maxHeightPixelsByArea / max(1, heightPixels))
            if scaleFactor >= 0.999 { break }

            let candidateScale = appliedScale * scaleFactor
            guard candidateScale >= MarkdownExportRenderConstants.minAllowedGlobalScale else {
                throw MarkdownExportService.ExportError.exportLimitExceeded(
                    reason: "Content too long for PNG export (height \(Int(ceil(scrollHeightPoints)))pt), required scale \(String(format: "%.3f", candidateScale)) < \(MarkdownExportRenderConstants.minAllowedGlobalScale)"
                )
            }

            try await applyGlobalScale(webView: webView, scale: candidateScale)
            appliedScale = candidateScale
            scrollHeightPoints = try await prepareForExportScrollHeightPoints(webView: webView)
        }

        await dumpTableMetricsIfRequested(webView: webView)

        try await scrollToTop(webView: webView)
        scrollHeightPoints = try await reconcileExportHeightPoints(
            webView: webView,
            estimatedHeightPoints: scrollHeightPoints
        )

        let processInfo = ProcessInfo.processInfo
        let projectedOutputHeightPixels = max(1, scrollHeightPoints * outputPixelScaleFactor)
        let projectedOutputTotalPixels = max(1, targetWidthPixels * projectedOutputHeightPixels)
        let shouldBypassPDFFromRasterBudget = projectedOutputTotalPixels > MarkdownExportRenderConstants.maxInMemoryBitmapPixels + 0.5
        let shouldBypassPDFFromHeight = MarkdownExportRenderConstants.shouldBypassPDFForHeight(scrollHeightPoints)
        let shouldBypassPDFForVeryTallContent = shouldBypassPDFFromHeight || shouldBypassPDFFromRasterBudget
        let requiresPDFExport = outputScale > 1.001 && !shouldBypassPDFForVeryTallContent
        let shouldAttemptPDF: Bool = {
            if processInfo.environment[ExportEnv.disablePDFExport] == "1" { return false }
            if shouldBypassPDFForVeryTallContent { return false }
            if requiresPDFExport { return true }
            // UI tests capture 1x exports through the snapshot path.
            return !processInfo.arguments.contains("--uitesting")
        }()
        if shouldBypassPDFForVeryTallContent {
            let pdfBypassReason = shouldBypassPDFFromHeight ? "height" : "rasterBudget"
            MarkdownExportService.logger.info(
                "Skipping PDF export and falling back to snapshot export. reason=\(pdfBypassReason, privacy: .public) heightPt=\(scrollHeightPoints, privacy: .public) projectedPixels=\(projectedOutputTotalPixels, privacy: .public)"
            )
        }
        if requiresPDFExport, !shouldAttemptPDF {
            let underlying = NSError(
                domain: "Scopy.MarkdownExport",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "PDF export required but disabled by environment"]
            )
            throw MarkdownExportService.ExportError.stageFailed(stage: .createPDF, underlying: underlying)
        }
        if shouldAttemptPDF {
            do {
                let outcome = try await exportPDFRasterizedPNG(webView: webView, heightPoints: scrollHeightPoints)
                return outcome
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if requiresPDFExport {
                    throw error
                }
                MarkdownExportService.logger.error("PDF export failed; falling back to snapshot export. scale=\(appliedScale, privacy: .public) heightPt=\(scrollHeightPoints, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }

        try advance(to: .snapshotOnce)
        if scrollHeightPoints <= MarkdownExportRenderConstants.maxSingleSnapshotRectHeightPoints {
            do {
                let outcome = try await exportSingleSnapshotPNG(webView: webView, heightPoints: scrollHeightPoints)
                return outcome
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Fall back to tiled snapshots for robustness (long content or intermittent WebKit snapshot failures).
                MarkdownExportService.logger.error("Single snapshot failed; falling back to tiled export. scale=\(appliedScale, privacy: .public) heightPt=\(scrollHeightPoints, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }

        try advance(to: .snapshotTiles)
        let outcome = try await exportTiledPNG(webView: webView, totalHeightPoints: scrollHeightPoints)
        return outcome
    }

    private func exportPDFRasterizedPNG(webView: WKWebView, heightPoints: CGFloat) async throws -> MarkdownExportService.ExportOutcome {
        let targetWidthPixels = max(1, Int(round(self.targetWidthPixels)))
        let pngquantOptions = preservesArtworkColors ? nil : self.pngquantOptions
        // WebKit's PDF output can embed page contents at a reduced scale (≈1 / devicePixelRatio),
        // which becomes more pronounced as we increase export resolution. Compensate by the full output pixel scale.
        let contentScaleCompensation = max(1, outputPixelScaleFactor)

        var currentHeightPoints = max(1, heightPoints)
        var lastLimitReason: String?

        // SCOPY_EXPORT_PDF_GLOBAL_SCALE_MISMATCH:
        // Pre-PDF global-scale budgeting is based on the WKWebView viewport width, but forced PDF export ultimately
        // rasterizes against the actual PDF page boxes. Those boxes can be narrower than the viewport, which inflates
        // the final raster height and can reintroduce long-content clipping only on the PDF path. Before rasterizing,
        // preflight the generated PDF with its real page boxes and, if needed, apply one more export-scale reduction.
        for _ in 0..<4 {
            try advance(to: .createPDF)
            let rectPoints = CGRect(
                x: 0,
                y: 0,
                width: viewportWidthPoints,
                height: max(1, ceil(currentHeightPoints))
            )

            let pdfData = try await createPDF(webView: webView, rectPoints: rectPoints)
            let metrics = try ExportRaster.pdfRasterMetrics(pdfData: pdfData, targetWidthPixels: targetWidthPixels)
            if metrics.totalPixels > MarkdownExportRenderConstants.maxTotalPixels + 0.5 {
                lastLimitReason = "PDF rasterization too large (w=\(targetWidthPixels)px, h=\(metrics.totalHeightPixels)px, total=\(Int(metrics.totalPixels))px)"
                let currentScale = await currentExportScale(webView: webView)
                let budgetRatio = max(0.01, min(0.98, (MarkdownExportRenderConstants.maxTotalPixels / metrics.totalPixels) * 0.98))
                let nextScale = currentScale * budgetRatio
                guard nextScale >= MarkdownExportRenderConstants.minAllowedGlobalScale else {
                    throw MarkdownExportService.ExportError.exportLimitExceeded(reason: lastLimitReason ?? "PDF rasterization remained above budget")
                }

                try await applyGlobalScale(webView: webView, scale: nextScale)
                currentHeightPoints = try await prepareForExportScrollHeightPoints(webView: webView)
                currentHeightPoints = try await reconcileExportHeightPoints(
                    webView: webView,
                    estimatedHeightPoints: currentHeightPoints
                )
                continue
            }

            try advance(to: .rasterizePDF)
            let expectedPageWidthPoints = rectPoints.width
            return try await runDetached {
                let canvas = try ExportRaster.rasterizePDFDataToCanvas(
                    pdfData: pdfData,
                    targetWidthPixels: targetWidthPixels,
                    expectedPageWidthPoints: expectedPageWidthPoints,
                    contentScaleCompensation: contentScaleCompensation
                )
                try Task.checkCancellation()
                return try ExportRaster.encodeExportCanvas(canvas, pngquantOptions: pngquantOptions)
            }
        }

        throw MarkdownExportService.ExportError.exportLimitExceeded(
            reason: lastLimitReason ?? "PDF rasterization remained above budget after export-scale retries"
        )
    }

    private func exportSingleSnapshotPNG(webView: WKWebView, heightPoints: CGFloat) async throws -> MarkdownExportService.ExportOutcome {
        try await resizeWebViewForSnapshot(webView: webView, heightPoints: heightPoints)
        let effectiveHeightPoints = try await reconcileExportHeightPoints(
            webView: webView,
            estimatedHeightPoints: heightPoints
        )
        if effectiveHeightPoints > MarkdownExportRenderConstants.maxSingleSnapshotRectHeightPoints + 1 {
            let underlying = NSError(
                domain: "Scopy.MarkdownExport",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Content expanded after snapshot resize (height=\(Int(ceil(effectiveHeightPoints)))pt); switching to tiled export"]
            )
            throw MarkdownExportService.ExportError.stageFailed(stage: .snapshotOnce, underlying: underlying)
        }

        let rectPoints = CGRect(
            x: 0,
            y: 0,
            width: viewportWidthPoints,
            height: max(1, ceil(effectiveHeightPoints))
        )

        let config = WKSnapshotConfiguration()
        config.rect = rectPoints
        config.snapshotWidth = NSNumber(value: Double(snapshotWidthPoints))
        config.afterScreenUpdates = true

        let image = try await takeSnapshot(webView: webView, config: config)

        try advance(to: .imageConversion)
        let cg = try cgImage(from: image)

        try advance(to: .pngEncoding)
        let targetWidth = max(1, Int(round(targetWidthPixels)))
        let pngquantOptions = preservesArtworkColors ? nil : self.pngquantOptions
        return try await runDetached {
            let canvas = try ExportRaster.canvasFromSnapshot(cg, targetWidthPixels: targetWidth)
            try Task.checkCancellation()
            return try ExportRaster.encodeExportCanvas(canvas, pngquantOptions: pngquantOptions)
        }
    }

    private func exportTiledPNG(webView: WKWebView, totalHeightPoints: CGFloat) async throws -> MarkdownExportService.ExportOutcome {
        let targetWidthPixelsInt = max(1, Int(round(targetWidthPixels)))

        try advance(to: .snapshotTiles)
        let tileViewportHeightPoints = MarkdownExportRenderConstants.exportViewportHeightPoints
        try await resizeWebViewForSnapshot(webView: webView, heightPoints: tileViewportHeightPoints)
        try await scrollToTop(webView: webView)

        let effectiveTotalHeightPoints = try await reconcileExportHeightPoints(
            webView: webView,
            estimatedHeightPoints: totalHeightPoints
        )
        let totalHeightPointsInt = max(1, Int(ceil(effectiveTotalHeightPoints)))
        let totalHeightPixelsInt = max(1, Int(ceil(CGFloat(totalHeightPointsInt) * outputPixelScaleFactor)))

        // Safety: enforce area limit. (Global zoom already tried to satisfy this, but keep a hard guard.)
        let totalPixels = CGFloat(targetWidthPixelsInt) * CGFloat(totalHeightPixelsInt)
        if totalPixels > MarkdownExportRenderConstants.maxTotalPixels + 0.5 {
            let details = (try? await layoutDebugInfo(webView: webView)) ?? "No debug info"
            throw MarkdownExportService.ExportError.exportLimitExceeded(
                reason: "Image too large after layout (w=\(targetWidthPixelsInt)px, h=\(totalHeightPixelsInt)px, total=\(Int(totalPixels))px). \(details)"
            )
        }

        let canvas = try ExportBitmapCanvas.make(
            width: targetWidthPixelsInt,
            height: totalHeightPixelsInt,
            stage: .stitchTiles
        )
        let ctx = canvas.context

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(targetWidthPixelsInt), height: CGFloat(totalHeightPixelsInt)))

        let overlapPoints = max(0, MarkdownExportRenderConstants.snapshotTileOverlapPoints)
        var scrollYPoints: CGFloat = 0
        let outputScaleFactor = outputPixelScaleFactor
        let tileStepPoints = max(1, tileViewportHeightPoints - overlapPoints)
        let tileCount = 1 + Int(max(0, ceil((CGFloat(totalHeightPointsInt) - tileViewportHeightPoints) / tileStepPoints)))
        var tileNumber = 0
        while scrollYPoints < CGFloat(totalHeightPointsInt) {
            try Task.checkCancellation()
            tileNumber += 1
            reportProgress(.capturing(tile: min(tileNumber, tileCount), of: tileCount))
            let remaining = CGFloat(totalHeightPointsInt) - scrollYPoints
            let captureHeightPoints = max(1, min(tileViewportHeightPoints, remaining))

            let actualScrollYPoints = try await scrollTo(webView: webView, yPoints: scrollYPoints)
            let captureOffsetPoints = max(
                0,
                min(
                    tileViewportHeightPoints - captureHeightPoints,
                    scrollYPoints - actualScrollYPoints
                )
            )
            let capturedContentStartPoints = max(0, actualScrollYPoints + captureOffsetPoints)

            let rectPoints = CGRect(
                x: 0,
                y: captureOffsetPoints,
                width: viewportWidthPoints,
                height: captureHeightPoints
            )
            let config = WKSnapshotConfiguration()
            config.rect = rectPoints
            config.snapshotWidth = NSNumber(value: Double(snapshotWidthPoints))
            config.afterScreenUpdates = true

            let image = try await takeSnapshot(webView: webView, config: config)
            let tileCG = try cgImage(from: image)

            let normalizedTile = ExportRaster.scaleCGImageIfNeeded(image: tileCG, targetWidthPixels: targetWidthPixelsInt)

            // Place each tile using the exact content interval it represents in the final image.
            // This avoids cumulative rounding drift between tiles, which can otherwise show up as
            // 1-2px seams or missing rows in very tall exports.
            let contentStartPixels = max(0, Int(floor(capturedContentStartPoints * outputScaleFactor)))
            let contentEndPixels = min(
                totalHeightPixelsInt,
                max(contentStartPixels + 1, Int(ceil((capturedContentStartPoints + captureHeightPoints) * outputScaleFactor)))
            )
            let destinationHeightPixels = max(1, contentEndPixels - contentStartPixels)
            let drawY = max(0, totalHeightPixelsInt - contentEndPixels)

            try advance(to: .stitchTiles)
            ctx.draw(
                normalizedTile,
                in: CGRect(
                    x: 0,
                    y: CGFloat(drawY),
                    width: CGFloat(targetWidthPixelsInt),
                    height: CGFloat(destinationHeightPixels)
                )
            )

            if remaining <= tileViewportHeightPoints { break }
            scrollYPoints += tileStepPoints
        }

        try advance(to: .pngEncoding)
        let pngquantOptions = preservesArtworkColors ? nil : self.pngquantOptions
        return try await runDetached {
            try ExportRaster.encodeExportCanvas(canvas, pngquantOptions: pngquantOptions)
        }
    }

    private func scrollTo(webView: WKWebView, yPoints: CGFloat) async throws -> CGFloat {
        let target = Double(max(0, yPoints))
        var appKitOffsetY: CGFloat?
        if let scrollView = resolvedScrollView(for: webView),
           let documentView = scrollView.documentView
        {
            let clipView = scrollView.contentView
            let documentHeight = max(documentView.bounds.height, documentView.frame.height)
            let viewportHeight = max(clipView.bounds.height, clipView.frame.height)
            let maxOffsetY = max(0, documentHeight - viewportHeight)
            let boundedY = CGFloat(min(target, Double(maxOffsetY)))
            clipView.scroll(to: NSPoint(x: 0, y: boundedY))
            scrollView.reflectScrolledClipView(clipView)
            scrollView.layoutSubtreeIfNeeded()
            documentView.layoutSubtreeIfNeeded()
            webView.layoutSubtreeIfNeeded()
            webView.displayIfNeeded()
            appKitOffsetY = max(0, clipView.bounds.origin.y)
        }
        // Keep the page's own scroll position in step with the clip view (or scroll it when there is none).
        let scrollJS = "window.ScopyDocument.export.scrollTo(\(target))"
        if appKitOffsetY == nil {
            _ = try await evaluateJavaScriptBool(webView: webView, javaScriptString: scrollJS)
        } else {
            _ = try? await evaluateJavaScriptBool(webView: webView, javaScriptString: scrollJS)
        }
        // Let WebKit lay out and paint the new scroll position before it is measured or captured.
        await waitForAnimationFrames(webView: webView, timeout: 0.5)

        if let appKitOffsetY {
            return appKitOffsetY
        }

        let actualJS = "window.ScopyDocument.export.scrollOffset()"
        let actual = try await evaluateJavaScriptString(webView: webView, javaScriptString: actualJS)
        return max(0, CGFloat(Double(actual) ?? 0))
    }

    private func resolvedScrollView(for webView: WKWebView) -> NSScrollView? {
        if let enclosing = webView.enclosingScrollView {
            return enclosing
        }
        return findFirstScrollView(in: webView)
    }

    private func findFirstScrollView(in view: NSView) -> NSScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? NSScrollView {
                return scrollView
            }
            if let found = findFirstScrollView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func cgImage(from image: NSImage) throws -> CGImage {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            throw MarkdownExportService.ExportError.stageFailed(stage: .imageConversion, underlying: nil)
        }
        return cg
    }

    private func scrollToTop(webView: WKWebView) async throws {
        do {
            _ = try await scrollTo(webView: webView, yPoints: 0)
        } catch {
            // Best-effort: scrolling shouldn't be a hard failure for export.
        }
    }

    private func resizeWebViewForSnapshot(webView: WKWebView, heightPoints: CGFloat) async throws {
        let targetHeight = max(MarkdownExportRenderConstants.minSnapshotHeightPoints, ceil(heightPoints))
        guard targetHeight.isFinite, targetHeight > 0 else { return }

        webView.setFrameSize(NSSize(width: viewportWidthPoints, height: targetHeight))
        webView.needsLayout = true
        webView.layoutSubtreeIfNeeded()

        if let hostWindow {
            var frame = hostWindow.frame
            frame.size.width = viewportWidthPoints
            frame.size.height = targetHeight
            hostWindow.setFrame(frame, display: false)
            hostWindow.contentView?.needsLayout = true
            hostWindow.contentView?.layoutSubtreeIfNeeded()
        }

        // Let WebKit lay out for the new viewport height before the snapshot is measured or captured.
        await waitForAnimationFrames(webView: webView, timeout: 0.5)
    }

    private func takeSnapshot(webView: WKWebView, config: WKSnapshotConfiguration) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: config) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let image else {
                    continuation.resume(throwing: MarkdownExportService.ExportError.stageFailed(stage: .snapshotOnce, underlying: nil))
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    private func createPDF(webView: WKWebView, rectPoints: CGRect) async throws -> Data {
        let config = WKPDFConfiguration()
        config.rect = rectPoints

        // WebKit can occasionally stall without invoking the completion handler (observed under UI testing).
        // Apply a short timeout so we can fall back to the snapshot pipeline.
        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            var timeoutTask: Task<Void, Never>?

            func resumeOnce(_ result: Result<Data, Error>) {
                guard !didResume else { return }
                didResume = true
                timeoutTask?.cancel()

                switch result {
                case .success(let data):
                    continuation.resume(returning: data)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                resumeOnce(.failure(MarkdownExportService.ExportError.renderingTimeout(stage: .createPDF)))
            }

            webView.createPDF(configuration: config) { result in
                Task { @MainActor in
                    resumeOnce(result)
                }
            }
        }
    }

    /// Moves to the next export stage unless the export was cancelled.
    private func advance(to next: MarkdownExportService.ExportStage) throws {
        try Task.checkCancellation()
        stage = next
    }

    /// Runs CPU-bound capture and encoding off the main actor. Cancelling the export cancels this work (pngquant is
    /// terminated), and the export does not finish until the work has exited.
    private func runDetached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Layout preparation and settle

    private func prepareForExportScrollHeightPoints(webView: WKWebView) async throws -> CGFloat {
        // `WKWebView.callAsyncJavaScript` has been observed to return `nil` (undefined) intermittently under UI testing,
        // so readiness is pushed by the page-side animation-frame watcher through the `scopyExportLayout` handler.
        let widthPoints = Double(viewportWidthPoints)

        let setupJS = "window.ScopyDocument.export.prepare()"
        let adjustWideContentJS = "window.ScopyDocument.export.adjustWideContent(\(widthPoints))"

        do {
            _ = try await readLayoutSample(webView: webView)
            _ = try await evaluateJavaScriptBool(webView: webView, javaScriptString: setupJS)
        } catch {
            throw MarkdownExportService.ExportError.stageFailed(stage: .prepareLayout, underlying: error)
        }

        let readinessDeadline = CFAbsoluteTimeGetCurrent() + 12.0
        var didAdjustWideContent = false
        var adjustAttempts = 0
        var firstSettledAt: CFAbsoluteTime?
        var lastSample: ExportLayoutSample?

        while true {
            let remaining = readinessDeadline - CFAbsoluteTimeGetCurrent()
            guard remaining > 0 else { break }
            let settled = try await awaitLayoutSettled(webView: webView, requireRenderReady: true, timeout: remaining)
            lastSample = settled.sample
            guard settled.isSettled else { break }
            let sample = settled.sample
            let now = CFAbsoluteTimeGetCurrent()
            if firstSettledAt == nil { firstSettledAt = now }

            if !didAdjustWideContent {
                // Wide-content adjustments measure code and table widths, so they wait for fonts unless the page has
                // no font API or fonts never report within 1.2 s of the first settled layout.
                let fontsSettled = sample.fonts == "loaded" || sample.fonts == "n/a" || now - (firstSettledAt ?? now) >= 1.2
                if !fontsSettled {
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    continue
                }
                let adjusted = (try? await evaluateJavaScriptBool(webView: webView, javaScriptString: adjustWideContentJS)) ?? false
                if adjusted {
                    didAdjustWideContent = true
                    continue
                }
                adjustAttempts += 1
                if adjustAttempts < 3 { continue }
                MarkdownExportService.logger.warning("Wide-content adjustment did not run after \(adjustAttempts, privacy: .public) attempts; exporting the measured layout")
                didAdjustWideContent = true
                continue
            }

            return sample.height
        }

        let error = NSError(
            domain: "Scopy.MarkdownExport",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Markdown did not reach terminal render readiness (last height: \(lastSample?.height ?? 0))."
            ]
        )
        throw MarkdownExportService.ExportError.stageFailed(stage: .prepareLayout, underlying: error)
    }


    /// Waits for the layout to settle after a change and returns the larger of the estimate and the live measurement.
    private func reconcileExportHeightPoints(
        webView: WKWebView,
        estimatedHeightPoints: CGFloat
    ) async throws -> CGFloat {
        let settled = try await awaitLayoutSettled(webView: webView, requireRenderReady: false, timeout: 1.0)
        var liveHeight = settled.sample.liveHeight
        if liveHeight <= 0,
           let scrollView = resolvedScrollView(for: webView),
           let documentView = scrollView.documentView
        {
            liveHeight = max(documentView.bounds.height, documentView.frame.height)
        }
        return max(max(1, estimatedHeightPoints), liveHeight)
    }

    private func currentExportScale(webView: WKWebView) async -> CGFloat {
        let raw = try? await evaluateJavaScriptString(webView: webView, javaScriptString: "window.ScopyDocument.export.state.scale")
        guard let raw, let scale = Double(raw), scale > 0 else { return 1 }
        return CGFloat(scale)
    }

    private func applyGlobalScale(webView: WKWebView, scale: CGFloat) async throws {
        let js = "window.ScopyDocument.export.applyScale(\(Double(scale)))"
        do {
            let ok = try await evaluateJavaScriptBool(webView: webView, javaScriptString: js)
            if !ok {
                let error = NSError(
                    domain: "Scopy.MarkdownExport",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "applyGlobalScale returned false"]
                )
                throw MarkdownExportService.ExportError.stageFailed(stage: .applyScale, underlying: error)
            }
        } catch {
            throw MarkdownExportService.ExportError.stageFailed(stage: .applyScale, underlying: error)
        }
        _ = try? await awaitLayoutSettled(webView: webView, requireRenderReady: false, timeout: 1.5)
    }

    // MARK: - Layout settle

    /// Reads the current sample from the page-side watcher (`ScopyDocument.export.watchLayout`), installing it on the
    /// first call; with a phase it also announces a new wait, which the watcher answers by pushing samples.
    private func readLayoutSample(webView: WKWebView, phase: Int? = nil) async throws -> ExportLayoutSample {
        let argument = phase.map(String.init) ?? ""
        let value = try await evaluateJavaScriptString(
            webView: webView,
            javaScriptString: "window.ScopyDocument.export.watchLayout(\(argument))"
        )
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let sample = ExportLayoutMessage(body: object)?.sample else {
            throw NSError(
                domain: "Scopy.MarkdownExport",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Layout watcher returned an unreadable sample: \(value.prefix(120))"]
            )
        }
        return sample
    }

    /// Starts a new layout phase and waits until the page pushes that the layout has been stable for three frames
    /// (at least two frames into the phase). Late messages from earlier phases are dropped. When no push arrives,
    /// animation frames may be throttled (an occluded host window), so each quiet interval reads one sample and
    /// accepts time-based stability: frames stalled for 0.3 s and the height unchanged for 0.45 s. Returns the last
    /// sample either way; `isSettled` tells whether the condition was met before `timeout`.
    private func awaitLayoutSettled(
        webView: WKWebView,
        requireRenderReady: Bool,
        timeout: TimeInterval
    ) async throws -> (sample: ExportLayoutSample, isSettled: Bool) {
        let deadline = CFAbsoluteTimeGetCurrent() + max(0, timeout)
        let phase = layoutPhases.begin()
        var sample = try await readLayoutSample(webView: webView, phase: phase)
        var lastFrames = sample.frames
        var framesChangedAt = CFAbsoluteTimeGetCurrent()
        var lastHeight = sample.height
        var heightStableSince = framesChangedAt
        while true {
            try Self.throwIfRenderFailed(sample)
            let remaining = deadline - CFAbsoluteTimeGetCurrent()
            guard remaining > 0 else { return (sample, false) }
            if let message = await nextLayoutMessage(within: min(remaining, 0.25), where: { message in
                message.sample.renderFailed
                    || (message.event == "settled" && (!requireRenderReady || message.sample.renderReady))
            }) {
                try Self.throwIfRenderFailed(message.sample)
                return (message.sample, true)
            }
            sample = try await readLayoutSample(webView: webView)
            let now = CFAbsoluteTimeGetCurrent()
            if sample.frames != lastFrames {
                lastFrames = sample.frames
                framesChangedAt = now
            }
            if abs(sample.height - lastHeight) >= 1 {
                lastHeight = sample.height
                heightStableSince = now
            }
            let ready = !requireRenderReady || sample.renderReady
            if ready, sample.height > 0, now - framesChangedAt > 0.3, now - heightStableSince >= 0.45 {
                MarkdownExportService.logger.info("Layout watcher frames stalled; accepting time-based stability")
                return (sample, true)
            }
        }
    }

    /// Waits until two animation frames have run in a new phase; best effort, bounded by `timeout`.
    private func waitForAnimationFrames(webView: WKWebView, timeout: TimeInterval) async {
        let phase = layoutPhases.begin()
        guard (try? await readLayoutSample(webView: webView, phase: phase)) != nil else {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return
        }
        _ = await nextLayoutMessage(within: timeout) { $0.event == "frames" || $0.event == "settled" }
    }

    /// The next pushed message of the current phase that satisfies `condition`, or nil after `interval`.
    private func nextLayoutMessage(
        within interval: TimeInterval,
        where condition: @escaping (ExportLayoutMessage) -> Bool
    ) async -> ExportLayoutMessage? {
        if let latest = layoutPhases.latest, condition(latest) { return latest }
        return await withCheckedContinuation { continuation in
            let waiter = ExportLayoutWaiter(condition: condition, continuation: continuation)
            layoutWaiter?.resume(nil)
            layoutWaiter = waiter
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
                if self?.layoutWaiter === waiter { self?.layoutWaiter = nil }
                waiter.resume(nil)
            }
        }
    }

    /// Delivers a message posted by the page to the waiting settle, if it belongs to the current phase.
    fileprivate func receiveLayoutMessage(_ message: ExportLayoutMessage) {
        guard layoutPhases.receive(message), let waiter = layoutWaiter, waiter.condition(message) else { return }
        layoutWaiter = nil
        waiter.resume(message)
    }

    private static func throwIfRenderFailed(_ sample: ExportLayoutSample) throws {
        guard sample.renderFailed else { return }
        let error = NSError(
            domain: "Scopy.MarkdownExport",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: sample.renderErrorReason ?? "Markdown renderer failed"]
        )
        throw MarkdownExportService.ExportError.stageFailed(stage: .prepareLayout, underlying: error)
    }

    // MARK: - UI-test diagnostics

    private func dumpTableMetricsIfRequested(webView: WKWebView) async {
        guard !didDumpTableMetrics else { return }
        guard let path = ProcessInfo.processInfo.environment["SCOPY_EXPORT_TABLE_METRICS_PATH"], !path.isEmpty else { return }

        let widthPoints = Double(viewportWidthPoints)
        let js = "window.ScopyDocument.export.tableMetrics(\(widthPoints))"

        let content = (try? await evaluateJavaScriptString(webView: webView, javaScriptString: js)) ?? ""
        try? Data(content.utf8).write(to: URL(fileURLWithPath: path), options: [.atomic])
        didDumpTableMetrics = true
    }


    private func layoutDebugInfo(webView: WKWebView) async throws -> String {
        let js = "window.ScopyDocument.export.layoutDebugInfo()"
        return try await evaluateJavaScriptString(webView: webView, javaScriptString: js)
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
