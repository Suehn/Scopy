import AppKit
import Darwin
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers
import WebKit

/// Service for exporting Markdown preview as PNG image to clipboard
public enum MarkdownExportService {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Scopy", category: "export")
    public static let defaultTargetWidthPixels: CGFloat = 1080

    public struct ExportStats: Sendable, Equatable {
        public let finalPNGBytes: Int
        /// True when the PNG came out of pngquant; false when ImageIO encoded the bitmap.
        public let pngquantApplied: Bool

        public init(finalPNGBytes: Int, pngquantApplied: Bool) {
            self.finalPNGBytes = finalPNGBytes
            self.pngquantApplied = pngquantApplied
        }
    }

    @MainActor
    public final class CancellationHandle: @unchecked Sendable {
        private var cancelAction: (@MainActor () -> Void)?

        init(cancelAction: @escaping @MainActor () -> Void) {
            self.cancelAction = cancelAction
        }

        public func cancel() {
            let action = cancelAction
            cancelAction = nil
            action?()
        }
    }

    public struct PasteboardWriteLease: Equatable, Sendable {
        let expectedChangeCount: Int

        @MainActor
        init(pasteboard: NSPasteboard) {
            expectedChangeCount = pasteboard.changeCount
        }

        @MainActor
        func isCurrent(for pasteboard: NSPasteboard) -> Bool {
            pasteboard.changeCount == expectedChangeCount
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
        case createPDF
        case rasterizePDF
        case snapshotOnce
        case snapshotTiles
        case stitchTiles
        case imageConversion
        case pngEncoding
        case pasteboardWrite

        /// The user-facing phase; tiled capture reports its own tile numbers.
        var progress: ExportProgress? {
            switch self {
            case .loadHTML, .prepareLayout, .applyScale: return .rendering
            case .createPDF, .rasterizePDF, .snapshotOnce, .imageConversion: return .capturing(tile: 1, of: 1)
            case .snapshotTiles, .stitchTiles: return nil
            case .pngEncoding: return .compressing
            case .pasteboardWrite: return .writing
            }
        }
    }

    /// What an export is doing now, for the preview's progress label.
    public enum ExportProgress: Equatable, Sendable {
        case rendering
        case capturing(tile: Int, of: Int)
        case compressing
        case writing
    }

    /// Export Markdown HTML as white-background PNG to clipboard
    /// Creates an offscreen WebView to render the full content
    /// - Parameters:
    ///   - html: The HTML content to render and export
    ///   - viewportWidthPoints: The viewport width used to lay out the HTML before snapshotting
    ///   - completion: Completion handler with result
    @MainActor
    @discardableResult
    public static func exportToPNGClipboard(
        html: String,
        targetWidthPixels: CGFloat = defaultTargetWidthPixels,
        resolutionScale: CGFloat = 1,
        pngquantOptions: PngquantService.Options? = nil,
        pasteboardWriteLease: PasteboardWriteLease? = nil,
        authorizePasteboardWrite: @escaping @MainActor () -> Bool = { true },
        onProgress: @escaping @MainActor (ExportProgress) -> Void = { _ in },
        completion: @escaping (Result<ExportStats, Error>) -> Void
    ) -> CancellationHandle {
        let pasteboard = resolvedPasteboardForExport()
        let pasteboardLease = pasteboardWriteLease ?? PasteboardWriteLease(pasteboard: pasteboard)
        let dumpURL = environmentURL(forKey: "SCOPY_EXPORT_DUMP_PATH")
        let errorDumpURL = environmentURL(forKey: "SCOPY_EXPORT_ERROR_DUMP_PATH")

        return exportToPNGData(
            html: html,
            targetWidthPixels: targetWidthPixels,
            resolutionScale: resolutionScale,
            pngquantOptions: pngquantOptions,
            onProgress: onProgress
        ) { result in
            switch result {
            case .success(let outcome):
                onProgress(.writing)
                let committed = commitRenderedExport(
                    outcome,
                    pasteboard: pasteboard,
                    lease: pasteboardLease,
                    authorizePasteboardWrite: authorizePasteboardWrite,
                    dumpURL: dumpURL,
                    errorDumpURL: errorDumpURL
                )
                if case .success = committed, outcome.stats.pngquantApplied {
                    logger.info("Exported PNG with pngquant: \(outcome.stats.finalPNGBytes, privacy: .public) bytes")
                }
                completion(committed)
            case .failure(let error):
                writeErrorDump(error, to: errorDumpURL)
                completion(.failure(error))
            }
        }
    }

