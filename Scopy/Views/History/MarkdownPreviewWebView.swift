import Foundation
import SwiftUI
import AppKit
import WebKit
import ScopyUISupport
import UniformTypeIdentifiers
import ImageIO
import os

private enum MarkdownPreviewScrollViewResolver {
    static func resolve(for view: NSView) -> NSScrollView? {
        if let sv = view as? NSScrollView { return sv }
        if let sv = view.enclosingScrollView { return sv }
        return findFirstScrollView(in: view)
    }

    private static func findFirstScrollView(in view: NSView) -> NSScrollView? {
        for subview in view.subviews {
            if let sv = subview as? NSScrollView { return sv }
            if let found = findFirstScrollView(in: subview) { return found }
        }
        return nil
    }
}

@MainActor
final class MarkdownExportRenderer: NSObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Scopy",
        category: "ui"
    )

    private enum RenderConstants {
        // Prefer tiling for very tall pages; a single huge WKWebView snapshot may return blank/partial images.
        static let maxSingleSnapshotHeightPoints: CGFloat = 20_000
        static let tileViewportHeightPoints: CGFloat = 1000
        static let tileOverlapPoints: CGFloat = 1

        // Safety guard for stitched images (RGBA 8-bit => ~4 bytes/pixel).
        static let maxTotalPixels: Int = 60_000_000
    }

    enum ExportError: Error {
        case navigationFailed
        case notReady
        case invalidMetrics
        case snapshotFailed
        case imageDecodeFailed
        case imageEncodeFailed
    }

    private let webView: WKWebView
    private var navigationContinuation: CheckedContinuation<Void, Error>?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController = WKUserContentController()
        MarkdownPreviewWebView.installNetworkBlocker(into: config.userContentController)

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsMagnification = false
        wv.setValue(false, forKey: "drawsBackground")
        self.webView = wv
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    deinit {
        let webView = webView
        Task { @MainActor in
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }
    }

    func renderPNG(
        html: String,
        containerWidthPoints: CGFloat,
        maxShortSidePixels: Int = 1500,
        maxLongSidePixels: Int = 16_384 * 4
    ) async throws -> Data {
        guard !html.isEmpty else { throw ExportError.notReady }

        // Prepare an offscreen web view with the same width as the preview container. Height will be expanded after layout.
        webView.frame = CGRect(x: 0, y: 0, width: max(1, containerWidthPoints), height: 800)

        try await loadHTML(html)

        // Export-only light appearance + robust "ready" waits.
        let exportHookReady = try await waitForJavaScriptCondition(
            "typeof window.__scopySetExportMode === 'function'",
            maxAttempts: 80,
            sleepNanoseconds: 25_000_000
        )
        guard exportHookReady else { throw ExportError.notReady }

        await evaluateJavaScriptIgnoringResult("window.__scopySetExportMode(true)")
        let exportModeEnabled = try await waitForJavaScriptCondition(
            "document && document.documentElement && document.documentElement.classList && document.documentElement.classList.contains('scopy-export-light')",
            maxAttempts: 80,
            sleepNanoseconds: 25_000_000
        )
        guard exportModeEnabled else { throw ExportError.notReady }

        // Wait for markdown-it to render. Without this, snapshotting can capture an empty/blank content area.
        let rendered = try await waitForJavaScriptCondition(
            "typeof window.__scopyMarkdownRendered === 'boolean' && window.__scopyMarkdownRendered === true",
            maxAttempts: 240,
            sleepNanoseconds: 50_000_000
        )
        guard rendered else { throw ExportError.notReady }

        // Ensure export-mode CSS has actually applied (avoid capturing while #content opacity is still 0).
        let contentVisible = try await waitForJavaScriptCondition(
            "(function(){ try { var el=document.getElementById('content'); if(!el) return false; var o=parseFloat((getComputedStyle(el).opacity||'0')); return o>=0.99; } catch(e){ return false; } })()",
            maxAttempts: 80,
            sleepNanoseconds: 25_000_000
        )
        guard contentVisible else { throw ExportError.notReady }

        // Best-effort math render + wait for first successful KaTeX render (if any).
        await evaluateJavaScriptIgnoringResult("typeof window.__scopyRenderMath === 'function' && window.__scopyRenderMath()")
        let hasMath = (try? await evaluateJavaScript("typeof window.__scopyHasMath === 'boolean' && window.__scopyHasMath === true")) as? Bool ?? false
        if hasMath {
            _ = try? await waitForJavaScriptCondition(
                "typeof window.__scopyMathRendered === 'boolean' && window.__scopyMathRendered === true",
                maxAttempts: 240,
                sleepNanoseconds: 50_000_000
            )
        }

        // Fit tables to export width (robust: avoid `zoom`, use wrapper+transform).
        await evaluateJavaScriptIgnoringResult("typeof window.__scopyFitTablesForExport === 'function' && window.__scopyFitTablesForExport()")
        _ = try? await waitForJavaScriptCondition(
            "typeof window.__scopyTablesFitDone === 'boolean' && window.__scopyTablesFitDone === true",
            maxAttempts: 120,
            sleepNanoseconds: 50_000_000
        )

        let metrics = try await waitForStableContentMetrics(maxAttempts: 16, sleepNanoseconds: 60_000_000)
        webView.frame = CGRect(x: 0, y: 0, width: max(1, metrics.width), height: max(1, metrics.height))

        // Resizing can change table layout slightly; re-fit tables and re-measure once to avoid 1px clipping.
        await evaluateJavaScriptIgnoringResult("typeof window.__scopyFitTablesForExport === 'function' && window.__scopyFitTablesForExport()")
        _ = try? await waitForJavaScriptCondition(
            "typeof window.__scopyTablesFitDone === 'boolean' && window.__scopyTablesFitDone === true",
            maxAttempts: 120,
            sleepNanoseconds: 50_000_000
        )
        let metrics2 = try await waitForStableContentMetrics(maxAttempts: 16, sleepNanoseconds: 60_000_000)
        let finalWidth = max(1, metrics2.width)
        let finalHeight = max(1, metrics2.height)
        webView.frame = CGRect(x: 0, y: 0, width: finalWidth, height: finalHeight)

        let snapshotTarget = Self.computeSnapshotPixelSize(
            contentWidthPoints: finalWidth,
            contentHeightPoints: finalHeight,
            maxShortSidePixels: maxShortSidePixels,
            maxLongSidePixels: maxLongSidePixels
        )
        let snapshotWidthPoints = CGFloat(max(1, snapshotTarget.width))

        if finalHeight <= RenderConstants.maxSingleSnapshotHeightPoints {
            do {
                let image = try await takeSnapshot(
                    size: CGSize(width: finalWidth, height: finalHeight),
                    snapshotWidthPoints: snapshotWidthPoints
                )
                var rect = CGRect(origin: .zero, size: image.size)
                guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                    throw ExportError.imageEncodeFailed
                }
                let trimmed = Self.trimBottomWhitespaceIfNeeded(cgImage: cgImage)
                return try await encodePNG(
                    cgImage: trimmed,
                    maxShortSidePixels: maxShortSidePixels,
                    maxLongSidePixels: maxLongSidePixels
                )
            } catch {
                // Fall back to tiled rendering for robustness.
                Self.logger.warning("Export snapshot failed; falling back to tiled render. error=\(String(describing: error), privacy: .private)")
            }
        }

        let stitched = try await renderTiledCGImage(
            contentWidthPoints: finalWidth,
            contentHeightPoints: finalHeight,
            snapshotWidthPoints: snapshotWidthPoints
        )
        return try await encodePNG(
            cgImage: stitched,
            maxShortSidePixels: maxShortSidePixels,
            maxLongSidePixels: maxLongSidePixels
        )
    }

