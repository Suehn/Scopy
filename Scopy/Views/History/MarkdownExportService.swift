import AppKit
import Foundation
import ImageIO
import os
import ScopyKit
import UniformTypeIdentifiers
import WebKit

/// Service for exporting Markdown preview as PNG image to clipboard
enum MarkdownExportService {
    fileprivate static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Scopy", category: "export")
    static let defaultTargetWidthPixels: CGFloat = 1080

    struct ExportStats: Sendable, Equatable {
        let originalPNGBytes: Int
        let finalPNGBytes: Int
        let pngquantRequested: Bool

        var percentSaved: Int? {
            guard pngquantRequested else { return nil }
            guard originalPNGBytes > 0 else { return nil }
            let saved = 1.0 - (Double(finalPNGBytes) / Double(originalPNGBytes))
            return max(0, min(100, Int((saved * 100.0).rounded())))
        }
    }

    struct ExportOutcome: Sendable {
        let pngData: Data
        let stats: ExportStats
    }

    enum ExportStage: String {
        case loadHTML
        case prepareLayout
        case applyScale
        case snapshotOnce
        case snapshotTiles
        case stitchTiles
        case imageConversion
        case pngEncoding
        case pasteboardWrite
    }

    /// Export Markdown HTML as white-background PNG to clipboard
    /// Creates an offscreen WebView to render the full content
    /// - Parameters:
    ///   - html: The HTML content to render and export
    ///   - viewportWidthPoints: The viewport width used to lay out the HTML before snapshotting
    ///   - completion: Completion handler with result
    @MainActor
    static func exportToPNGClipboard(
        html: String,
        targetWidthPixels: CGFloat = defaultTargetWidthPixels,
        pngquantOptions: PngquantService.Options? = nil,
        completion: @escaping (Result<ExportStats, Error>) -> Void
    ) {
        exportToPNGData(html: html, targetWidthPixels: targetWidthPixels, pngquantOptions: pngquantOptions) { result in
            switch result {
            case .success(let outcome):
                do {
                    if let dumpPath = ProcessInfo.processInfo.environment["SCOPY_EXPORT_DUMP_PATH"], !dumpPath.isEmpty {
                        try? outcome.pngData.write(to: URL(fileURLWithPath: dumpPath), options: [.atomic])
                    }
                    try writePNGToPasteboard(pngData: outcome.pngData, pasteboard: resolvedPasteboardForExport())

                    if let percent = outcome.stats.percentSaved {
                        logger.info(
                            "Exported PNG with pngquant: saved \(percent, privacy: .public)% (\(outcome.stats.originalPNGBytes, privacy: .public) -> \(outcome.stats.finalPNGBytes, privacy: .public) bytes)"
                        )
                    }

                    completion(.success(outcome.stats))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                if let errorPath = ProcessInfo.processInfo.environment["SCOPY_EXPORT_ERROR_DUMP_PATH"], !errorPath.isEmpty {
                    try? Data(String(describing: error).utf8).write(to: URL(fileURLWithPath: errorPath), options: [.atomic])
                }
                completion(.failure(error))
            }
        }
    }

    /// Export Markdown HTML as a white-background PNG data blob.
    /// This is the core export path and is used by clipboard export and tests.
    @MainActor
    static func exportToPNGData(
        html: String,
        targetWidthPixels: CGFloat = defaultTargetWidthPixels,
        pngquantOptions: PngquantService.Options? = nil,
        completion: @escaping (Result<ExportOutcome, Error>) -> Void
    ) {
        let coordinator = ExportCoordinator(
            html: html,
            targetWidthPixels: targetWidthPixels,
            pngquantOptions: pngquantOptions,
            completion: completion
        )
        coordinator.start()
    }

    enum ExportError: LocalizedError {
        case stageFailed(stage: ExportStage, underlying: Error?)
        case renderingTimeout(stage: ExportStage)
        case exportLimitExceeded(reason: String)

        var errorDescription: String? {
            switch self {
            case .stageFailed(let stage, let underlying):
                if let underlying {
                    return "Export failed at \(stage.rawValue): \(underlying.localizedDescription)"
                }
                return "Export failed at \(stage.rawValue)"
            case .renderingTimeout(let stage):
                return "Rendering timed out at \(stage.rawValue)"
            case .exportLimitExceeded(let reason):
                return "Export limit exceeded: \(reason)"
            }
        }
    }

    @MainActor
    static func writePNGToPasteboard(pngData: Data, pasteboard: NSPasteboard) throws {
        pasteboard.declareTypes([.png], owner: nil)

        guard pasteboard.setData(pngData, forType: .png) else {
            logger.error("Failed to set PNG data on pasteboard")
            throw ExportError.stageFailed(stage: .pasteboardWrite, underlying: nil)
        }
    }

    @MainActor
    private static func resolvedPasteboardForExport() -> NSPasteboard {
        let processInfo = ProcessInfo.processInfo
        let isUITesting = processInfo.arguments.contains("--uitesting")
        if isUITesting,
           let name = processInfo.environment["SCOPY_EXPORT_PASTEBOARD_NAME"],
           !name.isEmpty {
            return NSPasteboard(name: NSPasteboard.Name(name))
        }
        return .general
    }
}

// MARK: - Export Coordinator

private enum MarkdownExportRenderConstants {
    static let exportViewportHeightPoints: CGFloat = 1000
    static let minSnapshotHeightPoints: CGFloat = 120