    /// Captures pasteboard ownership at the user-command boundary, before file loading or WebKit
    /// rendering can suspend. A later clipboard change invalidates the lease.
    @MainActor
    public static func capturePasteboardWriteLease() -> PasteboardWriteLease {
        PasteboardWriteLease(pasteboard: resolvedPasteboardForExport())
    }

    /// Export Markdown HTML as a white-background PNG data blob.
    /// This is the core export path and is used by clipboard export and tests.
    @MainActor
    @discardableResult
    static func exportToPNGData(
        html: String,
        targetWidthPixels: CGFloat = defaultTargetWidthPixels,
        resolutionScale: CGFloat = 1,
        pngquantOptions: PngquantService.Options? = nil,
        onProgress: @escaping @MainActor (ExportProgress) -> Void = { _ in },
        completion: @escaping (Result<ExportOutcome, Error>) -> Void
    ) -> CancellationHandle {
        let coordinator = ExportCoordinator(
            html: html,
            targetWidthPixels: targetWidthPixels,
            resolutionScale: resolutionScale,
            pngquantOptions: pngquantOptions,
            onProgress: onProgress,
            completion: completion
        )
        let cancellationHandle = CancellationHandle { [weak coordinator] in
            coordinator?.cancel()
        }
        coordinator.start()
        return cancellationHandle
    }

    enum ExportError: LocalizedError {
        case stageFailed(stage: ExportStage, underlying: Error?)
        case renderingTimeout(stage: ExportStage)
        case exportLimitExceeded(reason: String)
        case pasteboardWriteNotAuthorized

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
            case .pasteboardWriteNotAuthorized:
                return "Export was cancelled before writing to the pasteboard"
            }
        }
    }

    @MainActor
    static func commitRenderedExport(
        _ outcome: ExportOutcome,
        pasteboard: NSPasteboard,
        lease: PasteboardWriteLease,
        authorizePasteboardWrite: @escaping @MainActor () -> Bool,
        dumpURL: URL?,
        errorDumpURL: URL?
    ) -> Result<ExportStats, Error> {
        do {
            let didWrite = try writePNGToPasteboard(
                pngData: outcome.pngData,
                pasteboard: pasteboard,
                authorization: {
                    authorizePasteboardWrite() && lease.isCurrent(for: pasteboard)
                }
            )
            guard didWrite else {
                throw ExportError.pasteboardWriteNotAuthorized
            }

            if let dumpURL {
                try? outcome.pngData.write(to: dumpURL, options: [.atomic])
            }
            return .success(outcome.stats)
        } catch {
            writeErrorDump(error, to: errorDumpURL)
            return .failure(error)
        }
    }

    private static func environmentURL(forKey key: String) -> URL? {
        guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func writeErrorDump(_ error: Error, to url: URL?) {
        guard let url else { return }
        try? Data(String(describing: error).utf8).write(to: url, options: [.atomic])
    }

    /// Performs the irreversible pasteboard mutation only after a caller-owned liveness check.
    /// Returning `false` leaves every existing pasteboard representation untouched.
    @MainActor
    @discardableResult
    static func writePNGToPasteboard(
        pngData: Data,
        pasteboard: NSPasteboard,
        authorization: () -> Bool
    ) throws -> Bool {
        guard authorization() else { return false }
        guard let imagePayload = makeStandardImagePayloadForPasteboardWrite(pngData) else {
            logger.error("Failed to normalize PNG payload before pasteboard export")
            throw ExportError.stageFailed(stage: .pasteboardWrite, underlying: nil)
        }
        // Normalization can be non-trivial for legacy image encodings. Recheck immediately before
        // the irreversible pasteboard clear so a newer user copy always wins.
        guard authorization() else { return false }
        try writeImagePayloadToPasteboard(imagePayload, pasteboard: pasteboard)
        return true
    }

    @MainActor
    static func writePNGToPasteboard(pngData: Data, pasteboard: NSPasteboard) throws {
        guard let imagePayload = makeStandardImagePayloadForPasteboardWrite(pngData) else {
            logger.error("Failed to normalize PNG payload before pasteboard export")
            throw ExportError.stageFailed(stage: .pasteboardWrite, underlying: nil)
        }

        try writeImagePayloadToPasteboard(imagePayload, pasteboard: pasteboard)
    }

    @MainActor
    private static func writeImagePayloadToPasteboard(
        _ imagePayload: ImagePasteboardPayload,
        pasteboard: NSPasteboard
    ) throws {
        pasteboard.clearContents()
        pasteboard.declareTypes([.png], owner: nil)

        guard pasteboard.setData(imagePayload.primaryPNGData, forType: .png) else {
            logger.error("Failed to set PNG data on pasteboard")
            throw ExportError.stageFailed(stage: .pasteboardWrite, underlying: nil)
        }
    }

    private struct ImagePasteboardPayload {
        let primaryPNGData: Data
    }

    private static func makeStandardImagePayloadForPasteboardWrite(_ data: Data) -> ImagePasteboardPayload? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        let sourceType = CGImageSourceGetType(imageSource) as String?
        if sourceType == UTType.png.identifier {
            return ImagePasteboardPayload(primaryPNGData: data)
        }

        guard let pngData = rasterizeCGImageToStandardPNG(image) else { return nil }
        return ImagePasteboardPayload(primaryPNGData: pngData)
    }

    private static func rasterizeCGImageToStandardPNG(_ image: CGImage) -> Data? {
        guard let context = makeStandardRGBAContext(for: image) else { return nil }
        let width = image.width
        let height = image.height
        context.interpolationQuality = CGInterpolationQuality.high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let rasterizedImage = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, rasterizedImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func makeStandardRGBAContext(for image: CGImage) -> CGContext? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big)
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )
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

