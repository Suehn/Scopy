import Foundation

/// Presentation-only helpers for deriving display strings from `ClipboardItemDTO`.
///
/// Domain model should not carry UI-specific derived fields (e.g. title/metadata).
/// This cache keeps UI rendering cheap without bloating the DTO.
@MainActor
final class ClipboardItemDisplayText {
    static let shared = ClipboardItemDisplayText()

    private let titleCache: NSCache<NSString, NSString>
    private let metadataCache: NSCache<NSString, NSString>

    private init() {
        let titleCache = NSCache<NSString, NSString>()
        titleCache.countLimit = 10_000
        self.titleCache = titleCache

        let metadataCache = NSCache<NSString, NSString>()
        metadataCache.countLimit = 10_000
        self.metadataCache = metadataCache
    }

    func title(for item: ClipboardItemDTO) -> String {
        let key = titleCacheKey(for: item)
        if let cached = titleCache.object(forKey: key) {
            return cached as String
        }

        let computed = computeTitle(type: item.type, plainText: item.plainText)
        titleCache.setObject(computed as NSString, forKey: key)
        return computed
    }

    func metadata(for item: ClipboardItemDTO) -> String {
        let key = metadataCacheKey(for: item)
        if let cached = metadataCache.object(forKey: key) {
            return cached as String
        }

        let computed = computeMetadata(type: item.type, plainText: item.plainText, sizeBytes: item.sizeBytes)
        metadataCache.setObject(computed as NSString, forKey: key)
        return computed
    }

    private func titleCacheKey(for item: ClipboardItemDTO) -> NSString {
        "\(item.type.rawValue)|\(item.contentHash)" as NSString
    }

    private func metadataCacheKey(for item: ClipboardItemDTO) -> NSString {
        "\(item.type.rawValue)|\(item.contentHash)|\(item.sizeBytes)" as NSString
    }

    private func computeTitle(type: ClipboardItemType, plainText: String) -> String {
        switch type {
        case .file:
            let paths = plainText.components(separatedBy: "\n").filter { !$0.isEmpty }
            let fileCount = paths.count
            let firstName = URL(fileURLWithPath: paths.first ?? "").lastPathComponent
            if fileCount <= 1 {
                return firstName.isEmpty ? plainText : firstName
            }
            return "\(firstName) + \(fileCount - 1) more"
        case .image:
            return "Image"
        default:
            return plainText.isEmpty ? "(No text)" : String(plainText.prefix(100))
        }
    }

    private func computeMetadata(type: ClipboardItemType, plainText: String, sizeBytes: Int) -> String {
        switch type {
        case .text, .rtf, .html:
            return computeTextMetadata(plainText)
        case .image:
            return computeImageMetadata(plainText, sizeBytes: sizeBytes)
        case .file:
            return computeFileMetadata(plainText, sizeBytes: sizeBytes)
        default:
            return formatBytes(sizeBytes)
        }
    }

    private func computeTextMetadata(_ text: String) -> String {
        let charCount = text.count
        let lineCount = text.components(separatedBy: .newlines).count
        let cleanText = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let lastChars = cleanText.count <= 15 ? cleanText : "...\(String(cleanText.suffix(15)))"
        return "\(charCount)字 · \(lineCount)行 · \(lastChars)"
    }

    private func computeImageMetadata(_ plainText: String, sizeBytes: Int) -> String {
        let size = formatBytes(sizeBytes)
        if let resolution = parseImageResolution(from: plainText) {
            return "\(resolution) · \(size)"
        }
        return size
    }

    private func computeFileMetadata(_ plainText: String, sizeBytes: Int) -> String {
        let paths = plainText.components(separatedBy: "\n").filter { !$0.isEmpty }
        let fileCount = paths.count
        let size = formatBytes(sizeBytes)
        if fileCount == 1 {
            return size
        }
        return "\(fileCount)个文件 · \(size)"
    }

    private func parseImageResolution(from text: String) -> String? {
        let pattern = #"\[Image:\s*(\d+)x(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let widthRange = Range(match.range(at: 1), in: text),
              let heightRange = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return "\(text[widthRange])×\(text[heightRange])"
    }

    private func formatBytes(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        return String(format: "%.1f MB", kb / 1024)
    }
}

extension ClipboardItemDTO {
    @MainActor var title: String { ClipboardItemDisplayText.shared.title(for: self) }
    @MainActor var metadata: String { ClipboardItemDisplayText.shared.metadata(for: self) }
}
