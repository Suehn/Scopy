import AppKit
import Darwin
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers
import WebKit

/// Service for exporting Markdown preview as PNG image to clipboard
public enum MarkdownExportService {
    fileprivate static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Scopy", category: "export")
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
        completion: @escaping (Result<ExportStats, Error>) -> Void
    ) -> CancellationHandle {
        let pasteboard = resolvedPasteboardForExport()
        let pasteboardLease = pasteboardWriteLease ?? PasteboardWriteLease(pasteboard: pasteboard)
        let dumpURL = environmentURL(forKey: "SCOPY_EXPORT_DUMP_PATH")
        let errorDumpURL = environmentURL(forKey: "SCOPY_EXPORT_ERROR_DUMP_PATH")

        return exportToPNGData(html: html, targetWidthPixels: targetWidthPixels, resolutionScale: resolutionScale, pngquantOptions: pngquantOptions) { result in
            switch result {
            case .success(let outcome):
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
        completion: @escaping (Result<ExportOutcome, Error>) -> Void
    ) -> CancellationHandle {
        let coordinator = ExportCoordinator(
            html: html,
            targetWidthPixels: targetWidthPixels,
            resolutionScale: resolutionScale,
            pngquantOptions: pngquantOptions,
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

// MARK: - Export Coordinator

@MainActor
final class MarkdownExportConcurrencyGate {
    enum Submission: Equatable {
        case started
        case queued
        case rejected
    }

    private struct PendingWork {
        let id: UUID
        let start: @MainActor () -> Void
    }

    let limit: Int
    let maximumPendingCount: Int
    private(set) var activeIDs: Set<UUID> = []
    private var pending: [PendingWork] = []

    init(limit: Int, maximumPendingCount: Int) {
        self.limit = max(1, limit)
        self.maximumPendingCount = max(0, maximumPendingCount)
    }

    var activeCount: Int { activeIDs.count }
    var pendingCount: Int { pending.count }

    func submit(id: UUID, start: @escaping @MainActor () -> Void) -> Submission {
        guard !activeIDs.contains(id), !pending.contains(where: { $0.id == id }) else {
            return .rejected
        }
        if activeIDs.count < limit {
            activeIDs.insert(id)
            start()
            return .started
        }
        guard pending.count < maximumPendingCount else { return .rejected }
        pending.append(PendingWork(id: id, start: start))
        return .queued
    }

    func finish(id: UUID) {
        if activeIDs.remove(id) != nil {
            promotePendingWorkIfPossible()
            return
        }
        pending.removeAll(where: { $0.id == id })
    }

    private func promotePendingWorkIfPossible() {
        while activeIDs.count < limit, !pending.isEmpty {
            let next = pending.removeFirst()
            activeIDs.insert(next.id)
            next.start()
        }
    }
}

private enum MarkdownExportRenderConstants {
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

/// The export bitmap is a PAM (`P7`, 8-bit `RGB_ALPHA`) file in a private temporary directory whose pixel rows are
/// memory-mapped: every export path draws straight into the file pngquant maps afterwards, so the pixels are never
/// copied. The header occupies a fixed-size region so the height can be rewritten in place after trimming.
private final class ExportBitmapStorage {
    let directoryURL: URL
    let fileURL: URL
    /// Start of the pixel rows inside the mapping.
    let pixels: UnsafeMutableRawPointer
    private let mapping: UnsafeMutableRawPointer
    private let mappingLength: Int
    private let fileDescriptor: Int32

    private init(
        directoryURL: URL,
        fileURL: URL,
        mapping: UnsafeMutableRawPointer,
        mappingLength: Int,
        headerLength: Int,
        fileDescriptor: Int32
    ) {
        self.directoryURL = directoryURL
        self.fileURL = fileURL
        self.mapping = mapping
        self.mappingLength = mappingLength
        self.pixels = mapping.advanced(by: headerLength)
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        munmap(mapping, mappingLength)
        close(fileDescriptor)
        try? FileManager.default.removeItem(at: directoryURL)
    }

    static func create(width: Int, height: Int, pixelBytes: Int) throws -> ExportBitmapStorage {
        guard pixelBytes > 0 else {
            throw posixError(operation: "size", code: EINVAL)
        }
        let header = PngquantService.pamHeader(width: width, height: height)
        let totalLength = header.count + pixelBytes
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "scopy-markdown-export-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent("export.pam")

        func fail(_ operation: String, fd: Int32?) -> NSError {
            let error = posixError(operation: operation)
            if let fd { close(fd) }
            try? FileManager.default.removeItem(at: directoryURL)
            return error
        }

        let fd = open(fileURL.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw fail("open", fd: nil) }
        // Reserve the blocks up front so a full disk surfaces here as an error instead of a fault while drawing.
        var store = fstore_t(
            fst_flags: UInt32(F_ALLOCATEALL),
            fst_posmode: F_PEOFPOSMODE,
            fst_offset: 0,
            fst_length: off_t(totalLength),
            fst_bytesalloc: 0
        )
        guard fcntl(fd, F_PREALLOCATE, &store) != -1 else { throw fail("preallocate", fd: fd) }
        guard ftruncate(fd, off_t(totalLength)) == 0 else { throw fail("ftruncate", fd: fd) }
        guard let mapping = mmap(nil, totalLength, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), mapping != MAP_FAILED else {
            throw fail("mmap", fd: fd)
        }
        header.withUnsafeBytes { bytes in
            mapping.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        return ExportBitmapStorage(
            directoryURL: directoryURL,
            fileURL: fileURL,
            mapping: mapping,
            mappingLength: totalLength,
            headerLength: header.count,
            fileDescriptor: fd
        )
    }

    /// Rewrites the header for the final dimensions and drops any rows past them.
    func finalize(width: Int, height: Int, pixelBytes: Int) throws {
        let header = PngquantService.pamHeader(width: width, height: height)
        header.withUnsafeBytes { bytes in
            mapping.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        guard ftruncate(fileDescriptor, off_t(header.count + pixelBytes)) == 0 else {
            throw Self.posixError(operation: "ftruncate")
        }
    }

    private static func posixError(operation: String, code: Int32 = errno) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(code)))"]
        )
    }
}

private final class ManagedAtomic: @unchecked Sendable {
    private var value: Bool
    private let lock = NSLock()
    init(_ value: Bool) { self.value = value }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// A white-background RGBA8 drawing surface backed by `ExportBitmapStorage`. Rows are stored top-down.
private final class ExportBitmapCanvas: @unchecked Sendable {
    let context: CGContext
    let width: Int
    private(set) var height: Int
    let bytesPerRow: Int
    let pixels: UnsafeMutableRawPointer
    private let storage: ExportBitmapStorage

    private init(context: CGContext, width: Int, height: Int, bytesPerRow: Int, storage: ExportBitmapStorage) {
        self.context = context
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixels = storage.pixels
        self.storage = storage
    }

    var fileURL: URL { storage.fileURL }

    static func make(
        width: Int,
        height: Int,
        stage: MarkdownExportService.ExportStage
    ) throws -> ExportBitmapCanvas {
        guard width > 0, height > 0 else {
            throw MarkdownExportService.ExportError.stageFailed(stage: stage, underlying: nil)
        }

        let (bytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (bufferLength, bufferOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !bufferOverflow, bufferLength > 0 else {
            throw MarkdownExportService.ExportError.exportLimitExceeded(
                reason: "Bitmap buffer overflow (w=\(width)px, h=\(height)px)"
            )
        }

        let storage: ExportBitmapStorage
        do {
            storage = try ExportBitmapStorage.create(width: width, height: height, pixelBytes: bufferLength)
        } catch {
            throw MarkdownExportService.ExportError.stageFailed(stage: stage, underlying: error)
        }

        guard let context = CGContext(
            data: storage.pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw MarkdownExportService.ExportError.stageFailed(stage: stage, underlying: nil)
        }

        return ExportBitmapCanvas(context: context, width: width, height: height, bytesPerRow: bytesPerRow, storage: storage)
    }

    /// Drops blank rows at the top of the buffer beyond a 40-pixel margin. The export background is forced to white,
    /// so over-measured content height shows up as blank rows; this keeps the crop the export has always applied.
    func trimBlankLeadingRowsIfNeeded() {
        let w = width
        let h = height
        guard w > 0, h > 0, bytesPerRow > 0 else { return }
        let buffer = pixels.assumingMemoryBound(to: UInt8.self)
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

        var firstContentRow: Int?
        for y in 0..<h where !rowIsMostlyWhite(y) {
            firstContentRow = y
            break
        }
        guard let firstContentRow else { return }
        // Keep a small margin (in pixels) so content doesn't touch the edge.
        let margin = min(40, max(0, h - 1))
        let dropRows = max(0, firstContentRow - margin)
        let remainingRows = h - dropRows
        guard dropRows > 0, remainingRows > 0 else { return }
        memmove(pixels, pixels.advanced(by: dropRows * bytesPerRow), remainingRows * bytesPerRow)
        height = remainingRows
    }

    /// Runs `draw` once per horizontal band on separate threads. Each band gets its own context over its rows and the
    /// full canvas rectangle expressed in that context's coordinates, so drawing the whole image into `bounds`
    /// produces exactly the rows the band owns; resampling reads source pixels, not neighbouring bands, so the result
    /// matches a single full-canvas draw byte for byte.
    func drawInParallelBands(_ draw: @Sendable (CGContext, CGRect) -> Void) throws {
        let rowsPerBand = 256
        let bandCount = max(1, (height + rowsPerBand - 1) / rowsPerBand)
        let bytesPerRow = self.bytesPerRow
        let width = self.width
        let height = self.height
        let pixels = self.pixels
        let failed = ManagedAtomic(false)
        DispatchQueue.concurrentPerform(iterations: bandCount) { band in
            let startRow = band * rowsPerBand
            let bandRows = min(rowsPerBand, height - startRow)
            guard bandRows > 0 else { return }
            guard let context = CGContext(
                data: pixels.advanced(by: startRow * bytesPerRow),
                width: width,
                height: bandRows,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                failed.set(true)
                return
            }
            // Rows are stored top-down while Core Graphics counts y upward from the band's bottom row.
            let originY = -CGFloat(height - startRow - bandRows)
            draw(context, CGRect(x: 0, y: originY, width: CGFloat(width), height: CGFloat(height)))
        }
        if failed.get() {
            throw MarkdownExportService.ExportError.stageFailed(stage: .imageConversion, underlying: nil)
        }
    }

    /// Writes the final dimensions into the file header and truncates the file to the remaining rows.
    func finalizeFile() throws {
        try storage.finalize(width: width, height: height, pixelBytes: bytesPerRow * height)
    }

    func makeImage() -> CGImage? {
        let retainedStorage = Unmanaged.passRetained(storage)
        guard let provider = CGDataProvider(
            dataInfo: retainedStorage.toOpaque(),
            data: pixels,
            size: bytesPerRow * height,
            releaseData: { info, _, _ in
                guard let info else { return }
                Unmanaged<ExportBitmapStorage>.fromOpaque(info).release()
            }
        ) else {
            retainedStorage.release()
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

/// Manages the lifecycle of offscreen WebView for export
@MainActor
private final class ExportCoordinator: NSObject, WKNavigationDelegate {
    private enum ExportEnv {
        static let disablePDFExport = "SCOPY_EXPORT_DISABLE_PDF"
        static let uiTestEnablePDFExport = "SCOPY_UITEST_ENABLE_PDF_EXPORT"
        static let requirePDFExport = "SCOPY_EXPORT_REQUIRE_PDF"
        static let dumpPDFPath = "SCOPY_EXPORT_PDF_DUMP_PATH"
    }

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
    private var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var timeoutTask: Task<Void, Never>?
    private var isCompleted = false
    private var exportTask: Task<Void, Never>?
    private var stage: MarkdownExportService.ExportStage = .loadHTML {
        didSet {
            MarkdownExportService.logger.info("Export stage \(oldValue.rawValue, privacy: .public) -> \(self.stage.rawValue, privacy: .public)")
        }
    }
    private var didDumpTableMetrics = false
    private let concurrencyID = UUID()

    // Keep a strong reference to self until export completes
    private static var activeCoordinators: Set<ExportCoordinator> = []
    private static let concurrencyGate = MarkdownExportConcurrencyGate(
        limit: 2,
        maximumPendingCount: 8
    )

    init(
        html: String,
        targetWidthPixels: CGFloat,
        resolutionScale: CGFloat,
        pngquantOptions: PngquantService.Options?,
        completion: @escaping (Result<MarkdownExportService.ExportOutcome, Error>) -> Void
    ) {
        self.html = html
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

        if !ProcessInfo.processInfo.arguments.contains("--uitesting"),
           let ruleList = await ExportNetworkBlocker.ruleList()
        {
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
            :root {
                color-scheme: light !important;
                --scopy-chatgpt-output-surface-width: \(MarkdownRenderLayoutConstants.chatGPTOutputSurfaceWidth)px;
                --scopy-chatgpt-content-inline-padding: \(MarkdownRenderLayoutConstants.chatGPTContentInlinePadding)px;
                --scopy-chatgpt-content-top-padding: \(MarkdownRenderLayoutConstants.chatGPTContentTopPadding)px;
                --scopy-chatgpt-content-bottom-padding: \(MarkdownRenderLayoutConstants.chatGPTContentBottomPadding)px;
                --scopy-chatgpt-thread-content-width: min(
                    var(--scopy-chatgpt-thread-content-max-width),
                    max(1px, calc(var(--scopy-chatgpt-render-width) - (var(--scopy-chatgpt-content-inline-padding) * 2)))
                );
                --scopy-chatgpt-render-width: var(--scopy-chatgpt-layout-viewport-width);
                --scopy-chatgpt-markdown-table-col-baseline: var(--scopy-chatgpt-thread-content-max-width);
                --scopy-chatgpt-table-breakout-width: var(--scopy-chatgpt-thread-content-width);
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
            javaScriptString: "Boolean(document.querySelector('#content [data-scopy-version=\"2\"], #content .scopy-mention-icon, #content img.scopy-link-origin-icon, #content img.scopy-source-citation-origin-icon'))"
        )
        var scrollHeightPoints = initialScrollHeightPoints

        stage = .applyScale
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

        let isUITesting = ProcessInfo.processInfo.arguments.contains("--uitesting")
        let processInfo = ProcessInfo.processInfo
        let pdfExplicitlyRequired = processInfo.environment[ExportEnv.requirePDFExport] == "1"
        let projectedOutputHeightPixels = max(1, scrollHeightPoints * outputPixelScaleFactor)
        let projectedOutputTotalPixels = max(1, targetWidthPixels * projectedOutputHeightPixels)
        let shouldBypassPDFFromRasterBudget = !pdfExplicitlyRequired
            && projectedOutputTotalPixels > MarkdownExportRenderConstants.maxInMemoryBitmapPixels + 0.5
        let shouldBypassPDFFromHeight = MarkdownExportRenderConstants.shouldBypassPDFForHeight(scrollHeightPoints)
        let shouldBypassPDFForVeryTallContent = !pdfExplicitlyRequired
            && (
                shouldBypassPDFFromHeight
                || shouldBypassPDFFromRasterBudget
            )
        let requiresPDFExportForResolution = outputScale > 1.001 && !shouldBypassPDFForVeryTallContent
        let shouldAttemptPDF: Bool = {
            let env = processInfo.environment
            if let raw = env[ExportEnv.disablePDFExport], raw == "1" { return false }
            if pdfExplicitlyRequired { return true }
            if shouldBypassPDFForVeryTallContent { return false }
            if requiresPDFExportForResolution { return true }
            if isUITesting {
                return env[ExportEnv.uiTestEnablePDFExport] == "1"
            }
            return true
        }()
        if shouldBypassPDFForVeryTallContent {
            let pdfBypassReason = shouldBypassPDFFromHeight ? "height" : "rasterBudget"
            MarkdownExportService.logger.info(
                "Skipping PDF export and falling back to snapshot export. reason=\(pdfBypassReason, privacy: .public) heightPt=\(scrollHeightPoints, privacy: .public) projectedPixels=\(projectedOutputTotalPixels, privacy: .public)"
            )
        }
        let requiresPDFExport = requiresPDFExportForResolution || pdfExplicitlyRequired
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
            } catch {
                if requiresPDFExport {
                    throw error
                }
                MarkdownExportService.logger.error("PDF export failed; falling back to snapshot export. scale=\(appliedScale, privacy: .public) heightPt=\(scrollHeightPoints, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }

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
            stage = .createPDF
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

            if let dumpPath = ProcessInfo.processInfo.environment[ExportEnv.dumpPDFPath], !dumpPath.isEmpty {
                try? pdfData.write(to: URL(fileURLWithPath: dumpPath), options: [.atomic])
            }

            stage = .rasterizePDF
            let expectedPageWidthPoints = rectPoints.width
            return try await Task.detached(priority: .userInitiated) {
                let canvas = try Self.rasterizePDFDataToCanvas(
                    pdfData: pdfData,
                    targetWidthPixels: targetWidthPixels,
                    expectedPageWidthPoints: expectedPageWidthPoints,
                    contentScaleCompensation: contentScaleCompensation
                )
                return try Self.encodeExportCanvas(canvas, pngquantOptions: pngquantOptions)
            }.value
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

        stage = .imageConversion
        let cg = try cgImage(from: image)

        stage = .pngEncoding
        let targetWidth = max(1, Int(round(targetWidthPixels)))
        let pngquantOptions = preservesArtworkColors ? nil : self.pngquantOptions
        return try await Task.detached(priority: .userInitiated) {
            let canvas = try Self.canvasFromSnapshot(cg, targetWidthPixels: targetWidth)
            return try Self.encodeExportCanvas(canvas, pngquantOptions: pngquantOptions)
        }.value
    }

    private func exportTiledPNG(webView: WKWebView, totalHeightPoints: CGFloat) async throws -> MarkdownExportService.ExportOutcome {
        let targetWidthPixelsInt = max(1, Int(round(targetWidthPixels)))

        stage = .snapshotTiles
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
        while scrollYPoints < CGFloat(totalHeightPointsInt) {
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

            stage = .stitchTiles
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
            scrollYPoints += max(1, tileViewportHeightPoints - overlapPoints)
        }

        stage = .pngEncoding
        let pngquantOptions = preservesArtworkColors ? nil : self.pngquantOptions
        return try await Task.detached(priority: .userInitiated) {
            try Self.encodeExportCanvas(canvas, pngquantOptions: pngquantOptions)
        }.value
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
        } else {
            let scrollJS = """
            (function() {
              try { window.scrollTo(0, \(target)); } catch (e) { }
              return true;
            })();
            """
            _ = try await evaluateJavaScriptBool(webView: webView, javaScriptString: scrollJS)
        }
        if appKitOffsetY != nil {
            let syncScrollJS = """
            (function() {
              var y = \(target);
              try { window.scrollTo(0, y); } catch (e) { }
              try {
                if (document && document.documentElement) { document.documentElement.scrollTop = y; }
                if (document && document.body) { document.body.scrollTop = y; }
              } catch (e) { }
              return true;
            })();
            """
            _ = try? await evaluateJavaScriptBool(webView: webView, javaScriptString: syncScrollJS)
        }
        // Let WebKit lay out and paint the new scroll position before it is measured or captured.
        await waitForAnimationFrames(webView: webView, count: 2, timeout: 0.5)

        if let appKitOffsetY {
            return appKitOffsetY
        }

        let actualJS = """
        (function() {
          try {
            var y = 0;
            if (typeof window.scrollY === 'number') { y = window.scrollY; }
            else if (typeof window.pageYOffset === 'number') { y = window.pageYOffset; }
            else if (document && document.documentElement && typeof document.documentElement.scrollTop === 'number') { y = document.documentElement.scrollTop; }
            return String(Math.max(0, y || 0));
          } catch (e) {
            return "0";
          }
        })();
        """
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

    private func prepareForExportScrollHeightPoints(webView: WKWebView) async throws -> CGFloat {
        // `WKWebView.callAsyncJavaScript` has been observed to return `nil` (undefined) intermittently under UI testing,
        // so readiness is tracked by a page-side animation-frame watcher that Swift polls with `evaluateJavaScript`.
        let widthPoints = Double(viewportWidthPoints)

        let setupJS = """
        (function() {
          try {
            try { if (document && document.documentElement && document.documentElement.classList) { document.documentElement.classList.add('scopy-export-mode'); } } catch (e) { }
            var content = document.getElementById('content');
            if (content) {
              try { content.style.opacity = '1'; } catch (e) { }
              try { content.style.transition = 'none'; } catch (e) { }
              try {
                if (window.ScopyUnifiedMarkdown && typeof window.ScopyUnifiedMarkdown.freezeRichForExport === 'function') {
                  window.ScopyUnifiedMarkdown.freezeRichForExport(content);
                }
              } catch (e) { }
              try { if (typeof window.syncChatGPTZoomShell === 'function') { window.syncChatGPTZoomShell(content); } } catch (e) { }
            }
            try { if (typeof window.__scopyRenderMath === 'function') { window.__scopyRenderMath(); } } catch (e) { }
          } catch (e) { }
          return true;
        })();
        """

        let adjustWideContentJS = """
        (function() {
          var w = \(widthPoints);
          var exportScale = 1;
          try {
            if (window && window.__scopyExportUsesTransform && window.__scopyExportScale) {
              var s = window.__scopyExportScale;
              if (s && isFinite(s) && s > 0) { exportScale = s; }
            }
          } catch (e) { exportScale = 1; }
          function computeTargetWidthPoints(content) {
            var padL = 0, padR = 0;
            try {
              var cs = window.getComputedStyle(content);
              padL = parseFloat(cs.paddingLeft) || 0;
              padR = parseFloat(cs.paddingRight) || 0;
            } catch (e) { padL = 0; padR = 0; }
            var layoutW = 0;
            try { layoutW = Math.ceil(content.clientWidth || content.offsetWidth || 0); } catch (e) { layoutW = 0; }
            if (!layoutW || !isFinite(layoutW) || layoutW <= 0) {
              try {
                var raw = window.getComputedStyle(document.documentElement).getPropertyValue('--scopy-chatgpt-render-width');
                layoutW = Math.ceil(parseFloat(raw) || 0);
              } catch (e) { layoutW = 0; }
            }
            if (!layoutW || !isFinite(layoutW) || layoutW <= 0) { layoutW = w; }

            // Table export starts from the same unscaled content box as preview. A later global transform may shrink
            // the entire rendered surface for PNG area limits, but it must not change text/table layout widths.
            return Math.max(1, Math.floor(layoutW - padL - padR));
          }
          function isExportTableWrapper(node) {
            return !!(node && node.classList && node.classList.contains('scopy-export-table-wrapper'));
          }
          function unwrapIfNeeded(block) {
            try {
              var p = block && block.parentElement;
              if (!p) { return; }
              if (!isExportTableWrapper(p)) { return; }
              var gp = p.parentNode;
              if (!gp) { return; }
              gp.insertBefore(block, p);
              gp.removeChild(p);
            } catch (e) { }
          }
          function previewTableBlock(table) {
            try {
              var p = table && table.parentElement;
              if (p && p.classList && p.classList.contains('scopy-chatgpt-table-wrapper')) {
                var gp = p.parentElement;
                if (gp && gp.classList && gp.classList.contains('scopy-chatgpt-table-container')) {
                  return gp;
                }
              }
              if (p && p.classList && p.classList.contains('scopy-chatgpt-table-container')) {
                return p;
              }
              if (table && table.parentNode && document && typeof document.createElement === 'function') {
                var wrapper = document.createElement('div');
                wrapper.className = 'scopy-chatgpt-table-container';
                var tableWrapper = document.createElement('div');
                tableWrapper.className = 'scopy-chatgpt-table-wrapper';
                table.parentNode.insertBefore(wrapper, table);
                wrapper.appendChild(tableWrapper);
                tableWrapper.appendChild(table);
                return wrapper;
              }
            } catch (e) { }
            return table;
          }
          function resetExportScale(node) {
            try {
              if (!node || !node.dataset || node.dataset.scopyExportScaled !== 'true') { return; }
              if (node.style) {
                node.style.transform = '';
                node.style.transformOrigin = '';
              }
              delete node.dataset.scopyExportScaled;
            } catch (e) { }
          }
          function applyExportScale(node, scale) {
            try {
              node.style.transform = 'scale(' + scale + ')';
              node.style.transformOrigin = 'top left';
              if (node.dataset) { node.dataset.scopyExportScaled = 'true'; }
            } catch (e) { }
          }
          function measureLayoutWidth(node) {
            if (!node) { return 0; }
            try { void node.offsetHeight; } catch (e) { }
            var rectW = 0, scrollW = 0, offsetW = 0, clientW = 0;
            try {
              rectW = Math.ceil((node.getBoundingClientRect().width || 0));
              var browserZoom = 1;
              try {
                var rawZoom = window.getComputedStyle(document.documentElement).getPropertyValue('--scopy-chatgpt-browser-zoom');
                browserZoom = parseFloat(rawZoom) || 1;
              } catch (e) { browserZoom = 1; }
              if (browserZoom && isFinite(browserZoom) && browserZoom > 0 && browserZoom !== 1) {
                rectW = Math.ceil(rectW / browserZoom);
              }
              if (exportScale && isFinite(exportScale) && exportScale > 0 && exportScale !== 1) {
                rectW = Math.ceil(rectW / exportScale);
              }
            } catch (e) { rectW = 0; }
            try { scrollW = Math.ceil((node.scrollWidth || 0)); } catch (e) { scrollW = 0; }
            try { offsetW = Math.ceil((node.offsetWidth || 0)); } catch (e) { offsetW = 0; }
            try { clientW = Math.ceil((node.clientWidth || 0)); } catch (e) { clientW = 0; }
            return Math.max(rectW, scrollW, offsetW, clientW);
          }
          function measurePreviewTableWidth(table, block) {
            return Math.max(measureLayoutWidth(block), measureLayoutWidth(table));
          }

          function measureBlockWidth(node) {
            if (!node) { return 0; }
            try { void node.offsetHeight; } catch (e) { }
            var rectW = 0, scrollW = 0, offsetW = 0, clientW = 0;
            try {
              rectW = Math.ceil((node.getBoundingClientRect().width || 0));
              var browserZoom = 1;
              try {
                var rawZoom = window.getComputedStyle(document.documentElement).getPropertyValue('--scopy-chatgpt-browser-zoom');
                browserZoom = parseFloat(rawZoom) || 1;
              } catch (e) { browserZoom = 1; }
              if (browserZoom && isFinite(browserZoom) && browserZoom > 0 && browserZoom !== 1) {
                rectW = Math.ceil(rectW / browserZoom);
              }
            } catch (e) { rectW = 0; }
            try { scrollW = Math.ceil((node.scrollWidth || 0)); } catch (e) { scrollW = 0; }
            try { offsetW = Math.ceil((node.offsetWidth || 0)); } catch (e) { offsetW = 0; }
            try { clientW = Math.ceil((node.clientWidth || 0)); } catch (e) { clientW = 0; }
            return Math.max(rectW, scrollW, offsetW, clientW);
          }

          function scaleWideTables(content, targetWidth) {
            if (!content || !content.querySelectorAll) { return; }
            try {
              if (typeof window.__scopyScaleChatGPTTablesForExport === 'function') {
                window.__scopyScaleChatGPTTablesForExport(content, targetWidth);
                return;
              }
            } catch (e) { }
            var tables = content.querySelectorAll('table');
            for (var i = 0; i < (tables.length || 0); i++) {
              var table = tables[i];
              if (!table) { continue; }
              var block = previewTableBlock(table);
              unwrapIfNeeded(block);
              resetExportScale(block);
              resetExportScale(table);

              var rawWidth = measurePreviewTableWidth(table, block);
              if (!rawWidth || rawWidth <= targetWidth + 1) { continue; }

              var scale = targetWidth / rawWidth;
              if (!scale || !isFinite(scale) || scale >= 0.999) { continue; }
              if (scale <= 0) { continue; }

              // Preserve the preview table layout. Fallback HTML that was not produced by the Markdown renderer still
              // scales the table itself and reserves the scaled height on its table container.
              applyExportScale(table, scale);
              try {
                var rawH = Math.ceil(table.offsetHeight || table.scrollHeight || table.getBoundingClientRect().height || 0);
                if (rawH && rawH > 0 && block && block.style) {
                  block.style.height = Math.ceil(rawH * scale + 1) + 'px';
                  block.style.overflowX = 'visible';
                  if (block.dataset) { block.dataset.scopyExportScaled = 'true'; }
                }
              } catch (e) { }
            }
          }

          function adaptWideCodeBlocks(content, targetWidth) {
            if (!content || !content.querySelectorAll) { return; }
            var blocks = content.querySelectorAll('pre');
            for (var i = 0; i < (blocks.length || 0); i++) {
              var pre = blocks[i];
              if (!pre || !pre.classList) { continue; }
              try { pre.classList.remove('scopy-export-wrap-code'); } catch (e) { }
              var rawWidth = measureBlockWidth(pre);
              if (rawWidth > targetWidth + 1) {
                try { pre.classList.add('scopy-export-wrap-code'); } catch (e) { }
              }
            }
          }

          function scaleWideMath(content, targetWidth) {
            if (!content || !content.querySelectorAll) { return; }
            var displays = content.querySelectorAll('.katex-display');
            for (var i = 0; i < (displays.length || 0); i++) {
              var display = displays[i];
              var math = display && display.querySelector ? display.querySelector('.katex') : null;
              if (!display || !math || !math.style) { continue; }
              var available = 0;
              try { available = Math.floor(display.clientWidth || 0); } catch (e) { available = 0; }
              if (!available || available <= 0) { available = targetWidth; }
              available = Math.min(targetWidth, available);
              var rawWidth = measureBlockWidth(math);
              if (!rawWidth || rawWidth <= available + 1) { continue; }
              var scale = available / rawWidth;
              if (!scale || !isFinite(scale) || scale <= 0 || scale >= 0.999) { continue; }
              var rawHeight = 0;
              try { rawHeight = Math.ceil(math.offsetHeight || math.scrollHeight || math.getBoundingClientRect().height || 0); } catch (e) { rawHeight = 0; }
              math.style.transform = 'scale(' + scale + ')';
              math.style.transformOrigin = 'top center';
              display.style.overflow = 'visible';
              display.style.maxWidth = '100%';
              if (rawHeight > 0) { display.style.height = Math.ceil(rawHeight * scale + 1) + 'px'; }
              if (display.dataset) { display.dataset.scopyExportMathScaled = 'true'; }
            }

            var inlineHosts = content.querySelectorAll('.scopy-math-inline-host');
            for (var j = 0; j < (inlineHosts.length || 0); j++) {
              var host = inlineHosts[j];
              var inlineMath = host && host.querySelector ? host.querySelector('.katex') : null;
              if (!host || !inlineMath || !inlineMath.style || !host.style) { continue; }
              var inlineAvailable = 0;
              try { inlineAvailable = Math.floor(host.clientWidth || 0); } catch (e) { inlineAvailable = 0; }
              if (!inlineAvailable || inlineAvailable <= 0) { inlineAvailable = targetWidth; }
              inlineAvailable = Math.min(targetWidth, inlineAvailable);
              var inlineRawWidth = measureBlockWidth(inlineMath);
              if (!inlineRawWidth || inlineRawWidth <= inlineAvailable + 1) { continue; }
              var inlineScale = inlineAvailable / inlineRawWidth;
              if (!inlineScale || !isFinite(inlineScale) || inlineScale <= 0 || inlineScale >= 0.999) { continue; }
              var inlineRawHeight = 0;
              try { inlineRawHeight = Math.ceil(inlineMath.offsetHeight || inlineMath.scrollHeight || inlineMath.getBoundingClientRect().height || 0); } catch (e) { inlineRawHeight = 0; }
              inlineMath.style.transform = 'scale(' + inlineScale + ')';
              inlineMath.style.transformOrigin = 'left center';
              host.style.overflow = 'visible';
              host.style.maxWidth = '100%';
              host.style.width = Math.ceil(inlineRawWidth * inlineScale + 1) + 'px';
              if (inlineRawHeight > 0) { host.style.height = Math.ceil(inlineRawHeight * inlineScale + 1) + 'px'; }
              if (host.dataset) { host.dataset.scopyExportMathScaled = 'true'; }
            }
          }

          var content = document.getElementById('content');
          if (!content) { return false; }
          var targetWidth = computeTargetWidthPoints(content);
          try { if (typeof window.syncChatGPTZoomShell === 'function') { window.syncChatGPTZoomShell(content); } } catch (e) { }
          scaleWideTables(content, targetWidth);
          scaleWideMath(content, targetWidth);
          adaptWideCodeBlocks(content, targetWidth);
          try { if (typeof window.syncChatGPTZoomShell === 'function') { window.syncChatGPTZoomShell(content); } } catch (e) { }
          return true;
        })();
        """

        do {
            try await installLayoutWatcher(webView: webView)
            _ = try await evaluateJavaScriptBool(webView: webView, javaScriptString: setupJS)
        } catch {
            throw MarkdownExportService.ExportError.stageFailed(stage: .prepareLayout, underlying: error)
        }

        let readinessDeadline = CFAbsoluteTimeGetCurrent() + 12.0
        var didAdjustWideContent = false
        var adjustAttempts = 0
        var sinceFrame = 0
        var firstSettledAt: CFAbsoluteTime?
        var lastSample: LayoutSample?

        while true {
            let remaining = readinessDeadline - CFAbsoluteTimeGetCurrent()
            guard remaining > 0 else { break }
            let settled = try await awaitLayoutSettled(
                webView: webView,
                sinceFrame: sinceFrame,
                requireRenderReady: true,
                timeout: remaining
            )
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
                sinceFrame = sample.frames
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
              var block = t;
              try {
                var directParent = t.parentElement;
                if (directParent && directParent.classList && directParent.classList.contains('scopy-chatgpt-table-wrapper')) {
                  var containerParent = directParent.parentElement;
                  if (containerParent && containerParent.classList && containerParent.classList.contains('scopy-chatgpt-table-container')) {
                    block = containerParent;
                  }
                } else if (directParent && directParent.classList && directParent.classList.contains('scopy-chatgpt-table-container')) {
                  block = directParent;
                }
              } catch (e) { block = t; }
              var rect = t.getBoundingClientRect();
              var w = Math.ceil(rect.width || 0);
              var sw = 0, cw = 0;
              try { sw = Math.ceil(t.scrollWidth || 0); } catch (e) { sw = 0; }
              try { cw = Math.ceil(t.clientWidth || 0); } catch (e) { cw = 0; }

              var wrapped = false;
              var wrapperW = 0;
              try {
                var p = block.parentElement;
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
                var tr = window.getComputedStyle(block).transform;
                scale = parseScale(tr);
                if (scale === 1) {
                  tr = window.getComputedStyle(t).transform;
                  scale = parseScale(tr);
                }
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

            var exportScale = 1;
            var usesTransform = false;
            try {
              if (window && window.__scopyExportScale) { exportScale = window.__scopyExportScale; }
              usesTransform = !!(window && window.__scopyExportUsesTransform);
            } catch (e) { exportScale = 1; usesTransform = false; }

            var contentRectW = 0, contentRectH = 0;
            try {
              var r = content.getBoundingClientRect();
              contentRectW = Math.ceil(r.width || 0);
              contentRectH = Math.ceil(r.height || 0);
            } catch (e) { contentRectW = 0; contentRectH = 0; }

            var contentScrollW = 0, contentOffsetW = 0;
            try { contentScrollW = Math.ceil(content.scrollWidth || 0); } catch (e) { contentScrollW = 0; }
            try { contentOffsetW = Math.ceil(content.offsetWidth || 0); } catch (e) { contentOffsetW = 0; }

            var contentComputedWidth = '', contentComputedMaxWidth = '', contentComputedTransform = '';
            try {
              var ccs = window.getComputedStyle(content);
              contentComputedWidth = ccs.width || '';
              contentComputedMaxWidth = ccs.maxWidth || '';
              contentComputedTransform = ccs.transform || '';
            } catch (e) { contentComputedWidth = ''; contentComputedMaxWidth = ''; contentComputedTransform = ''; }

            var contentStyleWidth = '', contentStyleMaxWidth = '', contentStyleTransform = '';
            try {
              contentStyleWidth = content.style && content.style.width ? content.style.width : '';
              contentStyleMaxWidth = content.style && content.style.maxWidth ? content.style.maxWidth : '';
              contentStyleTransform = content.style && content.style.transform ? content.style.transform : '';
            } catch (e) { contentStyleWidth = ''; contentStyleMaxWidth = ''; contentStyleTransform = ''; }

            var bodyOverflowX = '', htmlOverflowX = '';
            try { bodyOverflowX = (window.getComputedStyle(document.body).overflowX || ''); } catch (e) { bodyOverflowX = ''; }
            try { htmlOverflowX = (window.getComputedStyle(document.documentElement).overflowX || ''); } catch (e) { htmlOverflowX = ''; }

            var innerW = 0;
            var dpr = 1;
            try { innerW = window.innerWidth || 0; } catch (e) { innerW = 0; }
            try { dpr = window.devicePixelRatio || 1; } catch (e) { dpr = 1; }

            return JSON.stringify({
              hasContent: true,
              targetWidth: targetWidth,
              exportScale: exportScale,
              usesTransform: usesTransform,
              innerWidth: innerW,
              devicePixelRatio: dpr,
              contentRectWidth: contentRectW,
              contentRectHeight: contentRectH,
              contentScrollWidth: contentScrollW,
              contentOffsetWidth: contentOffsetW,
              contentComputedWidth: contentComputedWidth,
              contentComputedMaxWidth: contentComputedMaxWidth,
              contentComputedTransform: contentComputedTransform,
              contentStyleWidth: contentStyleWidth,
              contentStyleMaxWidth: contentStyleMaxWidth,
              contentStyleTransform: contentStyleTransform,
              bodyOverflowX: bodyOverflowX,
              htmlOverflowX: htmlOverflowX,
              tables: out
            });
          } catch (e) {
            return JSON.stringify({ hasContent: false, targetWidth: 0, tables: [], error: String(e) });
          }
        })();
        """

        let content = (try? await evaluateJavaScriptString(webView: webView, javaScriptString: js)) ?? ""
        try? Data(content.utf8).write(to: URL(fileURLWithPath: path), options: [.atomic])
        didDumpTableMetrics = true
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
              contentRectHeight: (c && c.getBoundingClientRect) ? Math.ceil(c.getBoundingClientRect().height || 0) : 0,
              renderFailed: !!(window.__scopyRenderState && window.__scopyRenderState.renderFailed),
              renderErrorReason: (window.__scopyRenderState && window.__scopyRenderState.unifiedErrorReason) ? window.__scopyRenderState.unifiedErrorReason : ''
            };
            return JSON.stringify(info);
          } catch (e) {
            return "debugError:" + (e && e.message ? e.message : String(e));
          }
        })();
        """
        return try await evaluateJavaScriptString(webView: webView, javaScriptString: js)
    }

    /// Waits for the layout to settle after a change and returns the larger of the estimate and the live measurement.
    private func reconcileExportHeightPoints(
        webView: WKWebView,
        estimatedHeightPoints: CGFloat
    ) async throws -> CGFloat {
        let mark = (try? await readLayoutSample(webView: webView))?.frames ?? 0
        let settled = try await awaitLayoutSettled(webView: webView, sinceFrame: mark, requireRenderReady: false, timeout: 1.0)
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
        guard let debug = try? await layoutDebugInfo(webView: webView),
              let scale = Self.parseNumberFromLayoutDebugInfo(debug, key: "exportScale"),
              scale > 0
        else {
            return 1
        }

        return scale
    }

    nonisolated private static func parseHeightsFromLayoutDebugInfo(_ value: String) -> [CGFloat] {
        guard let data = value.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        let keys = [
            "contentScrollHeight",
            "contentRectHeight"
        ]

        return keys.compactMap { key in
            if let number = obj[key] as? NSNumber { return max(0, CGFloat(truncating: number)) }
            if let double = obj[key] as? Double { return max(0, CGFloat(double)) }
            if let int = obj[key] as? Int { return max(0, CGFloat(int)) }
            if let string = obj[key] as? String, let value = Double(string) { return max(0, CGFloat(value)) }
            return nil
        }
    }

    nonisolated private static func parseNumberFromLayoutDebugInfo(_ value: String, key: String) -> CGFloat? {
        guard let data = value.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let number = obj[key] as? NSNumber { return max(0, CGFloat(truncating: number)) }
        if let double = obj[key] as? Double { return max(0, CGFloat(double)) }
        if let int = obj[key] as? Int { return max(0, CGFloat(int)) }
        if let string = obj[key] as? String, let value = Double(string) { return max(0, CGFloat(value)) }
        return nil
    }

    private func applyGlobalScale(webView: WKWebView, scale: CGFloat) async throws {
        let frameMark = (try? await readLayoutSample(webView: webView))?.frames ?? 0
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
            var browserZoom = 1;
            try {
              var rawZoom = window.getComputedStyle(document.documentElement).getPropertyValue('--scopy-chatgpt-browser-zoom');
              browserZoom = parseFloat(rawZoom) || 1;
            } catch (e) { browserZoom = 1; }
            if (!browserZoom || !isFinite(browserZoom) || browserZoom <= 0) { browserZoom = 1; }

            // Scopy-rendered Markdown has an explicit fixed-width layout shell. Keep that width stable while applying
            // export scale so paragraph wrapping and table column measurement stay aligned with preview/ChatGPT.
            // Legacy raw HTML exports do not have the shell, so keep their historical width compensation to avoid
            // blank right margins in WebKit's PDF rasterization path.
            try {
              var preservesScopyLayoutWidth = false;
              try { preservesScopyLayoutWidth = !!document.getElementById('content-scale-shell'); } catch (e) { preservesScopyLayoutWidth = false; }
              content.style.transformOrigin = 'top left';
              content.style.transform = 'scale(' + (browserZoom * nextScale) + ')';

              // Prefer an explicit pixel width for the unscaled layout. Very large percentage widths can be clamped or
              // handled inconsistently by WebKit's PDF pipeline, resulting in a blank right margin after scaling.
              var viewportW = 0;
              try { viewportW = Math.ceil(window.innerWidth || 0); } catch (e) { viewportW = 0; }
              if (!viewportW || !isFinite(viewportW) || viewportW <= 0) {
                try { viewportW = Math.ceil((document.documentElement && document.documentElement.clientWidth) ? document.documentElement.clientWidth : 0); } catch (e) { viewportW = 0; }
              }
              var widthPx = 0;
              if (viewportW && isFinite(viewportW) && viewportW > 0) {
                if (preservesScopyLayoutWidth) {
                  try { widthPx = Math.max(1, Math.ceil(content.clientWidth || content.offsetWidth || 0)); } catch (e) { widthPx = 0; }
                  if (!widthPx || !isFinite(widthPx) || widthPx <= 0) {
                    try {
                      var rawRenderWidth = window.getComputedStyle(document.documentElement).getPropertyValue('--scopy-chatgpt-render-width');
                      widthPx = Math.max(1, Math.ceil(parseFloat(rawRenderWidth) || 0));
                    } catch (e) { widthPx = 0; }
                  }
                  if (!widthPx || !isFinite(widthPx) || widthPx <= 0) {
                    widthPx = Math.max(1, Math.ceil(viewportW));
                  }
                } else if (nextScale === 1) {
                  widthPx = Math.max(1, Math.ceil(viewportW));
                } else {
                  widthPx = Math.max(1, Math.ceil(viewportW / nextScale));
                }
              }
              if (widthPx > 0) {
                content.style.setProperty('width', widthPx + 'px', 'important');
                content.style.setProperty('max-width', widthPx + 'px', 'important');
              } else {
                var widthPercent = (preservesScopyLayoutWidth || nextScale === 1) ? 100 : Math.max(1, (100 / nextScale));
                content.style.setProperty('width', widthPercent + '%', 'important');
                content.style.setProperty('max-width', widthPercent + '%', 'important');
              }
              content.style.display = 'block';
              try {
                var shell = document.getElementById('content-scale-shell');
                if (shell && shell.style) {
                  var rawHeight = Math.ceil(content.scrollHeight || content.offsetHeight || 0);
                  if (rawHeight && isFinite(rawHeight) && rawHeight > 0) {
                    shell.style.height = Math.ceil(rawHeight * browserZoom * nextScale) + 'px';
                  }
                }
              } catch (e) { }
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
        _ = try? await awaitLayoutSettled(webView: webView, sinceFrame: frameMark, requireRenderReady: false, timeout: 1.5)
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
        await waitForAnimationFrames(webView: webView, count: 2, timeout: 0.5)
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

    // MARK: - Layout settle watcher

    /// A page-side animation-frame watcher: it measures the export height every frame and counts how many
    /// consecutive frames it has been unchanged, so Swift can wait for layout to settle instead of sleeping.
    private static let layoutWatcherJS = """
    (function() {
      try {
        if (window.__scopyLayoutWatcher) { return true; }
        var w = { frames: 0, stableFrames: 0, height: 0, live: 0, lastHeight: -1, lastLive: -1, fonts: 'n/a',
                  renderReady: false, renderFailed: false, renderErrorReason: '', hasContent: false };
        window.__scopyLayoutWatcher = w;
        function measureHeight() {
          var c = document.getElementById('content');
          if (!c) { w.hasContent = false; return 0; }
          w.hasContent = true;
          var rectH = 0;
          try {
            var shell = document.getElementById('content-scale-shell') || c;
            var r = shell.getBoundingClientRect();
            rectH = Math.ceil(r.height || 0);
          } catch (e) { rectH = 0; }
          var sh = 0;
          try { sh = Math.ceil(c.scrollHeight || 0); } catch (e) { sh = 0; }
          // Prefer #content measurements so short content is not padded to the viewport height.
          var useTransform = !!window.__scopyExportUsesTransform;
          return Math.ceil((useTransform && rectH > 0) ? rectH : Math.max(rectH || 0, sh || 0));
        }
        function measureLive() {
          var c = document.getElementById('content');
          if (!c) { return 0; }
          var exportScale = window.__scopyExportScale || 1;
          var rectH = 0;
          try { rectH = Math.ceil(c.getBoundingClientRect().height || 0); } catch (e) { rectH = 0; }
          if (exportScale > 0 && Math.abs(exportScale - 1) > 0.001 && rectH > 0) { return rectH; }
          var sh = 0;
          try { sh = c.scrollHeight || 0; } catch (e) { sh = 0; }
          return Math.max(sh, rectH);
        }
        function tick() {
          w.frames += 1;
          var h = 0; try { h = measureHeight(); } catch (e) { h = 0; }
          var live = 0; try { live = measureLive(); } catch (e) { live = 0; }
          var ready = true;
          try { if (typeof window.__scopyIsRenderReady === 'function') { ready = !!window.__scopyIsRenderReady(); } } catch (e) { ready = true; }
          var state = window.__scopyRenderState || {};
          w.renderFailed = !!state.renderFailed;
          w.renderErrorReason = state.unifiedErrorReason || '';
          try { w.fonts = (document.fonts && document.fonts.status) ? document.fonts.status : 'n/a'; } catch (e) { w.fonts = 'n/a'; }
          if (ready && h > 0 && w.lastHeight >= 0 && Math.abs(h - w.lastHeight) < 1 && Math.abs(live - w.lastLive) < 1) {
            w.stableFrames += 1;
          } else {
            w.stableFrames = 0;
          }
          w.lastHeight = h; w.lastLive = live; w.height = h; w.live = live; w.renderReady = ready;
          window.requestAnimationFrame(tick);
        }
        window.requestAnimationFrame(tick);
        return true;
      } catch (e) { return false; }
    })();
    """

    private static let readLayoutWatcherJS = """
    (function() {
      var w = window.__scopyLayoutWatcher;
      if (!w) { return JSON.stringify({ installed: false }); }
      return JSON.stringify({ installed: true, frames: w.frames, stableFrames: w.stableFrames, height: w.height, live: w.live,
        fonts: w.fonts, renderReady: w.renderReady, renderFailed: w.renderFailed, renderErrorReason: w.renderErrorReason });
    })();
    """

    struct LayoutSample {
        let frames: Int
        let stableFrames: Int
        let height: CGFloat
        let liveHeight: CGFloat
        let fonts: String
        let renderReady: Bool
        let renderFailed: Bool
        let renderErrorReason: String?
    }

    private func installLayoutWatcher(webView: WKWebView) async throws {
        let installed = try await evaluateJavaScriptBool(webView: webView, javaScriptString: Self.layoutWatcherJS)
        guard installed else {
            throw NSError(
                domain: "Scopy.MarkdownExport",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Layout watcher could not be installed"]
            )
        }
    }

    private func readLayoutSample(webView: WKWebView) async throws -> LayoutSample {
        for _ in 0..<2 {
            let value = try await evaluateJavaScriptString(webView: webView, javaScriptString: Self.readLayoutWatcherJS)
            guard let data = value.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(
                    domain: "Scopy.MarkdownExport",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Layout watcher returned an unreadable sample: \(value.prefix(120))"]
                )
            }
            if (object["installed"] as? Bool) == true {
                func number(_ key: String) -> CGFloat {
                    if let n = object[key] as? NSNumber { return CGFloat(truncating: n) }
                    return 0
                }
                let reason = (object["renderErrorReason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return LayoutSample(
                    frames: Int(number("frames")),
                    stableFrames: Int(number("stableFrames")),
                    height: max(0, number("height")),
                    liveHeight: max(0, number("live")),
                    fonts: (object["fonts"] as? String) ?? "n/a",
                    renderReady: (object["renderReady"] as? Bool) ?? false,
                    renderFailed: (object["renderFailed"] as? Bool) ?? false,
                    renderErrorReason: (reason?.isEmpty ?? true) ? nil : reason
                )
            }
            // The page navigated or the world was reset; reinstall and read again.
            try await installLayoutWatcher(webView: webView)
        }
        throw NSError(
            domain: "Scopy.MarkdownExport",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Layout watcher did not report after reinstall"]
        )
    }

    /// Polls the watcher until at least two animation frames have run after `sinceFrame` and the measured height has
    /// been unchanged for `stableFrames` consecutive frames. When animation frames stop (occluded view), stability
    /// falls back to the height being unchanged for 0.45 s. Returns the last sample either way; `isSettled` tells
    /// whether the condition was met before `timeout`.
    private func awaitLayoutSettled(
        webView: WKWebView,
        sinceFrame: Int,
        stableFrames: Int = 3,
        requireRenderReady: Bool,
        timeout: TimeInterval
    ) async throws -> (sample: LayoutSample, isSettled: Bool) {
        let deadline = CFAbsoluteTimeGetCurrent() + max(0, timeout)
        var lastFrames = -1
        var framesChangedAt = CFAbsoluteTimeGetCurrent()
        var lastHeight: CGFloat = -1
        var heightStableSince = CFAbsoluteTimeGetCurrent()
        while true {
            let sample = try await readLayoutSample(webView: webView)
            let now = CFAbsoluteTimeGetCurrent()
            if sample.renderFailed {
                let error = NSError(
                    domain: "Scopy.MarkdownExport",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: sample.renderErrorReason ?? "Markdown renderer failed"]
                )
                throw MarkdownExportService.ExportError.stageFailed(stage: .prepareLayout, underlying: error)
            }
            if sample.frames != lastFrames {
                lastFrames = sample.frames
                framesChangedAt = now
            }
            if abs(sample.height - lastHeight) >= 1 {
                lastHeight = sample.height
                heightStableSince = now
            }
            let ready = !requireRenderReady || sample.renderReady
            if ready, sample.height > 0 {
                if sample.frames >= sinceFrame + 2, sample.stableFrames >= stableFrames {
                    return (sample, true)
                }
                if now - framesChangedAt > 0.3, now - heightStableSince >= 0.45 {
                    MarkdownExportService.logger.info("Layout watcher frames stalled; accepting time-based stability")
                    return (sample, true)
                }
            }
            if now >= deadline {
                return (sample, false)
            }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    /// Waits until `count` animation frames have run after the call; best effort, bounded by `timeout`.
    private func waitForAnimationFrames(webView: WKWebView, count: Int, timeout: TimeInterval) async {
        guard let start = try? await readLayoutSample(webView: webView) else {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return
        }
        let deadline = CFAbsoluteTimeGetCurrent() + max(0, timeout)
        while CFAbsoluteTimeGetCurrent() < deadline {
            try? await Task.sleep(nanoseconds: 8_000_000)
            guard let sample = try? await readLayoutSample(webView: webView) else { return }
            if sample.frames >= start.frames + count { return }
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

    /// Hands the bitmap to pngquant as raw pixels; falls back to ImageIO's PNG encoder when pngquant is
    /// disabled or declines the image.
    /// Encodes the finished canvas: pngquant maps the canvas file directly; ImageIO encodes the bitmap only when
    /// pngquant is disabled or declines the quality floor.
    nonisolated static func encodeExportCanvas(
        _ canvas: ExportBitmapCanvas,
        pngquantOptions: PngquantService.Options?
    ) throws -> MarkdownExportService.ExportOutcome {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        canvas.trimBlankLeadingRowsIfNeeded()
        let pixels = canvas.width * canvas.height
        if let pngquantOptions {
            do {
                try canvas.finalizeFile()
                if let quantized = PngquantService.compressPAMFileBestEffort(canvas.fileURL, options: pngquantOptions) {
                    logEncodeDuration(since: startedAt, pixels: pixels, bytes: quantized.count, encoder: "pngquant")
                    return MarkdownExportService.ExportOutcome(
                        pngData: quantized,
                        stats: MarkdownExportService.ExportStats(finalPNGBytes: quantized.count, pngquantApplied: true)
                    )
                }
            } catch {
                MarkdownExportService.logger.warning("Export canvas could not be finalized for pngquant: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let image = canvas.makeImage() else {
            throw MarkdownExportService.ExportError.stageFailed(stage: .pngEncoding, underlying: nil)
        }
        let png = try pngDataFromCGImage(image)
        logEncodeDuration(since: startedAt, pixels: pixels, bytes: png.count, encoder: "ImageIO")
        return MarkdownExportService.ExportOutcome(
            pngData: png,
            stats: MarkdownExportService.ExportStats(finalPNGBytes: png.count, pngquantApplied: false)
        )
    }

    nonisolated private static func logEncodeDuration(since startedAt: UInt64, pixels: Int, bytes: Int, encoder: StaticString) {
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds &- startedAt) / 1_000_000
        MarkdownExportService.logger.info(
            "Encoded export PNG via \(encoder, privacy: .public): \(pixels, privacy: .public) px -> \(bytes, privacy: .public) bytes in \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms"
        )
    }

    /// Draws the snapshot onto a white canvas at the target width in one pass, scaling when the snapshot's backing
    /// scale does not match the requested output width.
    nonisolated private static func canvasFromSnapshot(_ image: CGImage, targetWidthPixels: Int) throws -> ExportBitmapCanvas {
        let sourceWidth = image.width
        let sourceHeight = image.height
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw MarkdownExportService.ExportError.stageFailed(stage: .imageConversion, underlying: nil)
        }
        let width = max(1, targetWidthPixels)
        let height = sourceWidth == width
            ? sourceHeight
            : max(1, Int(round(CGFloat(sourceHeight) * CGFloat(width) / CGFloat(sourceWidth))))
        let canvas = try ExportBitmapCanvas.make(width: width, height: height, stage: .imageConversion)
        try canvas.drawInParallelBands { context, bounds in
            context.interpolationQuality = .high
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(bounds)
            context.draw(image, in: bounds)
        }
        return canvas
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

    nonisolated private static func rasterizePDFDataToCanvas(
        pdfData: Data,
        targetWidthPixels: Int,
        expectedPageWidthPoints: CGFloat?,
        contentScaleCompensation: CGFloat
    ) throws -> ExportBitmapCanvas {
        guard targetWidthPixels > 0 else {
            throw MarkdownExportService.ExportError.stageFailed(stage: .rasterizePDF, underlying: nil)
        }

        guard let provider = CGDataProvider(data: pdfData as CFData),
              let doc = CGPDFDocument(provider),
              doc.numberOfPages >= 1
        else {
            throw MarkdownExportService.ExportError.stageFailed(stage: .rasterizePDF, underlying: nil)
        }

        struct PDFPageInfo {
            let page: CGPDFPage
            let boxType: CGPDFBox
            let box: CGRect
        }

        var pages: [PDFPageInfo] = []
        pages.reserveCapacity(doc.numberOfPages)
        var maxPageWidthPoints: CGFloat = 0
        for i in 1...doc.numberOfPages {
            guard let page = doc.page(at: i) else { continue }
            let crop = page.getBoxRect(.cropBox)
            let media = page.getBoxRect(.mediaBox)
            let box: CGRect
            let boxType: CGPDFBox
            if crop.width > 0, crop.height > 0 {
                box = crop
                boxType = .cropBox
            } else {
                box = media
                boxType = .mediaBox
            }
            if box.width > maxPageWidthPoints { maxPageWidthPoints = box.width }
            pages.append(PDFPageInfo(page: page, boxType: boxType, box: box))
        }

        guard !pages.isEmpty, maxPageWidthPoints > 0 else {
            throw MarkdownExportService.ExportError.stageFailed(stage: .rasterizePDF, underlying: nil)
        }

        // Use the actual PDF page boxes to drive scaling, to avoid creating a wider canvas than the content.
        // (Using an "expected width" can leave a blank right margin when WebKit's printable area is narrower.)
        _ = expectedPageWidthPoints // keep parameter for future diagnostics without affecting behavior.
        let scale = CGFloat(targetWidthPixels) / max(1, maxPageWidthPoints)
        let pageHeightsPixels: [Int] = pages.map { entry in
            max(1, Int(ceil(entry.box.height * scale)))
        }
        let totalHeightPixels = pageHeightsPixels.reduce(0, +)

        let totalPixels = CGFloat(targetWidthPixels) * CGFloat(totalHeightPixels)
        if totalPixels > MarkdownExportRenderConstants.maxTotalPixels + 0.5 {
            throw MarkdownExportService.ExportError.exportLimitExceeded(
                reason: "PDF rasterization too large (w=\(targetWidthPixels)px, h=\(totalHeightPixels)px, total=\(Int(totalPixels))px)"
            )
        }

        let canvas = try ExportBitmapCanvas.make(
            width: targetWidthPixels,
            height: totalHeightPixels,
            stage: .rasterizePDF
        )
        let ctx = canvas.context

        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(targetWidthPixels), height: CGFloat(totalHeightPixels)))

        var yCursor = totalHeightPixels
        for (index, entry) in pages.enumerated() {
            let page = entry.page
            let box = entry.box
            let pageHeightPixels = pageHeightsPixels[index]
            yCursor -= pageHeightPixels

            ctx.saveGState()
            let pageWidthPixels = max(1, Int(ceil(box.width * scale)))
            let targetRect = CGRect(
                x: 0,
                y: CGFloat(yCursor),
                width: CGFloat(pageWidthPixels),
                height: CGFloat(pageHeightPixels)
            )
            // macOS WebKit can embed PDF page contents at ~0.5 scale (centered with blank margins) on Retina displays.
            // Compensate during rasterization so the final PNG matches on-screen layout.
            let baseTransform = entry.page.getDrawingTransform(entry.boxType, rect: targetRect, rotate: 0, preserveAspectRatio: true)
            let transform: CGAffineTransform
            if contentScaleCompensation > 1.001 {
                let centerX = box.midX
                let centerY = box.midY
                let extra = CGAffineTransform(translationX: centerX, y: centerY)
                    .scaledBy(x: contentScaleCompensation, y: contentScaleCompensation)
                    .translatedBy(x: -centerX, y: -centerY)
                transform = extra.concatenating(baseTransform)
            } else {
                transform = baseTransform
            }
            ctx.concatenate(transform)
            ctx.drawPDFPage(page)
            ctx.restoreGState()
        }

        return canvas
    }

    private struct PDFRasterMetrics: Sendable {
        let totalHeightPixels: Int
        let totalPixels: CGFloat
    }

    nonisolated private static func pdfRasterMetrics(pdfData: Data, targetWidthPixels: Int) throws -> PDFRasterMetrics {
        guard targetWidthPixels > 0 else {
            throw MarkdownExportService.ExportError.stageFailed(stage: .rasterizePDF, underlying: nil)
        }

        guard let provider = CGDataProvider(data: pdfData as CFData),
              let doc = CGPDFDocument(provider),
              doc.numberOfPages >= 1
        else {
            throw MarkdownExportService.ExportError.stageFailed(stage: .rasterizePDF, underlying: nil)
        }

        var maxPageWidthPoints: CGFloat = 0
        var totalHeightPixels = 0
        for index in 1...doc.numberOfPages {
            guard let page = doc.page(at: index) else { continue }
            let crop = page.getBoxRect(.cropBox)
            let media = page.getBoxRect(.mediaBox)
            let box = (crop.width > 0 && crop.height > 0) ? crop : media
            if box.width > maxPageWidthPoints { maxPageWidthPoints = box.width }
        }

        guard maxPageWidthPoints > 0 else {
            throw MarkdownExportService.ExportError.stageFailed(stage: .rasterizePDF, underlying: nil)
        }

        let scale = CGFloat(targetWidthPixels) / max(1, maxPageWidthPoints)
        for index in 1...doc.numberOfPages {
            guard let page = doc.page(at: index) else { continue }
            let crop = page.getBoxRect(.cropBox)
            let media = page.getBoxRect(.mediaBox)
            let box = (crop.width > 0 && crop.height > 0) ? crop : media
            totalHeightPixels += max(1, Int(ceil(box.height * scale)))
        }

        return PDFRasterMetrics(
            totalHeightPixels: totalHeightPixels,
            totalPixels: CGFloat(targetWidthPixels) * CGFloat(totalHeightPixels)
        )
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
        Self.concurrencyGate.finish(id: concurrencyID)
    }

}