#if DEBUG
    static func debugMaxSupportedHeightPixels(targetWidthPixels: CGFloat = defaultTargetWidthPixels) -> CGFloat {
        MarkdownExportRenderConstants.maxSupportedHeightPixels(for: targetWidthPixels)
    }

    static func debugShouldBypassPDFForVeryTallContent(heightPoints: CGFloat) -> Bool {
        MarkdownExportRenderConstants.shouldBypassPDFForHeight(heightPoints)
    }
#endif
}

enum MarkdownExportRenderConstants {
    static let exportViewportHeightPoints: CGFloat = 1000
    static let minSnapshotHeightPoints: CGFloat = 120
    static let defaultMaxInlineBitmapPixels: CGFloat = 60_000_000
    static let maxHeightBudgetMultiplier: CGFloat = 10
    static let maxAutomaticPDFExportHeightPoints: CGFloat = 14_400

    static func shouldBypassPDFForHeight(_ heightPoints: CGFloat) -> Bool {
        // WebKit/Quartz splits taller captures into multiple PDF pages. The tiled snapshot path is more reliable for
        // scroll-order preservation in long exports, so keep automatic PDF export to single-page captures.
        heightPoints > maxAutomaticPDFExportHeightPoints
    }

    // Raise the default height budget 10x while keeping extra-long exports off the heap.
    static var maxTotalPixels: CGFloat {
        let processInfo = ProcessInfo.processInfo
        if processInfo.arguments.contains("--uitesting"),
           let raw = processInfo.environment["SCOPY_UITEST_EXPORT_MAX_TOTAL_PIXELS"],
           let value = Double(raw),
           value.isFinite,
           value >= 1_000_000 {
            return CGFloat(value)
        }
        return defaultMaxInlineBitmapPixels * maxHeightBudgetMultiplier
    }

    static var maxInMemoryBitmapPixels: CGFloat {
        min(maxTotalPixels, defaultMaxInlineBitmapPixels)
    }

    static func maxSupportedHeightPixels(for targetWidthPixels: CGFloat) -> CGFloat {
        let width = max(1, targetWidthPixels)
        return floor(maxTotalPixels / width)
    }

    // Keep single-shot snapshots within a conservative height. Taller exports should switch to tiled snapshot + stitch.
    static let maxSingleSnapshotRectHeightPoints: CGFloat = 20_000
    static let snapshotTileOverlapPoints: CGFloat = 1
    static let minAllowedGlobalScale: CGFloat = 0.02
}
