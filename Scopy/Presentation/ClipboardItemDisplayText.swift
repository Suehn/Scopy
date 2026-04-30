import Foundation
import ScopyKit
import ScopyUISupport

/// Presentation-only helpers for deriving display strings from `ClipboardItemDTO`.
///
/// Domain model should not carry UI-specific derived fields (e.g. title/metadata).
/// This cache keeps UI rendering cheap without bloating the DTO.
@MainActor
final class ClipboardItemDisplayText {
    static let shared = ClipboardItemDisplayText()

    private struct TitleCacheKey: Hashable {
        let type: ClipboardItemType
        let contentKey: String
    }

    private struct MetadataCacheKey: Hashable {
        let type: ClipboardItemType
        let contentKey: String
        let note: String?
        let sizeBytes: Int
        let fileSizeBytes: Int?
    }

    private struct PrewarmSnapshot: Sendable {
        let type: ClipboardItemType
        let contentKey: String
        let plainText: String
        let note: String?
        let sizeBytes: Int
        let fileSizeBytes: Int?
    }

    private struct PrewarmEntry: Sendable {
        let titleKey: TitleCacheKey
        let metadataKey: MetadataCacheKey
        let title: String
        let metadata: String
    }

    private struct DisplayTextPair: Sendable {
        let title: String
        let metadata: String
    }

    private var titleCache: [TitleCacheKey: String] = [:]
    private var metadataCache: [MetadataCacheKey: String] = [:]

    private let cacheLimit: Int = 20_000

    private init() {
    }

    func title(for item: ClipboardItemDTO) -> String {
        trimCacheIfNeeded()
        let titleKey = makeTitleCacheKey(for: item)
        if let cached = titleCache[titleKey] { return cached }

        let pair = computeDisplayTextPair(for: item, metricName: "text.title_ms")
        storeDisplayTextPair(pair, titleKey: titleKey, metadataKey: makeMetadataCacheKey(for: item))
        return pair.title
    }

    func metadata(for item: ClipboardItemDTO) -> String {
        trimCacheIfNeeded()
        let metadataKey = makeMetadataCacheKey(for: item)
        if let cached = metadataCache[metadataKey] { return cached }

        let pair = computeDisplayTextPair(for: item, metricName: "text.metadata_ms")
        storeDisplayTextPair(pair, titleKey: makeTitleCacheKey(for: item), metadataKey: metadataKey)
        return pair.metadata
    }

    func displayTexts(for item: ClipboardItemDTO) -> (title: String, metadata: String) {
        trimCacheIfNeeded()
        let titleKey = makeTitleCacheKey(for: item)
        let metadataKey = makeMetadataCacheKey(for: item)
        if let title = titleCache[titleKey],
           let metadata = metadataCache[metadataKey] {
            return (title, metadata)
        }

        let pair = computeDisplayTextPair(for: item, metricName: "text.metadata_ms")
        storeDisplayTextPair(pair, titleKey: titleKey, metadataKey: metadataKey)
        return (pair.title, pair.metadata)
    }

    @discardableResult
    func prewarm(items: [ClipboardItemDTO]) -> Task<Void, Never>? {
        guard !items.isEmpty else { return nil }
        let snapshots = items.map { item in
            PrewarmSnapshot(
                type: item.type,
                contentKey: Self.cacheKeyContent(for: item),
                plainText: item.plainText,
                note: item.note,
                sizeBytes: item.sizeBytes,
                fileSizeBytes: item.fileSizeBytes
            )
        }

        let task = Task.detached(priority: .utility) { [snapshots] in
            var entries: [PrewarmEntry] = []
            entries.reserveCapacity(snapshots.count)
            for snapshot in snapshots {
                let pair = Self.computeDisplayTextPair(
                    type: snapshot.type,
                    plainText: snapshot.plainText,
                    note: snapshot.note,
                    sizeBytes: snapshot.sizeBytes,
                    fileSizeBytes: snapshot.fileSizeBytes
                )
                let titleKey = TitleCacheKey(type: snapshot.type, contentKey: snapshot.contentKey)
                let metadataKey = MetadataCacheKey(
                    type: snapshot.type,
                    contentKey: snapshot.contentKey,
                    note: snapshot.note,
                    sizeBytes: snapshot.sizeBytes,
                    fileSizeBytes: snapshot.fileSizeBytes
                )
                entries.append(
                    PrewarmEntry(
                        titleKey: titleKey,
                        metadataKey: metadataKey,
                        title: pair.title,
                        metadata: pair.metadata
                    )
                )
            }
            let preparedEntries = entries
            await MainActor.run {
                ClipboardItemDisplayText.shared.storePrewarmEntries(preparedEntries)
            }
        }

        return task
    }