    // Prevent runaway memory usage / internal WebKit snapshot limits.
    static let maxTotalPixels: CGFloat = 60_000_000

    // Keep single-shot snapshots within a conservative height. Taller exports should switch to tiled snapshot + stitch.
    static let maxSingleSnapshotRectHeightPoints: CGFloat = 20_000
    static let snapshotTileOverlapPoints: CGFloat = 1
    static let minAllowedGlobalScale: CGFloat = 0.02
}

/// Manages the lifecycle of offscreen WebView for export
@MainActor
private final class ExportCoordinator: NSObject, WKNavigationDelegate {
    private enum ExportNetworkBlocker {
        private static let ruleListIdentifier = "ScopyMarkdownExportBlockNetwork"
        private static let rulesJSON = """
        [
          {
            "trigger": { "url-filter": "https?://.*" },
            "action": { "type": "block" }
          }
        ]
        """
        @MainActor
        private static var cachedRuleList: WKContentRuleList?
        @MainActor
        private static var compilingTask: Task<WKContentRuleList?, Never>?

        @MainActor
        static func ruleList() async -> WKContentRuleList? {
            if let cachedRuleList { return cachedRuleList }
            if let compilingTask { return await compilingTask.value }

            let task = Task { @MainActor () -> WKContentRuleList? in
                await withCheckedContinuation { continuation in
                    WKContentRuleListStore.default().compileContentRuleList(
                        forIdentifier: ruleListIdentifier,
                        encodedContentRuleList: rulesJSON
                    ) { ruleList, _ in
                        continuation.resume(returning: ruleList)
                    }
                }
            }

            compilingTask = task
            let result = await task.value
            cachedRuleList = result
            compilingTask = nil
            return result
        }
    }

    private let html: String
    private let targetWidthPixels: CGFloat
    private let viewportWidthPoints: CGFloat
    private let pngquantOptions: PngquantService.Options?
    private let completion: (Result<MarkdownExportService.ExportOutcome, Error>) -> Void
    private let targetScreen: NSScreen?
    private let backingScaleFactor: CGFloat
    private var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var timeoutTask: Task<Void, Never>?
    private var isCompleted = false
    private var exportTask: Task<Void, Never>?
    private var stage: MarkdownExportService.ExportStage = .loadHTML
    private var didDumpTableMetrics = false

    // Keep a strong reference to self until export completes
    private static var activeCoordinators: Set<ExportCoordinator> = []

    init(
        html: String,
        targetWidthPixels: CGFloat,
        pngquantOptions: PngquantService.Options?,
        completion: @escaping (Result<MarkdownExportService.ExportOutcome, Error>) -> Void
    ) {
        self.html = html
        self.completion = completion
        let screen = Self.activeScreen()
        self.targetScreen = screen
        self.backingScaleFactor = screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        self.targetWidthPixels = max(1, targetWidthPixels)
        self.viewportWidthPoints = max(1, self.targetWidthPixels / max(1, self.backingScaleFactor))
        self.pngquantOptions = pngquantOptions
        super.init()
    }

    func start() {
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

        Task { @MainActor in
            await self.startWebViewAndLoadHTML()
        }
    }

    private func startWebViewAndLoadHTML() async {
        guard !isCompleted else { return }

        // Create offscreen WebView with an explicit viewport size to make layout deterministic.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController = WKUserContentController()

        if let ruleList = await ExportNetworkBlocker.ruleList() {
            config.userContentController.add(ruleList)
        }

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
        let baseURL = Bundle.main.resourceURL?.appendingPathComponent("MarkdownPreview", isDirectory: true)
        wv.loadHTMLString(exportHTML, baseURL: baseURL)
    }