#if DEBUG
    func debugEvaluateJavaScript(_ js: String) async throws -> Any {
        try await evaluateJavaScript(js)
    }
#endif

    // MARK: - Loading / Measuring

    private func loadHTML(_ html: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationContinuation?.resume(throwing: ExportError.navigationFailed)
            navigationContinuation = continuation
            let baseURL = Bundle.main.resourceURL?.appendingPathComponent("MarkdownPreview", isDirectory: true)
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    private struct ContentMetrics: Equatable {
        let width: CGFloat
        let height: CGFloat
    }

    private func waitForStableContentMetrics(maxAttempts: Int, sleepNanoseconds: UInt64) async throws -> ContentMetrics {
        var last: ContentMetrics?
        var stableCount = 0

        for _ in 0..<maxAttempts {
            let current = try await measureContentMetrics()
            if current.width <= 0 || current.height <= 0 { throw ExportError.invalidMetrics }

            if let last,
               abs(current.width - last.width) < 1,
               abs(current.height - last.height) < 1
            {
                stableCount += 1
                if stableCount >= 2 { return current }
            } else {
                stableCount = 0
            }
            last = current
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
        }

        return last ?? ContentMetrics(width: webView.bounds.width, height: webView.bounds.height)
    }

    private func measureContentMetrics() async throws -> ContentMetrics {
        let js = """
        (function () {
          try {
            var el = document.getElementById('content');
            if (!el) { return null; }
            var rect = el.getBoundingClientRect();
            var w = Math.ceil(rect.width || 0);
            var sh = Math.ceil(el.scrollHeight || 0);
            var h = Math.ceil(Math.max(rect.height || 0, sh));
            return { width: w, height: h };
          } catch (e) { return null; }
        })();
        """

        let value = try await evaluateJavaScript(js)
        if let dict = value as? [String: Any] {
            let w = MarkdownPreviewWebView.Coordinator.cgFloat(from: dict["width"])
            let h = MarkdownPreviewWebView.Coordinator.cgFloat(from: dict["height"])
            return ContentMetrics(width: w, height: h)
        }
        if let dict = value as? NSDictionary {
            let w = MarkdownPreviewWebView.Coordinator.cgFloat(from: dict["width"])
            let h = MarkdownPreviewWebView.Coordinator.cgFloat(from: dict["height"])
            return ContentMetrics(width: w, height: h)
        }
        throw ExportError.invalidMetrics
    }

    private func evaluateJavaScriptIgnoringResult(_ js: String) async {
        _ = try? await evaluateJavaScript(js)
    }

    private func evaluateJavaScript(_ js: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(js) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: value ?? NSNull())
            }
        }
    }

    private func waitForJavaScriptCondition(
        _ jsCondition: String,
        maxAttempts: Int,
        sleepNanoseconds: UInt64
    ) async throws -> Bool {
        for _ in 0..<maxAttempts {
            let value = try? await evaluateJavaScript("(function(){ try { return !!(\(jsCondition)); } catch (e) { return false; } })();")
            if let b = value as? Bool, b { return true }
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
        }
        return false
    }

    // MARK: - Snapshot / Encoding

    private func takeSnapshot(size: CGSize, snapshotWidthPoints: CGFloat) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(origin: .zero, size: size)
            config.snapshotWidth = NSNumber(value: Double(max(1, snapshotWidthPoints)))
            if #available(macOS 10.15, *) {
                config.afterScreenUpdates = true
            }

            webView.takeSnapshot(with: config) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let image else {
                    continuation.resume(throwing: ExportError.snapshotFailed)
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    private func encodePNG(image: NSImage, maxShortSidePixels: Int, maxLongSidePixels: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .utility) {
                do {
                    var rect = CGRect(origin: .zero, size: image.size)
                    guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                        throw ExportError.imageEncodeFailed
                    }
                    let scaledCGImage = try Self.scaleDownIfNeeded(
                        cgImage: cgImage,
                        maxShortSidePixels: maxShortSidePixels,
                        maxLongSidePixels: maxLongSidePixels
                    )
                    let out = NSMutableData()
                    guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
                        throw ExportError.imageEncodeFailed
                    }
                    CGImageDestinationAddImage(dest, scaledCGImage, nil)
                    guard CGImageDestinationFinalize(dest) else {
                        throw ExportError.imageEncodeFailed
                    }
                    continuation.resume(returning: out as Data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func encodePNG(cgImage: CGImage, maxShortSidePixels: Int, maxLongSidePixels: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .utility) {
                do {
                    let scaledCGImage = try Self.scaleDownIfNeeded(
                        cgImage: cgImage,
                        maxShortSidePixels: maxShortSidePixels,
                        maxLongSidePixels: maxLongSidePixels
                    )
                    let out = NSMutableData()
                    guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
                        throw ExportError.imageEncodeFailed
                    }
                    CGImageDestinationAddImage(dest, scaledCGImage, nil)
                    guard CGImageDestinationFinalize(dest) else {
                        throw ExportError.imageEncodeFailed
                    }
                    continuation.resume(returning: out as Data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func renderTiledCGImage(
        contentWidthPoints: CGFloat,
        contentHeightPoints: CGFloat,
        snapshotWidthPoints: CGFloat
    ) async throws -> CGImage {
        let viewportHeightPoints = max(1, min(RenderConstants.tileViewportHeightPoints, contentHeightPoints))
        webView.frame = CGRect(x: 0, y: 0, width: max(1, contentWidthPoints), height: viewportHeightPoints)

        var outputWidthPixels: Int?
        var outputHeightPixels: Int?
        var effectiveScale: Double?
        var context: CGContext?
        var bytesPerRow: Int = 0

        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        func ensureContextIfNeeded(from tile: CGImage, tileHeightPoints: CGFloat) throws {
            if context != nil { return }

            let rawScaleX = Double(tile.width) / Double(max(1, contentWidthPoints))
            var outW = max(1, tile.width)
            var outH = max(1, Int((Double(contentHeightPoints) * rawScaleX).rounded()))
            var scale = rawScaleX

            let totalPixels = outW * outH
            if totalPixels > RenderConstants.maxTotalPixels {
                let down = sqrt(Double(RenderConstants.maxTotalPixels) / Double(max(1, totalPixels)))
                scale = rawScaleX * down
                outW = max(1, Int((Double(outW) * down).rounded()))
                outH = max(1, Int((Double(outH) * down).rounded()))
            }

            outputWidthPixels = outW
            outputHeightPixels = outH
            effectiveScale = scale

            bytesPerRow = outW * 4
            guard let ctx = CGContext(
                data: nil,
                width: outW,
                height: outH,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: cs,
                bitmapInfo: bitmapInfo
            ) else {
                throw ExportError.imageEncodeFailed
            }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(outW), height: CGFloat(outH)))
            context = ctx
        }

        func cgImage(from image: NSImage) throws -> CGImage {
            var rect = CGRect(origin: .zero, size: image.size)
            guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                throw ExportError.imageDecodeFailed
            }
            return cgImage
        }

        func scaleToOutputWidthIfNeeded(_ image: CGImage, targetWidth: Int) throws -> CGImage {
            let srcW = image.width
            let srcH = image.height
            guard srcW > 0, srcH > 0 else { throw ExportError.imageDecodeFailed }
            if srcW == targetWidth { return image }

            let scale = Double(targetWidth) / Double(srcW)
            let targetHeight = max(1, Int((Double(srcH) * scale).rounded()))
            guard let ctx = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: cs,
                bitmapInfo: bitmapInfo
            ) else {
                throw ExportError.imageEncodeFailed
            }
            ctx.interpolationQuality = .high
            ctx.setShouldAntialias(true)
            ctx.setAllowsAntialiasing(true)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            guard let scaled = ctx.makeImage() else { throw ExportError.imageEncodeFailed }
            return scaled
        }

        var scrollYPoints: CGFloat = 0
        let overlap = max(0, RenderConstants.tileOverlapPoints)
        while scrollYPoints < contentHeightPoints {
            let remaining = contentHeightPoints - scrollYPoints
            let captureHeightPoints = max(1, min(viewportHeightPoints, remaining))

            try await scrollTo(yPoints: scrollYPoints)

            let image = try await takeSnapshot(
                size: CGSize(width: max(1, contentWidthPoints), height: captureHeightPoints),
                snapshotWidthPoints: snapshotWidthPoints
            )
            let tileCG = try cgImage(from: image)

            try ensureContextIfNeeded(from: tileCG, tileHeightPoints: captureHeightPoints)
            guard let outW = outputWidthPixels, let outH = outputHeightPixels, let scale = effectiveScale, let ctx = context else {
                throw ExportError.imageEncodeFailed
            }

            let normalizedTile = try scaleToOutputWidthIfNeeded(tileCG, targetWidth: outW)

            let bottomYPoints = contentHeightPoints - (scrollYPoints + captureHeightPoints)
            var drawY = Int((Double(bottomYPoints) * scale).rounded())
            if drawY < 0 { drawY = 0 }
            if drawY + normalizedTile.height > outH {
                drawY = max(0, outH - normalizedTile.height)
            }

            ctx.draw(
                normalizedTile,
                in: CGRect(
                    x: 0,
                    y: CGFloat(drawY),
                    width: CGFloat(outW),
                    height: CGFloat(normalizedTile.height)
                )
            )

            if remaining <= viewportHeightPoints { break }
            scrollYPoints += max(1, viewportHeightPoints - overlap)
        }

        guard let out = context?.makeImage() else { throw ExportError.imageEncodeFailed }
        guard let ctxData = context?.data, bytesPerRow > 0 else { return out }
        return Self.trimBottomWhitespaceIfNeeded(image: out, contextData: ctxData, bytesPerRow: bytesPerRow)
    }

    private func scrollTo(yPoints: CGFloat) async throws {
        let y = Double(max(0, yPoints))
        _ = try await evaluateJavaScript("(function(){ try { window.scrollTo(0, \(y)); } catch (e) { } return true; })();")
        // Give WebKit a moment to paint after programmatic scroll.
        try? await Task.sleep(nanoseconds: 70_000_000)
    }

    nonisolated private static func trimBottomWhitespaceIfNeeded(
        image: CGImage,
        contextData: UnsafeMutableRawPointer,
        bytesPerRow: Int
    ) -> CGImage {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return image }
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
            return darkCount <= max(6, sampleCount / 180)
        }

        // Notes:
        // - `context.data` is laid out top-to-bottom (row 0 is the top scanline),
        //   and `CGImage.cropping(to:)` uses an origin at top-left.
        // - To trim *bottom* whitespace, we scan from bottom (h-1) upwards.
        var lastContentRowYFromTop: Int?
        for y in stride(from: h - 1, through: 0, by: -1) {
            if !rowIsMostlyWhite(y) {
                lastContentRowYFromTop = y
                break
            }
        }
        guard let lastContentRowYFromTop else { return image }

        let bottomMargin = min(40, max(0, h - 1))
        let desiredHeight = min(h, lastContentRowYFromTop + 1 + bottomMargin)
        if desiredHeight >= h { return image }
        if desiredHeight <= 0 { return image }

        let rect = CGRect(x: 0, y: 0, width: w, height: desiredHeight)
        return image.cropping(to: rect) ?? image
    }

    nonisolated private static func trimBottomWhitespaceIfNeeded(cgImage: CGImage) -> CGImage {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return cgImage }

        let cs = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = w * 4
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return cgImage
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        guard let outImage = ctx.makeImage(), let data = ctx.data else { return cgImage }
        return trimBottomWhitespaceIfNeeded(image: outImage, contextData: data, bytesPerRow: bytesPerRow)
    }

    nonisolated static func computeScaledPixelSize(
        srcWidth: Int,
        srcHeight: Int,
        shortSidePixels: Int,
        maxLongSidePixels: Int
    ) -> (width: Int, height: Int, shortSide: Int) {
        let srcW = max(1, srcWidth)
        let srcH = max(1, srcHeight)
        let srcShort = min(srcW, srcH)
        let srcLong = max(srcW, srcH)

        var scale = Double(shortSidePixels) / Double(srcShort)
        var dstLong = Int((Double(srcLong) * scale).rounded())
        if dstLong > maxLongSidePixels {
            scale = Double(maxLongSidePixels) / Double(srcLong)
            dstLong = maxLongSidePixels
        }

        let dstW = max(1, Int((Double(srcW) * scale).rounded()))
        let dstH = max(1, Int((Double(srcH) * scale).rounded()))
        return (width: dstW, height: dstH, shortSide: min(dstW, dstH))
    }

    nonisolated static func computeDownscaledPixelSizeIfNeeded(
        srcWidth: Int,
        srcHeight: Int,
        maxShortSidePixels: Int,
        maxLongSidePixels: Int
    ) -> (width: Int, height: Int, shortSide: Int) {
        let srcW = max(1, srcWidth)
        let srcH = max(1, srcHeight)
        let srcShort = min(srcW, srcH)
        let desiredShort = min(max(1, maxShortSidePixels), srcShort)
        return computeScaledPixelSize(
            srcWidth: srcW,
            srcHeight: srcH,
            shortSidePixels: desiredShort,
            maxLongSidePixels: maxLongSidePixels
        )
    }

    nonisolated static func computeSnapshotPixelSize(
        contentWidthPoints: CGFloat,
        contentHeightPoints: CGFloat,
        maxShortSidePixels: Int,
        maxLongSidePixels: Int
    ) -> (width: Int, height: Int, shortSide: Int) {
        let baseW = max(1, Int(contentWidthPoints.rounded(.up)))
        let baseH = max(1, Int(contentHeightPoints.rounded(.up)))
        let baseShort = min(baseW, baseH)
        let oversampleShort = min(baseShort * 2, maxShortSidePixels * 2)
        let target = computeScaledPixelSize(
            srcWidth: baseW,
            srcHeight: baseH,
            shortSidePixels: max(1, oversampleShort),
            maxLongSidePixels: maxLongSidePixels
        )

        let totalPixels = target.width * target.height
        if totalPixels <= RenderConstants.maxTotalPixels {
            return target
        }

        let down = sqrt(Double(RenderConstants.maxTotalPixels) / Double(max(1, totalPixels)))
        let w = max(1, Int((Double(target.width) * down).rounded()))
        let h = max(1, Int((Double(target.height) * down).rounded()))
        return (width: w, height: h, shortSide: min(w, h))
    }

    nonisolated private static func scaleDownIfNeeded(
        cgImage: CGImage,
        maxShortSidePixels: Int,
        maxLongSidePixels: Int
    ) throws -> CGImage {
        let srcW = cgImage.width
        let srcH = cgImage.height
        guard srcW > 0, srcH > 0 else { throw ExportError.imageDecodeFailed }

        let target = computeDownscaledPixelSizeIfNeeded(
            srcWidth: srcW,
            srcHeight: srcH,
            maxShortSidePixels: maxShortSidePixels,
            maxLongSidePixels: maxLongSidePixels
        )
        if target.width == srcW && target.height == srcH {
            return cgImage
        }

        guard let context = CGContext(
            data: nil,
            width: target.width,
            height: target.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ExportError.imageEncodeFailed
        }
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        guard let scaled = context.makeImage() else { throw ExportError.imageEncodeFailed }
        return scaled
    }
}

