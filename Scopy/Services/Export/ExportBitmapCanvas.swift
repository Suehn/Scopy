import AppKit
import Darwin
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers
import WebKit

/// The export bitmap is a PAM (`P7`, 8-bit `RGB_ALPHA`) file in a private temporary directory whose pixel rows are
/// memory-mapped: every export path draws straight into the file pngquant maps afterwards, so the pixels are never
/// copied. The header occupies a fixed-size region so the height can be rewritten in place after trimming.
final class ExportBitmapStorage {
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

final class ManagedAtomic: @unchecked Sendable {
    private var value: Bool
    private let lock = NSLock()
    init(_ value: Bool) { self.value = value }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// A white-background RGBA8 drawing surface backed by `ExportBitmapStorage`. Rows are stored top-down.
final class ExportBitmapCanvas: @unchecked Sendable {
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
        /// Each band writes only its own rows of the shared buffer.
        struct BandedPixels: @unchecked Sendable { let base: UnsafeMutableRawPointer }
        let pixels = BandedPixels(base: self.pixels)
        let failed = ManagedAtomic(false)
        DispatchQueue.concurrentPerform(iterations: bandCount) { band in
            let startRow = band * rowsPerBand
            let bandRows = min(rowsPerBand, height - startRow)
            guard bandRows > 0 else { return }
            guard let context = CGContext(
                data: pixels.base.advanced(by: startRow * bytesPerRow),
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

extension ExportCoordinator {
    /// Encodes the finished canvas: pngquant maps the canvas file directly; ImageIO encodes the bitmap only when
    /// pngquant is disabled or declines the quality floor.
    nonisolated static func encodeExportCanvas(
        _ canvas: ExportBitmapCanvas,
        pngquantOptions: PngquantService.Options?
    ) throws -> MarkdownExportService.ExportOutcome {
        canvas.trimBlankLeadingRowsIfNeeded()
        if let pngquantOptions {
            do {
                try canvas.finalizeFile()
                if let quantized = PngquantService.compressPAMFileBestEffort(canvas.fileURL, options: pngquantOptions) {
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
        return MarkdownExportService.ExportOutcome(
            pngData: png,
            stats: MarkdownExportService.ExportStats(finalPNGBytes: png.count, pngquantApplied: false)
        )
    }

    /// Draws the snapshot onto a white canvas at the target width in one pass, scaling when the snapshot's backing
    /// scale does not match the requested output width.
    nonisolated static func canvasFromSnapshot(_ image: CGImage, targetWidthPixels: Int) throws -> ExportBitmapCanvas {
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

    nonisolated static func pngDataFromCGImage(_ image: CGImage) throws -> Data {
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

    nonisolated static func rasterizePDFDataToCanvas(
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

    struct PDFRasterMetrics: Sendable {
        let totalHeightPixels: Int
        let totalPixels: CGFloat
    }

    nonisolated static func pdfRasterMetrics(pdfData: Data, targetWidthPixels: Int) throws -> PDFRasterMetrics {
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


    nonisolated static func scaleCGImageIfNeeded(image: CGImage, targetWidthPixels: Int) -> CGImage {
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
}