    func cachedTitle(for item: ClipboardItemDTO) -> String? {
        titleCache[makeTitleCacheKey(for: item)]
    }

    func cachedMetadata(for item: ClipboardItemDTO) -> String? {
        metadataCache[makeMetadataCacheKey(for: item)]
    }

    func clearCaches() {
        titleCache.removeAll(keepingCapacity: true)
        metadataCache.removeAll(keepingCapacity: true)
    }

    private func trimCacheIfNeeded() {
        if titleCache.count > cacheLimit {
            titleCache.removeAll(keepingCapacity: true)
        }
        if metadataCache.count > cacheLimit {
            metadataCache.removeAll(keepingCapacity: true)
        }
    }

    private func makeTitleCacheKey(for item: ClipboardItemDTO) -> TitleCacheKey {
        TitleCacheKey(type: item.type, contentKey: Self.cacheKeyContent(for: item))
    }

    private func makeMetadataCacheKey(for item: ClipboardItemDTO) -> MetadataCacheKey {
        MetadataCacheKey(
            type: item.type,
            contentKey: Self.cacheKeyContent(for: item),
            note: item.note,
            sizeBytes: item.sizeBytes,
            fileSizeBytes: item.fileSizeBytes
        )
    }

    private func storePrewarmEntries(_ entries: [PrewarmEntry]) {
        guard !entries.isEmpty else { return }
        trimCacheIfNeeded()
        var titleCount = titleCache.count
        var metadataCount = metadataCache.count

        for entry in entries {
            if titleCount >= cacheLimit || metadataCount >= cacheLimit {
                break
            }

            if titleCache[entry.titleKey] == nil {
                titleCache[entry.titleKey] = entry.title
                titleCount += 1
            }
            if metadataCache[entry.metadataKey] == nil {
                metadataCache[entry.metadataKey] = entry.metadata
                metadataCount += 1
            }
        }
    }

    private func storeDisplayTextPair(_ pair: DisplayTextPair, titleKey: TitleCacheKey, metadataKey: MetadataCacheKey) {
        if titleCache[titleKey] == nil, titleCache.count < cacheLimit {
            titleCache[titleKey] = pair.title
        }
        if metadataCache[metadataKey] == nil, metadataCache.count < cacheLimit {
            metadataCache[metadataKey] = pair.metadata
        }
    }

    private func computeDisplayTextPair(for item: ClipboardItemDTO, metricName: String) -> DisplayTextPair {
        if ScrollPerformanceProfile.isEnabled {
            let start = CFAbsoluteTimeGetCurrent()
            let pair = Self.computeDisplayTextPair(
                type: item.type,
                plainText: item.plainText,
                note: item.note,
                sizeBytes: item.sizeBytes,
                fileSizeBytes: item.fileSizeBytes
            )
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            ScrollPerformanceProfile.recordMetric(name: metricName, elapsedMs: elapsed)
            return pair
        }

        return Self.computeDisplayTextPair(
            type: item.type,
            plainText: item.plainText,
            note: item.note,
            sizeBytes: item.sizeBytes,
            fileSizeBytes: item.fileSizeBytes
        )
    }

    private nonisolated static func cacheKeyContent(for item: ClipboardItemDTO) -> String {
        item.contentHash.isEmpty ? item.id.uuidString : item.contentHash
    }

    private nonisolated static func computeTitle(type: ClipboardItemType, plainText: String) -> String {
        computeDisplayTextPair(type: type, plainText: plainText, note: nil, sizeBytes: 0, fileSizeBytes: nil).title
    }

    private nonisolated static func computeMetadata(
        type: ClipboardItemType,
        plainText: String,
        note: String?,
        sizeBytes: Int,
        fileSizeBytes: Int?
    ) -> String {
        computeDisplayTextPair(
            type: type,
            plainText: plainText,
            note: note,
            sizeBytes: sizeBytes,
            fileSizeBytes: fileSizeBytes
        ).metadata
    }

    private nonisolated static func computeDisplayTextPair(
        type: ClipboardItemType,
        plainText: String,
        note: String?,
        sizeBytes: Int,
        fileSizeBytes: Int?
    ) -> DisplayTextPair {
        switch type {
        case .text, .rtf, .html:
            return DisplayTextPair(
                title: plainText.isEmpty ? "(No text)" : String(plainText.prefix(100)),
                metadata: computeTextMetadata(plainText)
            )
        case .image:
            return DisplayTextPair(
                title: "Image",
                metadata: computeImageMetadata(plainText, sizeBytes: sizeBytes)
            )
        case .file:
            let summary = summarizeFilePlainText(plainText)
            return DisplayTextPair(
                title: computeFileTitle(plainText, summary: summary),
                metadata: computeFileMetadata(summary: summary, note: note, fileSizeBytes: fileSizeBytes)
            )
        default:
            let metadata = formatBytes(sizeBytes)
            return DisplayTextPair(title: plainText.isEmpty ? "(No text)" : String(plainText.prefix(100)), metadata: metadata)
        }
    }