extension MarkdownExportRenderer: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.navigationType == .linkActivated {
            decisionHandler(.cancel)
            return
        }
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https"
        {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }
}

struct MarkdownContentMetrics: Equatable {
    let size: CGSize
    let hasHorizontalOverflow: Bool
}

struct MarkdownPreviewWebView: NSViewRepresentable {
    let html: String
    let shouldScroll: Bool
    let onContentSizeChange: @MainActor (MarkdownContentMetrics) -> Void

    private static let blockNetworkRuleListIdentifier = "ScopyMarkdownPreviewBlockNetwork"
    fileprivate static let sizeMessageHandlerName = "scopySize"
    private static let blockNetworkRulesJSON = """
    [
      {
        "trigger": { "url-filter": "https?://.*" },
        "action": { "type": "block" }
      }
    ]
    """
    private static var cachedBlockNetworkRuleList: WKContentRuleList?
    private static var isCompilingRuleList: Bool = false
    private static let ruleListLock = NSLock()
    private static let pendingControllers = NSHashTable<WKUserContentController>.weakObjects()

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController = WKUserContentController()

        Self.installNetworkBlocker(into: config.userContentController)
        config.userContentController.add(context.coordinator.sizeMessageHandlerProxy, name: Self.sizeMessageHandlerName)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        configureScrollers(for: webView, shouldScroll: shouldScroll)
        context.coordinator.attachScrollbarAutoHiderIfPossible(for: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onContentSizeChange = onContentSizeChange
        configureScrollers(for: webView, shouldScroll: shouldScroll)
        context.coordinator.attachScrollbarAutoHiderIfPossible(for: webView)

        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            let baseURL = Bundle.main.resourceURL?.appendingPathComponent("MarkdownPreview", isDirectory: true)
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: Self.sizeMessageHandlerName)
        coordinator.scrollbarAutoHider.detach()
    }

    private func configureScrollers(for webView: WKWebView, shouldScroll: Bool) {
        guard let scrollView = MarkdownPreviewScrollViewResolver.resolve(for: webView) else { return }
        scrollView.hasVerticalScroller = shouldScroll
        // Keep the outer horizontal scroller disabled. Horizontal overflow is handled inside HTML (e.g. KaTeX/code)
        // so we don't show a persistent bottom bar under the system "always show scroll bars" setting.
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
    }

    fileprivate static func installNetworkBlocker(into controller: WKUserContentController) {
        ruleListLock.lock()
        if let cached = cachedBlockNetworkRuleList {
            ruleListLock.unlock()
            controller.add(cached)
            return
        }
        pendingControllers.add(controller)
        if isCompilingRuleList {
            ruleListLock.unlock()
            return
        }
        isCompilingRuleList = true
        ruleListLock.unlock()

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: blockNetworkRuleListIdentifier,
            encodedContentRuleList: blockNetworkRulesJSON
        ) { ruleList, _ in
            ruleListLock.lock()
            isCompilingRuleList = false
            if let ruleList {
                cachedBlockNetworkRuleList = ruleList
            }
            ruleListLock.unlock()

            guard let ruleList else { return }
            DispatchQueue.main.async {
                for pending in pendingControllers.allObjects {
                    pending.add(ruleList)
                }
            }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var lastHTML: String = ""
        var onContentSizeChange: (@MainActor (MarkdownContentMetrics) -> Void)?
        private var lastReportedMetrics: MarkdownContentMetrics = MarkdownContentMetrics(size: .zero, hasHorizontalOverflow: false)
        let scrollbarAutoHider = ScrollbarAutoHider()
        let sizeMessageHandlerProxy = WeakScriptMessageHandler()

        override init() {
            super.init()
            sizeMessageHandlerProxy.delegate = self
        }

        func attachScrollbarAutoHiderIfPossible(for webView: WKWebView) {
            if let scrollView = MarkdownPreviewScrollViewResolver.resolve(for: webView) {
                scrollbarAutoHider.attach(to: scrollView)
                scrollbarAutoHider.applyHiddenState()
                DispatchQueue.main.async { [weak scrollbarAutoHider] in
                    scrollbarAutoHider?.applyHiddenState()
                }
            } else {
                DispatchQueue.main.async { [weak self, weak webView] in
                    guard let self, let webView else { return }
                    if let scrollView = MarkdownPreviewScrollViewResolver.resolve(for: webView) {
                        self.scrollbarAutoHider.attach(to: scrollView)
                        self.scrollbarAutoHider.applyHiddenState()
                        DispatchQueue.main.async { [weak scrollbarAutoHider = self.scrollbarAutoHider] in
                            scrollbarAutoHider?.applyHiddenState()
                        }
                    }
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.targetFrame == nil {
                decisionHandler(.cancel)
                return
            }
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
                return
            }

            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https"
            {
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Best-effort: ensure math render runs even if DOMContentLoaded timing varies.
            attachScrollbarAutoHiderIfPossible(for: webView)
            webView.evaluateJavaScript("typeof window.__scopyRenderMath === 'function'") { result, _ in
                guard let ok = result as? Bool, ok else { return }
                webView.evaluateJavaScript("window.__scopyRenderMath()") { _, _ in }
            }
            webView.evaluateJavaScript("typeof window.__scopyReportHeight === 'function'") { result, _ in
                guard let ok = result as? Bool, ok else { return }
                webView.evaluateJavaScript("window.__scopyReportHeight()") { _, _ in }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == MarkdownPreviewWebView.sizeMessageHandlerName else { return }

            var size: CGSize?
            var overflowX: Bool = false
            if let dict = message.body as? [String: Any] {
                let w = dict["width"]
                let h = dict["height"]
                size = CGSize(width: Self.cgFloat(from: w), height: Self.cgFloat(from: h))
                if let b = dict["overflowX"] as? Bool {
                    overflowX = b
                } else if let n = dict["overflowX"] as? NSNumber {
                    overflowX = n.boolValue
                } else if let s = dict["overflowX"] as? String {
                    overflowX = (s == "true" || s == "1")
                }
            } else if let dict = message.body as? NSDictionary {
                let w = dict["width"]
                let h = dict["height"]
                size = CGSize(width: Self.cgFloat(from: w), height: Self.cgFloat(from: h))
                if let b = dict["overflowX"] as? Bool {
                    overflowX = b
                } else if let n = dict["overflowX"] as? NSNumber {
                    overflowX = n.boolValue
                } else if let s = dict["overflowX"] as? String {
                    overflowX = (s == "true" || s == "1")
                }
            } else if let n = message.body as? NSNumber {
                // Backward-compatible: height-only payload.
                size = CGSize(width: 0, height: CGFloat(truncating: n))
            }

            guard let size else { return }
            guard size.width.isFinite, size.height.isFinite else { return }
            guard size.height > 0 else { return }

            let metrics = MarkdownContentMetrics(size: size, hasHorizontalOverflow: overflowX)
            if abs(metrics.size.width - lastReportedMetrics.size.width) < 1,
               abs(metrics.size.height - lastReportedMetrics.size.height) < 1,
               metrics.hasHorizontalOverflow == lastReportedMetrics.hasHorizontalOverflow
            {
                return
            }
            lastReportedMetrics = metrics

            if let wk = message.webView {
                attachScrollbarAutoHiderIfPossible(for: wk)
            }
            Task { @MainActor in
                self.onContentSizeChange?(metrics)
            }
        }

        fileprivate static func cgFloat(from any: Any?) -> CGFloat {
            if let n = any as? NSNumber {
                return CGFloat(truncating: n)
            }
            if let d = any as? Double {
                return CGFloat(d)
            }
            if let i = any as? Int {
                return CGFloat(i)
            }
            if let s = any as? String, let d = Double(s) {
                return CGFloat(d)
            }
            return 0
        }
    }
}

@MainActor
final class MarkdownPreviewWebViewController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    enum ExportSnapshotError: Error {
        case notReady
        case invalidBounds
        case snapshotFailed
        case tiffEncodingFailed
    }

    let webView: WKWebView

    var onContentSizeChange: (@MainActor (MarkdownContentMetrics) -> Void)?
    private var lastHTML: String = ""
    private var isContentLoaded: Bool = false
    private var lastReportedMetrics: MarkdownContentMetrics = MarkdownContentMetrics(size: .zero, hasHorizontalOverflow: false)
    private let scrollbarAutoHider = ScrollbarAutoHider()
    private let sizeMessageHandlerProxy = WeakScriptMessageHandler()

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController = WKUserContentController()

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsMagnification = false
        wv.setValue(false, forKey: "drawsBackground")
        self.webView = wv
        super.init()

        // Reuse the same network blocker & message handler semantics as the one-shot web view.
        MarkdownPreviewWebView.installNetworkBlocker(into: config.userContentController)
        sizeMessageHandlerProxy.delegate = self
        config.userContentController.add(sizeMessageHandlerProxy, name: MarkdownPreviewWebView.sizeMessageHandlerName)

        attachWebViewIfNeeded()
    }

    func attachWebViewIfNeeded() {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: MarkdownPreviewWebView.sizeMessageHandlerName)
        controller.add(sizeMessageHandlerProxy, name: MarkdownPreviewWebView.sizeMessageHandlerName)

        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func detachWebView() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: MarkdownPreviewWebView.sizeMessageHandlerName)
        scrollbarAutoHider.detach()
    }

    func setShouldScroll(_ shouldScroll: Bool) {
        attachWebViewIfNeeded()
        guard let scrollView = MarkdownPreviewScrollViewResolver.resolve(for: webView) else { return }
        scrollView.hasVerticalScroller = shouldScroll
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollbarAutoHider.attach(to: scrollView)
        scrollbarAutoHider.applyHiddenState()
        DispatchQueue.main.async { [weak scrollbarAutoHider] in
            scrollbarAutoHider?.applyHiddenState()
        }
    }

    func loadHTMLIfNeeded(_ html: String) {
        attachWebViewIfNeeded()
        if lastHTML == html { return }
        lastHTML = html
        isContentLoaded = false
        lastReportedMetrics = MarkdownContentMetrics(size: .zero, hasHorizontalOverflow: false)
        let baseURL = Bundle.main.resourceURL?.appendingPathComponent("MarkdownPreview", isDirectory: true)
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    // MARK: - Export Snapshot (Copy as Image)

    func makeLightSnapshotPNGForClipboard() async throws -> Data {
        guard !lastHTML.isEmpty, isContentLoaded else { throw ExportSnapshotError.notReady }

        let rect = webView.bounds
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 1, rect.height > 1 else {
            throw ExportSnapshotError.invalidBounds
        }

        // Best-effort: toggle export-only light appearance. This is scoped to snapshotting only.
        await evaluateJavaScriptIgnoringResult(Self.exportModeToggleJS(enabled: true))
        defer {
            webView.evaluateJavaScript(Self.exportModeToggleJS(enabled: false)) { _, _ in }
        }

        let image = try await takeSnapshot(rect: rect)
        guard let tiff = image.tiffRepresentation else { throw ExportSnapshotError.tiffEncodingFailed }

        // Encode PNG off the main thread (snapshot is UI-bound, encoding is pure data processing).
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .utility) {
                do {
                    let png = try Self.convertTIFFDataToPNG(tiff)
                    continuation.resume(returning: png)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func exportModeToggleJS(enabled: Bool) -> String {
        let flag = enabled ? "true" : "false"
        return """
        (function () {
          try {
            if (typeof window.__scopySetExportMode === 'function') {
              window.__scopySetExportMode(\(flag));
              return true;
            }
            var root = document.documentElement;
            if (!root) { return false; }
            if (\(flag)) {
              root.classList.add('scopy-export-light');
              root.classList.remove('scopy-scrollbars-visible');
            } else {
              root.classList.remove('scopy-export-light');
            }
            return true;
          } catch (e) { return false; }
        })();
        """
    }

    private func evaluateJavaScriptIgnoringResult(_ js: String) async {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(js) { _, _ in
                continuation.resume()
            }
        }
    }

    private func takeSnapshot(rect: CGRect) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            let config = WKSnapshotConfiguration()
            config.rect = rect
            config.snapshotWidth = NSNumber(value: Double(max(1, rect.width)))
            if #available(macOS 10.15, *) {
                config.afterScreenUpdates = true
            }

            webView.takeSnapshot(with: config) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let image else {
                    continuation.resume(throwing: ExportSnapshotError.snapshotFailed)
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    nonisolated private static func convertTIFFDataToPNG(_ tiffData: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(tiffData as CFData, nil) else {
            throw ExportSnapshotError.snapshotFailed
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ExportSnapshotError.snapshotFailed
        }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportSnapshotError.snapshotFailed
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ExportSnapshotError.snapshotFailed
        }
        return out as Data
    }

    // MARK: - WKNavigationDelegate / WKUIDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.navigationType == .linkActivated {
            decisionHandler(.cancel)
            return
        }

        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https"
        {
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isContentLoaded = true
        // Best-effort: ensure math render runs even if DOMContentLoaded timing varies.
        webView.evaluateJavaScript("typeof window.__scopyRenderMath === 'function'") { result, _ in
            guard let ok = result as? Bool, ok else { return }
            webView.evaluateJavaScript("window.__scopyRenderMath()") { _, _ in }
        }
        webView.evaluateJavaScript("typeof window.__scopyReportHeight === 'function'") { result, _ in
            guard let ok = result as? Bool, ok else { return }
            webView.evaluateJavaScript("window.__scopyReportHeight()") { _, _ in }
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "scopySize" else { return }

        var size: CGSize?
        var overflowX: Bool = false
        if let dict = message.body as? [String: Any] {
            let w = dict["width"]
            let h = dict["height"]
            size = CGSize(width: Self.cgFloat(from: w), height: Self.cgFloat(from: h))
            if let b = dict["overflowX"] as? Bool {
                overflowX = b
            } else if let n = dict["overflowX"] as? NSNumber {
                overflowX = n.boolValue
            } else if let s = dict["overflowX"] as? String {
                overflowX = (s == "true" || s == "1")
            }
        } else if let dict = message.body as? NSDictionary {
            let w = dict["width"]
            let h = dict["height"]
            size = CGSize(width: Self.cgFloat(from: w), height: Self.cgFloat(from: h))
            if let b = dict["overflowX"] as? Bool {
                overflowX = b
            } else if let n = dict["overflowX"] as? NSNumber {
                overflowX = n.boolValue
            } else if let s = dict["overflowX"] as? String {
                overflowX = (s == "true" || s == "1")
            }
        } else if let n = message.body as? NSNumber {
            size = CGSize(width: 0, height: CGFloat(truncating: n))
        }

        guard let size else { return }
        guard size.width.isFinite, size.height.isFinite else { return }
        guard size.height > 0 else { return }

        let metrics = MarkdownContentMetrics(size: size, hasHorizontalOverflow: overflowX)
        if abs(metrics.size.width - lastReportedMetrics.size.width) < 1,
           abs(metrics.size.height - lastReportedMetrics.size.height) < 1,
           metrics.hasHorizontalOverflow == lastReportedMetrics.hasHorizontalOverflow
        {
            return
        }
        lastReportedMetrics = metrics

        if let scrollView = MarkdownPreviewScrollViewResolver.resolve(for: webView) {
            scrollbarAutoHider.attach(to: scrollView)
            scrollbarAutoHider.applyHiddenState()
            DispatchQueue.main.async { [weak scrollbarAutoHider] in
                scrollbarAutoHider?.applyHiddenState()
            }
        }
        Task { @MainActor in
            self.onContentSizeChange?(metrics)
        }
    }

    private static func cgFloat(from any: Any?) -> CGFloat {
        if let n = any as? NSNumber {
            return CGFloat(truncating: n)
        }
        if let d = any as? Double {
            return CGFloat(d)
        }
        if let i = any as? Int {
            return CGFloat(i)
        }
        if let s = any as? String, let d = Double(s) {
            return CGFloat(d)
        }
        return 0
    }
}

