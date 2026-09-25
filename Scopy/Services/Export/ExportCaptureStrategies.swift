import AppKit
import Darwin
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers
import WebKit

extension ExportCoordinator {
    func exportPNG(webView: WKWebView) async throws -> MarkdownExportService.ExportOutcome {
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

    func exportPDFRasterizedPNG(webView: WKWebView, heightPoints: CGFloat) async throws -> MarkdownExportService.ExportOutcome {
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
            let metrics = try Self.pdfRasterMetrics(pdfData: pdfData, targetWidthPixels: targetWidthPixels)
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
                let canvas = try Self.rasterizePDFDataToCanvas(
                    pdfData: pdfData,
                    targetWidthPixels: targetWidthPixels,
                    expectedPageWidthPoints: expectedPageWidthPoints,
                    contentScaleCompensation: contentScaleCompensation
                )
                try Task.checkCancellation()
                return try Self.encodeExportCanvas(canvas, pngquantOptions: pngquantOptions)
            }
        }

        throw MarkdownExportService.ExportError.exportLimitExceeded(
            reason: lastLimitReason ?? "PDF rasterization remained above budget after export-scale retries"
        )
    }

    func exportSingleSnapshotPNG(webView: WKWebView, heightPoints: CGFloat) async throws -> MarkdownExportService.ExportOutcome {
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
            let canvas = try Self.canvasFromSnapshot(cg, targetWidthPixels: targetWidth)
            try Task.checkCancellation()
            return try Self.encodeExportCanvas(canvas, pngquantOptions: pngquantOptions)
        }
    }

    func exportTiledPNG(webView: WKWebView, totalHeightPoints: CGFloat) async throws -> MarkdownExportService.ExportOutcome {
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

            let normalizedTile = Self.scaleCGImageIfNeeded(image: tileCG, targetWidthPixels: targetWidthPixelsInt)

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
            try Self.encodeExportCanvas(canvas, pngquantOptions: pngquantOptions)
        }
    }

    func scrollTo(webView: WKWebView, yPoints: CGFloat) async throws -> CGFloat {
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

    func resolvedScrollView(for webView: WKWebView) -> NSScrollView? {
        if let enclosing = webView.enclosingScrollView {
            return enclosing
        }
        return findFirstScrollView(in: webView)
    }

    func findFirstScrollView(in view: NSView) -> NSScrollView? {
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

    func cgImage(from image: NSImage) throws -> CGImage {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            throw MarkdownExportService.ExportError.stageFailed(stage: .imageConversion, underlying: nil)
        }
        return cg
    }

    func scrollToTop(webView: WKWebView) async throws {
        do {
            _ = try await scrollTo(webView: webView, yPoints: 0)
        } catch {
            // Best-effort: scrolling shouldn't be a hard failure for export.
        }
    }

    func resizeWebViewForSnapshot(webView: WKWebView, heightPoints: CGFloat) async throws {
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

    func takeSnapshot(webView: WKWebView, config: WKSnapshotConfiguration) async throws -> NSImage {
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

    func createPDF(webView: WKWebView, rectPoints: CGRect) async throws -> Data {
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
    func advance(to next: MarkdownExportService.ExportStage) throws {
        try Task.checkCancellation()
        stage = next
    }

    /// Runs CPU-bound capture and encoding off the main actor. Cancelling the export cancels this work (pngquant is
    /// terminated), and the export does not finish until the work has exited.
    func runDetached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
