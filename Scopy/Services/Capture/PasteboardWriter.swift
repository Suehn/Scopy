import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension ClipboardMonitor {
    public enum ImagePasteboardWriteMode: Sendable {
        case standard
        case codexOptimized
    }

    /// Why a pasteboard write produced nothing usable.
    ///
    /// A failed write leaves the previous clipboard content in place, so these must reach the
    /// caller rather than a log line.
    public enum PasteboardWriteFailure: Error, Equatable {
        /// The bytes could not be turned into a pasteboard image representation.
        case imageNotRenderable
        /// `NSPasteboard` refused the primary representation.
        case rejectedByPasteboard
    }

    public func copyToClipboard(text: String) throws {
        pasteboard.clearContents()
        defer { recordOwnWrite() }
        guard pasteboard.setString(text, forType: .string) else {
            throw PasteboardWriteFailure.rejectedByPasteboard
        }
    }

    public func copyToClipboard(
        data: Data,
        type: NSPasteboard.PasteboardType,
        imageWriteMode: ImagePasteboardWriteMode = .standard
    ) throws {
        if type == .png {
            guard let imagePayload = Self.makeImagePasteboardPayloadForWrite(data, imageWriteMode: imageWriteMode) else {
                throw PasteboardWriteFailure.imageNotRenderable
            }

            pasteboard.clearContents()
            defer { recordOwnWrite() }
            let declaredTypes: [NSPasteboard.PasteboardType] = imagePayload.compatibilityTIFFData == nil ? [.png] : [.png, .tiff]
            pasteboard.declareTypes(declaredTypes, owner: nil)

            guard pasteboard.setData(imagePayload.primaryPNGData, forType: .png) else {
                throw PasteboardWriteFailure.rejectedByPasteboard
            }

            // The primary PNG is on the pasteboard; a missing compatibility fallback narrows the
            // set of readers, it does not fail the copy.
            if let tiffData = imagePayload.compatibilityTIFFData,
               !pasteboard.setData(tiffData, forType: .tiff) {
                ScopyLog.monitor.warning("Failed to write TIFF fallback for PNG payload")
            }
            return
        }

        pasteboard.clearContents()
        defer { recordOwnWrite() }
        guard pasteboard.setData(data, forType: type) else {
            throw PasteboardWriteFailure.rejectedByPasteboard
        }
    }

    public func copyToClipboard(
        imageData data: Data,
        fileURL: URL,
        imageWriteMode: ImagePasteboardWriteMode = .standard
    ) throws {
        guard let imagePayload = Self.makeImagePasteboardPayloadForWrite(data, imageWriteMode: imageWriteMode) else {
            throw PasteboardWriteFailure.imageNotRenderable
        }

        pasteboard.clearContents()
        defer { recordOwnWrite() }
        guard pasteboard.writeObjects([fileURL as NSURL]) else {
            ScopyLog.monitor.warning("Failed to write image file URL to pasteboard; falling back to PNG payload")
            try copyToClipboard(data: data, type: .png, imageWriteMode: imageWriteMode)
            return
        }

        let fileListType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        pasteboard.setPropertyList([fileURL.path], forType: fileListType)

        // The file URL is already on the pasteboard, so the copy succeeded; the inline
        // representations only widen reader compatibility.
        if pasteboard.setData(imagePayload.primaryPNGData, forType: .png) {
            if let tiffData = imagePayload.compatibilityTIFFData,
               !pasteboard.setData(tiffData, forType: .tiff) {
                ScopyLog.monitor.warning("Failed to add TIFF fallback for file-backed image pasteboard payload")
            }
        } else {
            ScopyLog.monitor.warning("Failed to add PNG fallback for file-backed image pasteboard payload")
        }
    }

    public func copyToClipboard(text: String, data: Data, type: NSPasteboard.PasteboardType) throws {
        pasteboard.clearContents()
        defer { recordOwnWrite() }

        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(data, forType: type)
        guard pasteboard.writeObjects([item]) else {
            throw PasteboardWriteFailure.rejectedByPasteboard
        }
    }

    struct ImagePasteboardPayload {
        let primaryPNGData: Data
        let compatibilityTIFFData: Data?
    }

    nonisolated static func makeImagePasteboardPayloadForWrite(
        _ data: Data,
        imageWriteMode: ImagePasteboardWriteMode
    ) -> ImagePasteboardPayload? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        let sourceType = CGImageSourceGetType(imageSource) as String?
        if sourceType == UTType.png.identifier {
            switch imageWriteMode {
            case .standard:
                return ImagePasteboardPayload(primaryPNGData: data, compatibilityTIFFData: nil)
            case .codexOptimized:
                if !Self.shouldAddTIFFFallbackForPNGReplay(data) {
                    return ImagePasteboardPayload(primaryPNGData: data, compatibilityTIFFData: nil)
                }
            }
        }

        if sourceType == UTType.png.identifier,
           let tiffData = Self.rasterizeCGImageToStandardTIFF(image) {
            // Keep the stored PNG bytes as the primary representation so replay
            // continues to prefer the pngquant result when available. Only add a
            // rasterized TIFF as a compatibility fallback for narrow readers.
            return ImagePasteboardPayload(primaryPNGData: data, compatibilityTIFFData: tiffData)
        }

        guard let pngData = Self.rasterizeCGImageToStandardPNG(image) else { return nil }
        return ImagePasteboardPayload(primaryPNGData: pngData, compatibilityTIFFData: nil)
    }

    nonisolated static func shouldAddTIFFFallbackForPNGReplay(_ pngData: Data) -> Bool {
        guard let metadata = Self.parsePNGHeaderForReplayPolicy(pngData) else { return true }

        switch metadata.colorType {
        case 2, 6:
            return metadata.bitDepth < 8
        default:
            return true
        }
    }

    private struct PNGReplayHeader {
        let bitDepth: UInt8
        let colorType: UInt8
    }

    nonisolated private static func parsePNGHeaderForReplayPolicy(_ data: Data) -> PNGReplayHeader? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= 33, data.prefix(signature.count).elementsEqual(signature) else { return nil }
        guard Self.pngUInt32(data, at: 8) == 13 else { return nil }
        guard Self.pngASCII(data, at: 12, length: 4) == "IHDR" else { return nil }

        guard let bitDepth = Self.pngByte(data, at: 24),
              let colorType = Self.pngByte(data, at: 25) else {
            return nil
        }
        return PNGReplayHeader(bitDepth: bitDepth, colorType: colorType)
    }

    nonisolated private static func pngByte(_ data: Data, at offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[data.startIndex + offset]
    }

    nonisolated private static func pngUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 3 < data.count else { return nil }
        guard let b0 = Self.pngByte(data, at: offset),
              let b1 = Self.pngByte(data, at: offset + 1),
              let b2 = Self.pngByte(data, at: offset + 2),
              let b3 = Self.pngByte(data, at: offset + 3) else {
            return nil
        }
        return (UInt32(b0) << 24) | (UInt32(b1) << 16) | (UInt32(b2) << 8) | UInt32(b3)
    }

    nonisolated private static func pngASCII(_ data: Data, at offset: Int, length: Int) -> String? {
        guard offset >= 0, length >= 0, offset + length <= data.count else { return nil }
        let range = (data.startIndex + offset)..<(data.startIndex + offset + length)
        return String(data: data.subdata(in: range), encoding: .ascii)
    }

    nonisolated private static func rasterizeCGImageToStandardPNG(_ image: CGImage) -> Data? {
        guard let context = Self.makeStandardRGBAContext(for: image) else { return nil }

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

    nonisolated private static func rasterizeCGImageToStandardTIFF(_ image: CGImage) -> Data? {
        guard let context = Self.makeStandardRGBAContext(for: image) else { return nil }

        let width = image.width
        let height = image.height
        context.interpolationQuality = CGInterpolationQuality.high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let rasterizedImage = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.tiff.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, rasterizedImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    nonisolated private static func makeStandardRGBAContext(for image: CGImage) -> CGContext? {
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

    /// Writes file URLs so Finder can paste them.
    public func copyToClipboard(fileURLs: [URL]) throws {
        pasteboard.clearContents()
        defer { recordOwnWrite() }

        guard pasteboard.writeObjects(fileURLs as [NSURL]) else {
            throw PasteboardWriteFailure.rejectedByPasteboard
        }

        // Finder still reads the legacy NSFilenamesPboardType next to the NSURL objects.
        let paths = fileURLs.map { $0.path }
        pasteboard.setPropertyList(paths, forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
    }
}