struct ReusableMarkdownPreviewWebView: NSViewRepresentable {
    @ObservedObject var controller: MarkdownPreviewWebViewController
    let html: String
    let shouldScroll: Bool
    let onContentSizeChange: @MainActor (MarkdownContentMetrics) -> Void

    func makeNSView(context: Context) -> WKWebView {
        controller.attachWebViewIfNeeded()
        return controller.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        controller.attachWebViewIfNeeded()
        controller.onContentSizeChange = onContentSizeChange
        controller.setShouldScroll(shouldScroll)
        controller.loadHTMLIfNeeded(html)
    }

    @MainActor
    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) {
        // Ensure the controller does not keep WebKit delegates/handlers alive when the view is removed.
        if let controller = (nsView.navigationDelegate as? MarkdownPreviewWebViewController) {
            controller.detachWebView()
        } else {
            nsView.stopLoading()
            nsView.navigationDelegate = nil
            nsView.uiDelegate = nil
            nsView.configuration.userContentController.removeScriptMessageHandler(forName: MarkdownPreviewWebView.sizeMessageHandlerName)
        }
    }
}

/// Ensures scrollbars stay hidden when idle and only appear while scrolling.
/// This intentionally overrides the system "always show scroll bars" preference for hover-preview surfaces.
final class ScrollbarAutoHider: NSObject {
    private weak var scrollView: NSScrollView?
    private weak var contentView: NSClipView?
    private var hideWorkItem: DispatchWorkItem?