    private nonisolated static func computeFileTitle(
        _ plainText: String,
        summary: (firstPath: String?, fileCount: Int)
    ) -> String {
        let fileCount = summary.fileCount
        let firstName = URL(fileURLWithPath: summary.firstPath ?? "").lastPathComponent
        if fileCount <= 1 {
            return firstName.isEmpty ? plainText : firstName
        }
        return "\(firstName) + \(fileCount - 1) more"
    }

    private nonisolated static func computeTextMetadata(_ text: String) -> String {
        let summary = TextMetrics.displayWordUnitCountAndLineCount(for: text)

        // Match previous behavior:
        // - lineCount: `components(separatedBy: .newlines).count`
        // - suffix: last 15 Characters of `text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")`
        // - prefix: add "..." only when the cleaned text character count > 15
        let maxTailChars = 15

        let (suffix, needsEllipsis) = cleanTailAndEllipsis(text, maxTailChars: maxTailChars)
        let lastChars = needsEllipsis ? "...\(suffix)" : suffix
        return "\(summary.wordUnitCount)字 · \(summary.lineCount)行 · \(lastChars)"
    }

    private nonisolated static func cleanTailAndEllipsis(_ text: String, maxTailChars: Int) -> (suffix: String, needsEllipsis: Bool) {
        // Determine if cleaned text length exceeds the threshold without scanning the whole string.
        // Note: "\r\n" is a single grapheme cluster, but legacy replacement produces two spaces (two Characters),
        // so we must treat it as 2 when checking the cleaned Character count.
        var needsEllipsis = false
        var cleanedCount = 0
        for ch in text {
            if ch == "\r\n" {
                cleanedCount += 2
            } else {
                cleanedCount += 1
            }
            if cleanedCount > maxTailChars {
                needsEllipsis = true
                break
            }
        }

        var tail: [Character] = []
        tail.reserveCapacity(maxTailChars)
        var remaining = maxTailChars
        for ch in text.reversed() {
            if remaining <= 0 { break }
            if ch == "\r\n" {
                // Legacy replacement: "\r" -> " ", "\n" -> " " (two spaces).
                if remaining > 0 {
                    tail.append(" ")
                    remaining -= 1
                }
                if remaining > 0 {
                    tail.append(" ")
                    remaining -= 1
                }
                continue
            }
            if ch == "\n" || ch == "\r" {
                tail.append(" ")
                remaining -= 1
                continue
            }
            tail.append(ch)
            remaining -= 1
        }

        return (String(tail.reversed()), needsEllipsis)
    }

    private nonisolated static func computeImageMetadata(_ plainText: String, sizeBytes: Int) -> String {
        let size = formatBytes(sizeBytes)
        if let resolution = parseImageResolution(from: plainText) {
            return "\(resolution) · \(size)"
        }
        return size
    }

    private nonisolated static func computeFileMetadata(
        summary: (firstPath: String?, fileCount: Int),
        note: String?,
        fileSizeBytes: Int?
    ) -> String {
        let fileCount = summary.fileCount
        var parts: [String] = []

        if fileCount > 1 {
            parts.append("\(fileCount)个文件")
        }

        if let fileSizeBytes {
            parts.append(formatBytes(fileSizeBytes))
        } else {
            parts.append("未知大小")
        }

        if let note, !note.isEmpty {
            parts.append(note)
        }

        return parts.joined(separator: " · ")
    }

    private nonisolated static func summarizeFilePlainText(_ plainText: String) -> (firstPath: String?, fileCount: Int) {
        guard !plainText.isEmpty else { return (nil, 0) }

        var firstPath: String?
        var fileCount = 0

        var lineStart = plainText.startIndex
        var index = lineStart

        while index < plainText.endIndex {
            let ch = plainText[index]
            if ch == "\n" {
                if lineStart != index {
                    fileCount += 1
                    if firstPath == nil {
                        firstPath = String(plainText[lineStart..<index])
                    }
                }
                lineStart = plainText.index(after: index)
            }
            index = plainText.index(after: index)
        }

        if lineStart != plainText.endIndex {
            fileCount += 1
            if firstPath == nil {
                firstPath = String(plainText[lineStart..<plainText.endIndex])
            }
        }

        return (firstPath, fileCount)
    }

    private nonisolated static func parseImageResolution(from text: String) -> String? {
        let pattern = #"\[Image:\s*(\d+)x(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let widthRange = Range(match.range(at: 1), in: text),
              let heightRange = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return "\(text[widthRange])×\(text[heightRange])"
    }

    private nonisolated static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        }
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
