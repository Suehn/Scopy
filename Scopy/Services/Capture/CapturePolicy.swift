import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pure capture decisions: the dedup key, temporary-image and Office/table sniffing, and the
/// stored form of a file capture. No pasteboard access.
enum CapturePolicy {
    /// Central dedup key policy, shared by small-content capture and durable ingest replay.
    static func contentHash(
        type: ClipboardItemType,
        plainText: String,
        payloadData: Data?,
        precomputedHash: String?
    ) -> String {
        if let precomputedHash {
            return precomputedHash
        }

        // Text, RTF and HTML intentionally deduplicate by normalized visible text. File
        // captures need a distinct namespace because the same path string has different
        // replay semantics when copied as plain text.
        switch type {
        case .text, .rtf, .html:
            if !plainText.isEmpty {
                return ClipboardMonitor.computeHashStatic(Data(plainText.utf8))
            }
            if let payloadData {
                return ClipboardMonitor.computeHashStatic(payloadData)
            }
            return ClipboardMonitor.computeHashStatic(Data())
        case .file:
            return "file:" + ClipboardMonitor.computeHashStatic(Data(plainText.utf8))
        case .image:
            if let payloadData {
                return ClipboardMonitor.computeHashStatic(payloadData)
            }
            return ClipboardMonitor.computeHashStatic(Data(plainText.utf8))
        case .other:
            if let payloadData {
                return ClipboardMonitor.computeHashStatic(payloadData)
            }
            return ClipboardMonitor.computeHashStatic(Data(plainText.utf8))
        }
    }

    /// Stored payload of a file capture: a JSON array of paths. Paths rather than
    /// `absoluteString`, so replay rebuilds file URLs without a `file://` round trip.
    static func serializeFileURLs(_ urls: [URL]) -> Data? {
        do {
            let paths = urls.map { $0.path }
            return try JSONEncoder().encode(paths)
        } catch {
            ScopyLog.monitor.error("Failed to serialize file URLs: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    static func isLikelyTemporaryImageFileURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let ext = url.pathExtension.lowercased()
        let imageExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"
        ]
        guard imageExtensions.contains(ext) else { return false }

        let path = url.standardizedFileURL.path.lowercased()
        if path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") { return true }
        if path.contains("/var/folders/") { return true }
        if path.contains("/library/caches/") { return true }
        if path.contains("/library/containers/com.tencent.xinwechat/"),
           (path.contains("/temp/") || path.contains("/rwtemp/") || path.contains("/xwechat_files/")) {
            return true
        }
        if path.contains("/xwechat_files/"),
           (path.contains("/temp/") || path.contains("/rwtemp/")) {
            return true
        }
        return false
    }

    static func htmlLooksLikeOfficeSpreadsheet(_ htmlData: Data) -> Bool {
        // Only the first 16 KB is scanned, so a large table costs nothing extra.
        let sample = String(decoding: htmlData.prefix(16 * 1024), as: UTF8.self).lowercased()

        // Browsers and design tools copy images as `<img …>`, sometimes inside a table; those
        // stay images.
        if sample.contains("<img") { return false }

        // Any one Excel/Office signature is enough.
        if sample.contains("urn:schemas-microsoft-com:office:excel") { return true }
        if sample.contains("microsoft excel") { return true }
        if sample.contains("mso-") { return true }

        // Fallback: an explicit table structure, which copied Excel cells always carry.
        if sample.contains("<table") && (sample.contains("<td") || sample.contains("<tr")) {
            return true
        }

        return false
    }

    static func rtfLooksLikeTable(_ rtfData: Data) -> Bool {
        let sample = String(decoding: rtfData.prefix(16 * 1024), as: UTF8.self).lowercased()
        // RTF tables carry the \trowd / \cell control words.
        return sample.contains("\\trowd") || sample.contains("\\cell")
    }

    static func stringLooksLikeTabularData(_ string: String) -> Bool {
        // Copied Excel/Sheets cells arrive as TSV. Line count alone is not a signal: an image
        // copied together with a multi-line description would be misread as a table.
        return string.contains("\t")
    }
}

// Image and hash helpers that ClipboardService, StorageService and their tests reference as
// `ClipboardMonitor.…`; they need no monitor state.
extension ClipboardMonitor {
    /// SHA-256 hex digest: the content hash of every stored item.
    public nonisolated static func computeHashStatic(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Re-encodes TIFF as PNG before storage: screenshots reach the pasteboard as uncompressed
    /// TIFF, up to 35x the size of the PNG.
    nonisolated static func convertTIFFToPNG(_ tiffData: Data) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(tiffData as CFData, nil) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImageFromSource(destination, imageSource, 0, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// PNG bytes of a temporary image file that accompanies an image copy, or nil when the
    /// file is not such a temporary image.
    nonisolated static func loadImageFileDataAsPNG(_ url: URL) -> Data? {
        guard CapturePolicy.isLikelyTemporaryImageFileURL(url) else { return nil }

        let fileData: Data
        do {
            fileData = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            return nil
        }

        if PngquantService.isLikelyPNG(fileData) {
            return fileData
        }

        return convertTIFFToPNG(fileData)
    }
}