    func attach(to scrollView: NSScrollView) {
        if self.scrollView === scrollView { return }
        detach()
        self.scrollView = scrollView
        self.contentView = scrollView.contentView
        scrollView.contentView.postsBoundsChangedNotifications = true

        if let contentView = scrollView.contentView as NSClipView? {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAnyScroll(_:)),
                name: NSView.boundsDidChangeNotification,
                object: contentView
            )
        }

        applyHiddenState()
        DispatchQueue.main.async { [weak self] in
            self?.applyHiddenState()
        }
    }

    func detach() {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        if let contentView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: contentView)
        }
        scrollView = nil
        contentView = nil
    }

    deinit {
        detach()
    }

    func applyHiddenState() {
        guard let scrollView else { return }
        if let vs = scrollView.verticalScroller {
            vs.isHidden = true
            vs.alphaValue = 0
        }
        if let hs = scrollView.horizontalScroller {
            hs.isHidden = true
            hs.alphaValue = 0
        }
    }

    @objc private func handleAnyScroll(_ notification: Notification) {
        showScrollers()
        scheduleHide()
    }

    private func showScrollers() {
        guard let scrollView else { return }
        if let vs = scrollView.verticalScroller {
            vs.isHidden = false
            vs.alphaValue = 1
        }
        if let hs = scrollView.horizontalScroller {
            hs.isHidden = false
            hs.alphaValue = 1
        }
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applyHiddenState()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }
}
