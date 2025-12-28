import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

public enum FilePreviewKind: String, Sendable {
    case image
    case video
    case other
}

public struct FilePreviewInfo: Sendable {
    public let url: URL
    public let kind: FilePreviewKind
}

public enum FilePreviewSupport {
    private static let markdownTypes: [UTType] = {
        var types: [UTType] = []
        if let type = UTType("net.daringfireball.markdown") {
            types.append(type)
        }
        if let type = UTType("public.markdown") {
            types.append(type)
        }
        return types
    }()

    public static func isMarkdownFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if let type = UTType(filenameExtension: ext),
           markdownTypes.contains(where: { type.conforms(to: $0) }) {
            return true
        }
        switch ext {
        case "md", "markdown", "mdown", "mkd", "mkdn":
            return true
        default:
            return false
        }
    }

    public static func previewInfo(from plainText: String, requireExists: Bool = true) -> FilePreviewInfo? {
        guard let url = primaryFileURL(from: plainText, requireExists: requireExists) else { return nil }
        return FilePreviewInfo(url: url, kind: kind(for: url))
    }

    public static func primaryFileURL(from plainText: String, requireExists: Bool = true) -> URL? {
        var start = plainText.startIndex
        while start < plainText.endIndex {
            var end = start
            while end < plainText.endIndex, !plainText[end].isNewline {
                end = plainText.index(after: end)
            }

            if start != end {
                let rawLine = plainText[start..<end]
                let path = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = parseFileURL(from: path) {
                    if requireExists {
                        var isDirectory: ObjCBool = false
                        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                           !isDirectory.boolValue {
                            return url
                        }
                    } else {
                        return url
                    }
                }
            }

            start = end
            while start < plainText.endIndex, plainText[start].isNewline {
                start = plainText.index(after: start)
            }
        }
        return nil
    }

    public static func primaryFilePath(from plainText: String) -> String? {
        primaryFileURL(from: plainText, requireExists: false)?.path
    }

    public static func fileURLs(from plainText: String, requireExists: Bool = true) -> [URL] {
        var urls: [URL] = []
        urls.reserveCapacity(2)

        for line in plainText.split(whereSeparator: \.isNewline) {
            let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = parseFileURL(from: path) else { continue }
            if requireExists {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
                guard !isDirectory.boolValue else { continue }
            }
            urls.append(url)
        }
        return urls
    }

    public static func totalFileSizeBytes(from plainText: String) -> Int? {
        let urls = fileURLs(from: plainText, requireExists: true)
        guard !urls.isEmpty else { return nil }
        var total = 0
        var didRead = false
        for url in urls {
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += size
                didRead = true
            }
        }
        return didRead ? total : nil
    }

    public static func readTextFile(url: URL, maxBytes: Int) -> String? {
        guard maxBytes > 0 else { return nil }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
           size > maxBytes {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer {
            try? handle.close()
        }
        // Read a small prefix so we never pull huge files into memory when `fileSizeKey` is unavailable.
        let data: Data
        do {
            data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        } catch {
            return nil
        }
        guard data.count <= maxBytes else { return nil }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let utf16 = String(data: data, encoding: .utf16) {
            return utf16
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func kind(for url: URL) -> FilePreviewKind {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) {
            return .image
        }
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            return .video
        }
        return .other
    }

    public static func shouldGenerateThumbnail(for url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        if type.conforms(to: .image) {
            return true
        }
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            return true
        }
        if type.conforms(to: .pdf) {
            return true
        }
        return false
    }

    public static func loadVideoNaturalSize(from url: URL) async -> CGSize? {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            guard let track = asset.tracks(withMediaType: .video).first else { return nil }
            let transformed = track.naturalSize.applying(track.preferredTransform)
            let width = abs(transformed.width)
            let height = abs(transformed.height)
            guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
            return CGSize(width: width, height: height)
        }.value
    }

    private static func parseFileURL(from rawPath: String) -> URL? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.isFileURL {
            return url
        }
        if trimmed.hasPrefix("file://") {
            let prefix = "file://"
            var stripped = String(trimmed.dropFirst(prefix.count))
            if stripped.hasPrefix("localhost/") {
                stripped = String(stripped.dropFirst("localhost/".count))
            }
            if !stripped.hasPrefix("/") {
                stripped = "/" + stripped
            }
            let decoded = stripped.removingPercentEncoding ?? stripped
            return URL(fileURLWithPath: decoded)
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    public static func makeVideoThumbnailPNG(from url: URL, maxHeight: Int) -> Data? {
        guard maxHeight > 0 else { return nil }
        guard let cgImage = makeVideoPreviewCGImage(from: url, maxSidePixels: maxHeight) else { return nil }
        return makePNGData(from: cgImage)
    }

    public static func makeVideoPreviewCGImage(from url: URL, maxSidePixels: Int) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let maxSide = max(1, maxSidePixels)
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        do {
            return try generator.copyCGImage(at: time, actualTime: nil)
        } catch {
            return nil
        }
    }

    public static func makeQuickLookThumbnailPNG(
        from url: URL,
        maxSidePixels: Int,
        scale: CGFloat
    ) async -> Data? {
        guard let cgImage = await makeQuickLookPreviewCGImage(from: url, maxSidePixels: maxSidePixels, scale: scale) else {
            return nil
        }
        return makePNGData(from: cgImage)
    }

    public static func makeQuickLookPreviewCGImage(
        from url: URL,
        maxSidePixels: Int,
        scale: CGFloat
    ) async -> CGImage? {
        guard maxSidePixels > 0 else { return nil }
        let scaleFactor = max(1, scale)
        let sidePoints = max(1, CGFloat(maxSidePixels) / scaleFactor)
        let size = CGSize(width: sidePoints, height: sidePoints)

        return await withCheckedContinuation { continuation in
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: size,
                scale: scaleFactor,
                representationTypes: .all
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                if let cgImage = representation?.cgImage {
                    continuation.resume(returning: cgImage)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func makePNGData(from cgImage: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