    private func injectExportStyles(_ html: String) -> String {
        // Insert export-specific styles before </head>
        let exportStyles = """
        <style id="scopy-export-style">
            :root { color-scheme: light !important; }
            html, body {
                background: #FFFFFF !important;
                color: #000000 !important;
                -webkit-text-size-adjust: 100% !important;
            }

            #content {
                background: #FFFFFF !important;
                display: block !important;
                width: 100% !important;
                max-width: 100% !important;
                opacity: 1 !important;
                transition: none !important;
            }

            /* During export we may scroll programmatically for tiled snapshots; always keep inner scrollbars hidden. */
            html.scopy-scrollbars-visible pre::-webkit-scrollbar,
            html.scopy-scrollbars-visible table::-webkit-scrollbar,
            html.scopy-scrollbars-visible .katex-display::-webkit-scrollbar {
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

    // MARK: - Rendering Pipeline

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

    private func exportPNG(webView: WKWebView) async throws -> MarkdownExportService.ExportOutcome {
        stage = .prepareLayout
        let initialScrollHeightPoints = try await prepareForExportScrollHeightPoints(webView: webView)
        var scrollHeightPoints = initialScrollHeightPoints
        if scrollHeightPoints <= 0 {
            let details = (try? await layoutDebugInfo(webView: webView)) ?? "No debug info"
            let underlying = NSError(
                domain: "Scopy.MarkdownExport",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid scroll height (0). \(details)"]
            )
            throw MarkdownExportService.ExportError.stageFailed(stage: .prepareLayout, underlying: underlying)
        }

        stage = .applyScale
        // Target output width is fixed (pixels). We avoid downscaling unless we hit safe image-area constraints.
        var appliedScale: CGFloat = 1
        let widthPixels = max(1, targetWidthPixels)
        let maxHeightPixelsByArea: CGFloat = MarkdownExportRenderConstants.maxTotalPixels / widthPixels

        // Apply global scale iteratively. Under WebKit, applying scale can reflow content (e.g. line wrapping),
        // so a single pass based on the initial height may still exceed the safe area budget.
        for _ in 0..<6 {
            let heightPixels = scrollHeightPoints * backingScaleFactor
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

        stage = .snapshotOnce
        if scrollHeightPoints <= MarkdownExportRenderConstants.maxSingleSnapshotRectHeightPoints {
            do {
                let outcome = try await exportSingleSnapshotPNG(webView: webView, heightPoints: scrollHeightPoints)
                return outcome
            } catch {
                // Fall back to tiled snapshots for robustness (long content or intermittent WebKit snapshot failures).
                MarkdownExportService.logger.error("Single snapshot failed; falling back to tiled export. scale=\(appliedScale, privacy: .public) heightPt=\(scrollHeightPoints, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }

        stage = .snapshotTiles
        let outcome = try await exportTiledPNG(webView: webView, totalHeightPoints: scrollHeightPoints)
        return outcome
    }

    private func exportSingleSnapshotPNG(webView: WKWebView, heightPoints: CGFloat) async throws -> MarkdownExportService.ExportOutcome {
        try await resizeWebViewForSnapshot(webView: webView, heightPoints: heightPoints)

        let rectPoints = CGRect(
            x: 0,
            y: 0,
            width: viewportWidthPoints,
            height: max(1, ceil(heightPoints))
        )

        let config = WKSnapshotConfiguration()
        config.rect = rectPoints
        config.snapshotWidth = NSNumber(value: Double(viewportWidthPoints))
        config.afterScreenUpdates = true

        let image = try await takeSnapshot(webView: webView, config: config)

        stage = .imageConversion
        let cg = try cgImage(from: image)

        stage = .pngEncoding
        let targetWidthPixels = self.targetWidthPixels
        let pngquantOptions = self.pngquantOptions
        return try await Task.detached(priority: .userInitiated) {
            let targetWidth = max(1, Int(round(targetWidthPixels)))
            let normalized = Self.scaleCGImageIfNeeded(image: cg, targetWidthPixels: targetWidth)
            let originalData = try Self.pngDataFromCGImageWithWhiteBackground(normalized)
            let finalData: Data
            if let pngquantOptions {
                finalData = PngquantService.compressBestEffort(originalData, options: pngquantOptions)
            } else {
                finalData = originalData
            }
            return MarkdownExportService.ExportOutcome(
                pngData: finalData,
                stats: MarkdownExportService.ExportStats(
                    originalPNGBytes: originalData.count,
                    finalPNGBytes: finalData.count,
                    pngquantRequested: pngquantOptions != nil
                )
            )
        }.value
    }

    private func exportTiledPNG(webView: WKWebView, totalHeightPoints: CGFloat) async throws -> MarkdownExportService.ExportOutcome {
        let targetWidthPixelsInt = max(1, Int(round(targetWidthPixels)))
        let totalHeightPointsInt = max(1, Int(ceil(totalHeightPoints)))
        let totalHeightPixelsInt = max(1, Int(ceil(CGFloat(totalHeightPointsInt) * backingScaleFactor)))

        // Safety: enforce area limit. (Global zoom already tried to satisfy this, but keep a hard guard.)
        let totalPixels = CGFloat(targetWidthPixelsInt) * CGFloat(totalHeightPixelsInt)
        if totalPixels > MarkdownExportRenderConstants.maxTotalPixels + 0.5 {
            let details = (try? await layoutDebugInfo(webView: webView)) ?? "No debug info"
            throw MarkdownExportService.ExportError.exportLimitExceeded(
                reason: "Image too large after layout (w=\(targetWidthPixelsInt)px, h=\(totalHeightPixelsInt)px, total=\(Int(totalPixels))px). \(details)"
            )
        }

        let bytesPerRow = targetWidthPixelsInt * 4
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: targetWidthPixelsInt,
            height: totalHeightPixelsInt,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else {
            throw MarkdownExportService.ExportError.stageFailed(stage: .stitchTiles, underlying: nil)
        }

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(targetWidthPixelsInt), height: CGFloat(totalHeightPixelsInt)))

        stage = .snapshotTiles
        let tileViewportHeightPoints = MarkdownExportRenderConstants.exportViewportHeightPoints
        try await resizeWebViewForSnapshot(webView: webView, heightPoints: tileViewportHeightPoints)

        let overlapPoints = max(0, MarkdownExportRenderConstants.snapshotTileOverlapPoints)
        var scrollYPoints: CGFloat = 0
        while scrollYPoints < CGFloat(totalHeightPointsInt) {
            let remaining = CGFloat(totalHeightPointsInt) - scrollYPoints
            let captureHeightPoints = max(1, min(tileViewportHeightPoints, remaining))

            try await scrollTo(webView: webView, yPoints: scrollYPoints)

            let rectPoints = CGRect(
                x: 0,
                y: 0,
                width: viewportWidthPoints,
                height: captureHeightPoints
            )
            let config = WKSnapshotConfiguration()
            config.rect = rectPoints
            config.snapshotWidth = NSNumber(value: Double(viewportWidthPoints))
            config.afterScreenUpdates = true

            let image = try await takeSnapshot(webView: webView, config: config)
            let tileCG = try cgImage(from: image)

            let normalizedTile = Self.scaleCGImageIfNeeded(image: tileCG, targetWidthPixels: targetWidthPixelsInt)

            // Place the tile using scroll offset -> output coordinate mapping.
            // outputBottomY = totalHeight - (scrollY + captureHeight)
            let bottomYPoints = CGFloat(totalHeightPointsInt) - (scrollYPoints + captureHeightPoints)
            var drawY = Int(round(bottomYPoints * backingScaleFactor))
            if drawY < 0 { drawY = 0 }
            if drawY + normalizedTile.height > totalHeightPixelsInt {
                drawY = max(0, totalHeightPixelsInt - normalizedTile.height)
            }

            stage = .stitchTiles
            ctx.draw(
                normalizedTile,
                in: CGRect(
                    x: 0,
                    y: CGFloat(drawY),
                    width: CGFloat(targetWidthPixelsInt),
                    height: CGFloat(normalizedTile.height)
                )
            )

            if remaining <= tileViewportHeightPoints { break }
            scrollYPoints += max(1, tileViewportHeightPoints - overlapPoints)
        }

        guard let stitched = ctx.makeImage() else {
            throw MarkdownExportService.ExportError.stageFailed(stage: .stitchTiles, underlying: nil)
        }

        stage = .pngEncoding
        let trimmed = Self.trimBottomWhitespaceIfNeeded(image: stitched, contextData: ctx.data, bytesPerRow: bytesPerRow)
        let originalPNG = try Self.pngDataFromCGImage(trimmed)
        if let pngquantOptions {
            let finalPNG = await Task.detached(priority: .userInitiated) {
                PngquantService.compressBestEffort(originalPNG, options: pngquantOptions)
            }.value
            return MarkdownExportService.ExportOutcome(
                pngData: finalPNG,
                stats: MarkdownExportService.ExportStats(
                    originalPNGBytes: originalPNG.count,
                    finalPNGBytes: finalPNG.count,
                    pngquantRequested: true
                )
            )
        }
        return MarkdownExportService.ExportOutcome(
            pngData: originalPNG,
            stats: MarkdownExportService.ExportStats(
                originalPNGBytes: originalPNG.count,
                finalPNGBytes: originalPNG.count,
                pngquantRequested: false
            )
        )
    }

    private func scrollTo(webView: WKWebView, yPoints: CGFloat) async throws {
        let js = """
        (function() {
          try { window.scrollTo(0, \(Double(max(0, yPoints)))); } catch (e) { }
          return true;
        })();
        """
        _ = try await evaluateJavaScript(webView: webView, javaScriptString: js)
        // Give WebKit a moment to paint after programmatic scroll.
        try? await Task.sleep(nanoseconds: 70_000_000)
    }

    private func cgImage(from image: NSImage) throws -> CGImage {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            throw MarkdownExportService.ExportError.stageFailed(stage: .imageConversion, underlying: nil)
        }
        return cg
    }

    private func prepareForExportScrollHeightPoints(webView: WKWebView) async throws -> CGFloat {
        // `WKWebView.callAsyncJavaScript` has been observed to return `nil` (undefined) intermittently under UI testing.
        // To keep export deterministic, use synchronous `evaluateJavaScript` + a short settle loop from Swift.
        let widthPoints = Double(viewportWidthPoints)

        let setupJS = """
        (function() {
          try {
            var content = document.getElementById('content');
            if (content) {
              try { content.style.opacity = '1'; } catch (e) { }
              try { content.style.transition = 'none'; } catch (e) { }
            }
            try { if (typeof window.__scopyRenderMath === 'function') { window.__scopyRenderMath(); } } catch (e) { }
          } catch (e) { }
          return true;
        })();
        """

        let scaleTablesJS = """
        (function() {
          var w = \(widthPoints);
          var minAllowNoWrapScale = 0.35; // below this, wrap to preserve readability
          function computeTargetWidthPoints(content) {
            var padL = 0, padR = 0;
            try {
              var cs = window.getComputedStyle(content);
              padL = parseFloat(cs.paddingLeft) || 0;
              padR = parseFloat(cs.paddingRight) || 0;
            } catch (e) { padL = 0; padR = 0; }
            return Math.max(1, Math.floor(w - padL - padR));
          }
          function unwrapIfNeeded(table) {
            try {
              var p = table && table.parentElement;
              if (!p) { return; }
              if (!p.classList || !p.classList.contains('scopy-export-table-wrapper')) { return; }
              var gp = p.parentNode;
              if (!gp) { return; }
              gp.insertBefore(table, p);
              gp.removeChild(p);
            } catch (e) { }
          }
          function applyNoWrap(table) {
            try {
              var cells = table.querySelectorAll('th, td');
              for (var j = 0; j < (cells.length || 0); j++) {
                var cell = cells[j];
                if (!cell || !cell.style) { continue; }
                cell.style.maxWidth = 'none';
                cell.style.minWidth = '0';
                cell.style.whiteSpace = 'nowrap';
                cell.style.overflowWrap = 'normal';
                cell.style.wordBreak = 'normal';
              }
            } catch (e) { }
            try {
              table.style.tableLayout = 'auto';
              table.style.width = 'auto';
              table.style.maxWidth = 'none';
            } catch (e) { }
          }

          function applyWrap(table) {
            try {
              var cells = table.querySelectorAll('th, td');
              for (var j = 0; j < (cells.length || 0); j++) {
                var cell = cells[j];
                if (!cell || !cell.style) { continue; }
                cell.style.maxWidth = 'none';
                cell.style.minWidth = '0';
                cell.style.whiteSpace = 'normal';
                cell.style.overflowWrap = 'anywhere';
                cell.style.wordBreak = 'break-word';
              }
            } catch (e) { }
            try {
              table.style.tableLayout = 'fixed';
              table.style.width = '100%';
              table.style.maxWidth = '100%';
            } catch (e) { }
          }

          function measureTableWidth(table) {
            try { void table.offsetHeight; } catch (e) { }
            var rectW = 0, scrollW = 0, offsetW = 0;
            try { rectW = Math.ceil((table.getBoundingClientRect().width || 0)); } catch (e) { rectW = 0; }
            try { scrollW = Math.ceil((table.scrollWidth || 0)); } catch (e) { scrollW = 0; }
            try { offsetW = Math.ceil((table.offsetWidth || 0)); } catch (e) { offsetW = 0; }
            return Math.max(rectW, scrollW, offsetW);
          }

          function scaleWideTables(content, targetWidth) {
            if (!content || !content.querySelectorAll) { return; }
            var tables = content.querySelectorAll('table');
            for (var i = 0; i < (tables.length || 0); i++) {
              var table = tables[i];
              if (!table) { continue; }
              unwrapIfNeeded(table);

              try { table.style.transform = 'none'; } catch (e) { }
              try { table.style.transformOrigin = 'top left'; } catch (e) { }
              try {
                table.style.display = 'table';
                table.style.overflow = 'visible';
              } catch (e) { }

              applyNoWrap(table);

              var rawWidth = measureTableWidth(table);
              if (!rawWidth || rawWidth <= targetWidth + 1) { continue; }

              var scale = targetWidth / rawWidth;
              var useWrap = false;
              if (scale > 0 && scale < minAllowNoWrapScale) {
                // Preserve readability: cap minimum scale at 0.35, and enable wrapping to avoid truncation.
                applyWrap(table);
                useWrap = true;
                scale = minAllowNoWrapScale;
                rawWidth = Math.ceil(targetWidth / minAllowNoWrapScale);
              }
              if (!scale || !isFinite(scale) || scale >= 0.999) { continue; }
              if (scale <= 0) { continue; }

              // Expand the table to its raw width, then scale down inside a fixed-width wrapper.
              try {
                table.style.tableLayout = useWrap ? 'fixed' : 'auto';
                table.style.width = Math.ceil(rawWidth) + 'px';
                table.style.maxWidth = 'none';
                table.style.overflow = 'visible';
              } catch (e) { }

              var wrapper = document.createElement('div');
              wrapper.className = 'scopy-export-table-wrapper';
              wrapper.style.display = 'block';
              wrapper.style.width = targetWidth + 'px';
              wrapper.style.height = '1px';
              wrapper.style.overflow = 'visible';
              wrapper.style.margin = '0';
              wrapper.style.padding = '0';

              try {
                table.style.transform = 'scale(' + scale + ')';
                table.style.transformOrigin = 'top left';
              } catch (e) { }

              var parent = table.parentNode;
              if (!parent) { continue; }
              parent.insertBefore(wrapper, table);
              wrapper.appendChild(table);

              // Force layout and set wrapper height to preserve document flow.
              try { void table.offsetHeight; } catch (e) { }
              try {
                var scaledRect = table.getBoundingClientRect();
                var scaledH = Math.ceil(scaledRect.height || table.offsetHeight || 0);
                if (scaledH && scaledH > 0) {
                  wrapper.style.height = (scaledH + 2) + 'px';
                }
              } catch (e) { }
            }
          }

          var content = document.getElementById('content');
          if (!content) { return false; }
          var targetWidth = computeTargetWidthPoints(content);
          scaleWideTables(content, targetWidth);
          return true;
        })();
        """

        let measureJS = """
        (function() {
          try {
            var c = document.getElementById('content');
            if (!c) { return JSON.stringify({ hasContent: false, height: 0, fonts: 'n/a' }); }

            var rectH = 0;
            try {
              if (typeof c.getBoundingClientRect === 'function') {
                var r = c.getBoundingClientRect();
                rectH = Math.ceil(r.height || 0);
              }
            } catch (e) { rectH = 0; }

            var sh = 0;
            try { sh = Math.ceil(c.scrollHeight || 0); } catch (e) { sh = 0; }

            // Prefer #content measurements for export height so short content doesn't get padded to the viewport height.
            // (documentElement.scrollHeight tends to floor to the viewport height.)
            var useTransform = !!(window && window.__scopyExportUsesTransform);
            var h = 0;
            if (useTransform && rectH > 0) {
              h = rectH;
            } else {
              h = Math.max(rectH || 0, sh || 0);
            }

            var fonts = 'n/a';
            try { fonts = (document.fonts && document.fonts.status) ? document.fonts.status : 'n/a'; } catch (e) { fonts = 'n/a'; }
            return JSON.stringify({ hasContent: true, height: Math.ceil(h || 0), fonts: fonts });
          } catch (e) {
            return JSON.stringify({ hasContent: false, height: 0, fonts: 'n/a' });
          }
        })();
        """

        do {
            _ = try await evaluateJavaScript(webView: webView, javaScriptString: setupJS)
        } catch {
            throw MarkdownExportService.ExportError.stageFailed(stage: .prepareLayout, underlying: error)
        }

        var lastNonZeroHeight: CGFloat = 0
        var stableSince: CFAbsoluteTime?
        var firstNonZeroAt: CFAbsoluteTime?
        var didScaleTables = false
        var fontsWereLoaded = false

        for _ in 0..<60 {
            let now = CFAbsoluteTimeGetCurrent()
            let value: Any?
            do {
                value = try await evaluateJavaScript(webView: webView, javaScriptString: measureJS)
            } catch {
                throw MarkdownExportService.ExportError.stageFailed(stage: .prepareLayout, underlying: error)
            }

            let parsedHeight = Self.parseHeightFromMeasureValue(value)
            let fontsStatus = Self.parseFontsStatusFromMeasureValue(value)
            if fontsStatus == "loaded" { fontsWereLoaded = true }
            if parsedHeight <= 0 {
                stableSince = nil
                try? await Task.sleep(nanoseconds: 80_000_000)
                continue
            }
            if firstNonZeroAt == nil { firstNonZeroAt = now }

            if lastNonZeroHeight > 0, abs(parsedHeight - lastNonZeroHeight) < 1 {
                if stableSince == nil { stableSince = now }
            } else {
                stableSince = nil
                lastNonZeroHeight = parsedHeight
            }

            // Scale tables once, ideally after fonts are loaded and layout has stopped changing briefly.
            // This avoids over-scaling caused by late font swaps or delayed DOM updates.
            if !didScaleTables,
               (fontsWereLoaded || fontsStatus == "n/a"),
               let stableStart = stableSince,
               (now - stableStart) >= 0.20
            {
                _ = try? await evaluateJavaScript(webView: webView, javaScriptString: scaleTablesJS)
                didScaleTables = true
                stableSince = nil
                lastNonZeroHeight = 0
                try? await Task.sleep(nanoseconds: 120_000_000)
                continue
            }

            // Consider layout stable only if height has been unchanged for long enough.
            // This prevents returning early when #content starts at a small non-zero height (e.g. padding-only),
            // then gets populated asynchronously (markdown-it / KaTeX / delayed scripts).
            if let stableStart = stableSince, (now - stableStart) >= 0.45 {
                return parsedHeight
            }

            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        return lastNonZeroHeight
    }

    private func dumpTableMetricsIfRequested(webView: WKWebView) async {
        guard !didDumpTableMetrics else { return }
        guard let path = ProcessInfo.processInfo.environment["SCOPY_EXPORT_TABLE_METRICS_PATH"], !path.isEmpty else { return }

        let widthPoints = Double(viewportWidthPoints)
        let js = """
        (function() {
          try {
            var content = document.getElementById('content');
            if (!content) { return JSON.stringify({ hasContent: false, targetWidth: 0, tables: [] }); }

            var padL = 0, padR = 0;
            try {
              var cs = window.getComputedStyle(content);
              padL = parseFloat(cs.paddingLeft) || 0;
              padR = parseFloat(cs.paddingRight) || 0;
            } catch (e) { padL = 0; padR = 0; }
            var targetWidth = Math.max(1, Math.floor(\(widthPoints) - padL - padR));

            function parseScale(transform) {
              if (!transform || transform === 'none') { return 1; }
              // matrix(a, b, c, d, e, f) => scaleX ~= sqrt(a^2 + b^2)
              var m = transform.match(/matrix\\(([^)]+)\\)/);
              if (!m || !m[1]) { return 1; }
              var parts = m[1].split(',').map(function(x) { return parseFloat(x); });
              if (!parts || parts.length < 4) { return 1; }
              var a = parts[0], b = parts[1];
              var s = Math.sqrt((a * a) + (b * b));
              return (s && isFinite(s) && s > 0) ? s : 1;
            }

            var tables = content.querySelectorAll('table');
            var out = [];
            for (var i = 0; i < (tables.length || 0); i++) {
              var t = tables[i];
              if (!t) { continue; }
              var rect = t.getBoundingClientRect();
              var w = Math.ceil(rect.width || 0);
              var sw = 0, cw = 0;
              try { sw = Math.ceil(t.scrollWidth || 0); } catch (e) { sw = 0; }
              try { cw = Math.ceil(t.clientWidth || 0); } catch (e) { cw = 0; }

              var wrapped = false;
              var wrapperW = 0;
              try {
                var p = t.parentElement;
                wrapped = !!(p && p.classList && p.classList.contains('scopy-export-table-wrapper'));
                if (wrapped) {
                  var pr = p.getBoundingClientRect();
                  wrapperW = Math.ceil(pr.width || 0);
                }
              } catch (e) { wrapped = false; wrapperW = 0; }

              var cols = 0;
              try {
                var row = t.querySelector('tr');
                if (row && row.children) { cols = row.children.length || 0; }
              } catch (e) { cols = 0; }

              var scale = 1;
              try {
                var tr = window.getComputedStyle(t).transform;
                scale = parseScale(tr);
              } catch (e) { scale = 1; }

              out.push({
                index: i,
                cols: cols,
                width: w,
                scrollWidth: sw,
                clientWidth: cw,
                wrapped: wrapped,
                wrapperWidth: wrapperW,
                scale: scale,
                targetWidth: targetWidth
              });
            }

            return JSON.stringify({ hasContent: true, targetWidth: targetWidth, tables: out });
          } catch (e) {
            return JSON.stringify({ hasContent: false, targetWidth: 0, tables: [], error: String(e) });
          }
        })();
        """

        let value = try? await evaluateJavaScript(webView: webView, javaScriptString: js)
        let content: String
        if let s = value as? String {
            content = s
        } else {
            content = String(describing: value)
        }
        try? Data(content.utf8).write(to: URL(fileURLWithPath: path), options: [.atomic])
        didDumpTableMetrics = true
    }

    nonisolated private static func parseHeightFromMeasureValue(_ value: Any?) -> CGFloat {
        if let s = value as? String,
           let data = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if let n = obj["height"] as? NSNumber { return max(0, CGFloat(truncating: n)) }
            if let d = obj["height"] as? Double { return max(0, CGFloat(d)) }
            if let i = obj["height"] as? Int { return max(0, CGFloat(i)) }
            if let str = obj["height"] as? String, let d = Double(str) { return max(0, CGFloat(d)) }
        }
        if let n = value as? NSNumber { return max(0, CGFloat(truncating: n)) }
        if let d = value as? Double { return max(0, CGFloat(d)) }
        return 0
    }

    nonisolated private static func parseFontsStatusFromMeasureValue(_ value: Any?) -> String? {
        guard let s = value as? String,
              let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let status = obj["fonts"] as? String { return status }
        return nil
    }

    private func layoutDebugInfo(webView: WKWebView) async throws -> String {
        let js = """
        (function() {
          try {
            var c = document.getElementById('content');
            var info = {
              readyState: (document && document.readyState) ? document.readyState : 'unknown',
              hasContent: !!c,
              exportScale: (window && window.__scopyExportScale) ? window.__scopyExportScale : 1,
              baseFontSize: (window && window.__scopyExportBaseFontSize) ? window.__scopyExportBaseFontSize : 0,
              bodyFontSize: (function() {
                try { return (window.getComputedStyle && document.body) ? window.getComputedStyle(document.body).fontSize : ''; } catch (e) { return ''; }
              })(),
              devicePixelRatio: (window && window.devicePixelRatio) ? window.devicePixelRatio : 1,
              innerHeight: (window && window.innerHeight) ? window.innerHeight : 0,
              bodyScrollHeight: (document.body && document.body.scrollHeight) ? document.body.scrollHeight : 0,
              documentScrollHeight: (document.documentElement && document.documentElement.scrollHeight) ? document.documentElement.scrollHeight : 0,
              contentScrollHeight: (c && c.scrollHeight) ? c.scrollHeight : 0,
              contentRectHeight: (c && c.getBoundingClientRect) ? Math.ceil(c.getBoundingClientRect().height || 0) : 0
            };
            return JSON.stringify(info);
          } catch (e) {
            return "debugError:" + (e && e.message ? e.message : String(e));
          }
        })();
        """
        let value = try await evaluateJavaScript(webView: webView, javaScriptString: js)
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return String(describing: value)
    }

    private func applyGlobalScale(webView: WKWebView, scale: CGFloat) async throws {
        let js = """
        (function() {
          try {
            // Reset any prior scaling so we can re-apply deterministically.
            try { document.documentElement && (document.documentElement.style.zoom = ''); } catch (e) { }
            try { document.body && (document.body.style.zoom = ''); } catch (e) { }

            window.__scopyExportScale = \(Double(scale));
            window.__scopyExportUsesTransform = true;

            var body = document.body;
            if (!body) { return false; }
            var content = document.getElementById('content');
            if (!content) { return false; }

            var nextScale = \(Double(scale));
            if (!nextScale || !isFinite(nextScale) || nextScale <= 0) { nextScale = 1; }

            // Scale the entire content (including images) via transform and compensate width.
            try {
              content.style.transformOrigin = 'top left';
              content.style.transform = 'scale(' + nextScale + ')';
              var widthPercent = Math.max(1, (100 / nextScale));
              content.style.width = widthPercent + '%';
              content.style.maxWidth = widthPercent + '%';
              content.style.display = 'inline-block';
            } catch (e) { return false; }

            // Ensure font-size reset so we don't double-scale text.
            try { body.style.fontSize = ''; } catch (e) { }
            return true;
          } catch (e) {
            return false;
          }
        })();
        """
        do {
            let result = try await evaluateJavaScript(webView: webView, javaScriptString: js)
            let ok: Bool
            if let boolValue = result as? Bool {
                ok = boolValue
            } else if let num = result as? NSNumber {
                ok = num.boolValue
            } else {
                ok = false
            }
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
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    private func scrollToTop(webView: WKWebView) async throws {
        let js = """
        (function() {
          try { window.scrollTo(0, 0); } catch (e) { }
          return true;
        })();
        """
        do {
            _ = try await evaluateJavaScript(webView: webView, javaScriptString: js)
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

        // Give WebKit a moment to realize the new viewport height and fully paint.
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    private func evaluateJavaScript(webView: WKWebView, javaScriptString: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(javaScriptString) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: value)
            }
        }
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

    nonisolated private static func pngDataFromCGImageWithWhiteBackground(_ image: CGImage) throws -> Data {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else {
            throw MarkdownExportService.ExportError.stageFailed(stage: .imageConversion, underlying: nil)
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let bytesPerRow = w * 4
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else {
            throw MarkdownExportService.ExportError.stageFailed(stage: .imageConversion, underlying: nil)
        }

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))

        guard let flattened = ctx.makeImage() else {
            throw MarkdownExportService.ExportError.stageFailed(stage: .imageConversion, underlying: nil)
        }

        let trimmed = trimBottomWhitespaceIfNeeded(image: flattened, contextData: ctx.data, bytesPerRow: bytesPerRow)

        return try pngDataFromCGImage(trimmed)
    }

    nonisolated private static func pngDataFromCGImage(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw MarkdownExportService.ExportError.stageFailed(stage: .pngEncoding, underlying: nil)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MarkdownExportService.ExportError.stageFailed(stage: .pngEncoding, underlying: nil)
        }
        return data as Data
    }

    nonisolated private static func trimBottomWhitespaceIfNeeded(
        image: CGImage,
        contextData: UnsafeMutableRawPointer?,
        bytesPerRow: Int
    ) -> CGImage {
        // The export background is forced to white. If we accidentally over-measure content height or WebKit leaves
        // unpainted regions at the bottom, we can trim trailing white space for a tighter and more readable result.
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return image }
        guard let contextData else { return image }
        guard bytesPerRow > 0 else { return image }

        let buffer = contextData.assumingMemoryBound(to: UInt8.self)
        let sampleStepX = 8
        let skipRightPixels = min(24, max(0, w / 24))
        let whiteThreshold: UInt8 = 250

        func rowIsMostlyWhite(_ y: Int) -> Bool {
            let start = y * bytesPerRow
            var darkCount = 0
            var sampleCount = 0
            var x = 0
            let maxX = max(0, w - skipRightPixels)
            while x < maxX {
                let idx = start + x * 4
                if idx + 2 < bytesPerRow * h {
                    let r = buffer[idx]
                    let g = buffer[idx + 1]
                    let b = buffer[idx + 2]
                    if r < whiteThreshold || g < whiteThreshold || b < whiteThreshold {
                        darkCount += 1
                    }
                    sampleCount += 1
                }
                x += sampleStepX
            }
            // Treat a row as "white" if it contains at most a handful of non-white samples (anti-aliasing noise).
            return darkCount <= max(6, sampleCount / 180)
        }

        // Find the first non-white row from the bottom (bitmap context origin is bottom-left).
        var firstContentFromBottomY: Int?
        for y in 0..<h {
            if !rowIsMostlyWhite(y) {
                firstContentFromBottomY = y
                break
            }
        }

        guard let firstContentFromBottomY else { return image }

        // Keep a small bottom margin (in pixels) so content doesn't touch the edge.
        let bottomMargin = min(40, max(0, h - 1))
        let cropStartY = max(0, firstContentFromBottomY - bottomMargin)
        if cropStartY <= 0 { return image }

        let croppedHeight = h - cropStartY
        guard croppedHeight > 0, croppedHeight < h else { return image }

        let rect = CGRect(x: 0, y: cropStartY, width: w, height: croppedHeight)
        return image.cropping(to: rect) ?? image
    }

    nonisolated private static func scaleCGImageIfNeeded(image: CGImage, targetWidthPixels: Int) -> CGImage {
        let srcW = image.width
        let srcH = image.height
        guard srcW > 0, srcH > 0 else { return image }
        guard targetWidthPixels > 0 else { return image }
        if srcW == targetWidthPixels { return image }

        let scale = CGFloat(targetWidthPixels) / CGFloat(srcW)
        let targetHeightPixels = max(1, Int(round(CGFloat(srcH) * scale)))

        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: targetWidthPixels,
            height: targetHeightPixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else {
            return image
        }

        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(targetWidthPixels), height: CGFloat(targetHeightPixels)))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(targetWidthPixels), height: CGFloat(targetHeightPixels)))

        return ctx.makeImage() ?? image
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
        exportTask?.cancel()
        exportTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        hostWindow?.orderOut(nil)
        hostWindow = nil
        Self.activeCoordinators.remove(self)
    }

}
