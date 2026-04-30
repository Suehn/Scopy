import Foundation
import ScopyKit
import ScopyUISupport

/// Presentation-only cache for row-level derived values that are safe to precompute off the main thread.
@MainActor
final class HistoryItemPresentationCache {
    static let shared = HistoryItemPresentationCache()

    struct FilePreviewSummary: Sendable {
        let info: FilePreviewInfo
        let path: String
        let kind: FilePreviewKind
        let isMarkdown: Bool
        let shouldGenerateThumbnail: Bool
    }

    private struct CacheKey: Hashable, Sendable {
        let type: ClipboardItemType
        let contentKey: String
        let textLength: Int
    }

    private struct FilePreviewCacheValue: Sendable {
        let summary: FilePreviewSummary?
    }

    private struct PrewarmSnapshot: Sendable {
        let key: CacheKey
        let plainText: String
    }

    private struct PrewarmEntry: Sendable {
        let filePreviewKey: CacheKey?
        let filePreviewValue: FilePreviewCacheValue?
        let markdownKey: CacheKey?
        let markdownValue: Bool?
    }

    private let cacheLimit = 4_096

    private var filePreviewCache: [CacheKey: FilePreviewCacheValue] = [:]
    private var markdownCapabilityCache: [CacheKey: Bool] = [:]

    private init() {
    }

    func filePreview(for item: ClipboardItemDTO) -> FilePreviewSummary? {
        guard item.type == .file else { return nil }
        trimCachesIfNeeded()

        let key = Self.cacheKey(for: item)
        if let cached = filePreviewCache[key] {
            return cached.summary
        }

        let profileStart = ScrollPerformanceProfile.isEnabled ? CFAbsoluteTimeGetCurrent() : nil
        let summary = Self.computeFilePreview(plainText: item.plainText)
        if let profileStart {
            ScrollPerformanceProfile.recordMetric(
                name: "row.file_preview_ms",
                elapsedMs: (CFAbsoluteTimeGetCurrent() - profileStart) * 1000
            )
        }
        filePreviewCache[key] = FilePreviewCacheValue(summary: summary)
        return summary
    }

    func canExportPNG(for item: ClipboardItemDTO, filePreview: FilePreviewSummary?) -> Bool {
        switch item.type {
        case .text, .rtf, .html:
            return markdownExportCapability(for: item)
        case .file:
            return (filePreview ?? self.filePreview(for: item))?.isMarkdown == true
        default:
            return false
        }
    }

    @discardableResult
    func prewarm(items: [ClipboardItemDTO]) -> Task<Void, Never>? {
        let snapshots = items.compactMap { item -> PrewarmSnapshot? in
            switch item.type {
            case .file, .text, .rtf, .html:
                return PrewarmSnapshot(key: Self.cacheKey(for: item), plainText: item.plainText)
            default:
                return nil
            }
        }
        guard !snapshots.isEmpty else { return nil }

        let task = Task.detached(priority: .utility) { [snapshots] in
            var entries: [PrewarmEntry] = []
            entries.reserveCapacity(snapshots.count)

            for snapshot in snapshots {
                switch snapshot.key.type {
                case .file:
                    entries.append(
                        PrewarmEntry(
                            filePreviewKey: snapshot.key,
                            filePreviewValue: FilePreviewCacheValue(
                                summary: Self.computeFilePreview(plainText: snapshot.plainText)
                            ),
                            markdownKey: nil,
                            markdownValue: nil
                        )
                    )
                case .text, .rtf, .html:
                    entries.append(
                        PrewarmEntry(
                            filePreviewKey: nil,
                            filePreviewValue: nil,
                            markdownKey: snapshot.key,
                            markdownValue: MarkdownDetector.isLikelyMarkdown(snapshot.plainText)
                        )
                    )
                default:
                    break
                }
            }

            await MainActor.run {
                HistoryItemPresentationCache.shared.storePrewarmEntries(entries)
            }
        }

        return task
    }

    func cachedFilePreview(for item: ClipboardItemDTO) -> FilePreviewSummary? {
        guard item.type == .file else { return nil }
        return filePreviewCache[Self.cacheKey(for: item)]?.summary
    }

    func cachedMarkdownExportCapability(for item: ClipboardItemDTO) -> Bool? {
        guard Self.isMarkdownCandidate(type: item.type) else { return nil }
        return markdownCapabilityCache[Self.cacheKey(for: item)]
    }

    func clearCaches() {
        filePreviewCache.removeAll(keepingCapacity: true)
        markdownCapabilityCache.removeAll(keepingCapacity: true)
    }

    private func markdownExportCapability(for item: ClipboardItemDTO) -> Bool {
        guard Self.isMarkdownCandidate(type: item.type) else { return false }
        trimCachesIfNeeded()

        let key = Self.cacheKey(for: item)
        if let cached = markdownCapabilityCache[key] {
            return cached
        }

        let computed: Bool
        if ScrollPerformanceProfile.isEnabled {
            let start = CFAbsoluteTimeGetCurrent()
            computed = MarkdownDetector.isLikelyMarkdown(item.plainText)
            ScrollPerformanceProfile.recordMetric(
                name: "text.markdown_detect_ms",
                elapsedMs: (CFAbsoluteTimeGetCurrent() - start) * 1000
            )
        } else {
            computed = MarkdownDetector.isLikelyMarkdown(item.plainText)
        }
        markdownCapabilityCache[key] = computed
        return computed
    }

    private func storePrewarmEntries(_ entries: [PrewarmEntry]) {
        guard !entries.isEmpty else { return }
        trimCachesIfNeeded()

        for entry in entries {
            if let key = entry.filePreviewKey, let value = entry.filePreviewValue, filePreviewCache.count < cacheLimit {
                filePreviewCache[key] = value
            }
            if let key = entry.markdownKey, let value = entry.markdownValue, markdownCapabilityCache.count < cacheLimit {
                markdownCapabilityCache[key] = value
            }
        }
    }

    private func trimCachesIfNeeded() {
        if filePreviewCache.count > cacheLimit {
            filePreviewCache.removeAll(keepingCapacity: true)
        }
        if markdownCapabilityCache.count > cacheLimit {
            markdownCapabilityCache.removeAll(keepingCapacity: true)
        }
    }

    private nonisolated static func cacheKey(for item: ClipboardItemDTO) -> CacheKey {
        let contentKey = item.contentHash.isEmpty
            ? "\(item.id.uuidString)-\(item.plainText.hashValue)"
            : item.contentHash
        return CacheKey(type: item.type, contentKey: contentKey, textLength: item.plainText.utf16.count)
    }

    private nonisolated static func isMarkdownCandidate(type: ClipboardItemType) -> Bool {
        switch type {
        case .text, .rtf, .html:
            return true
        default:
            return false
        }
    }

    private nonisolated static func computeFilePreview(plainText: String) -> FilePreviewSummary? {
        guard let info = FilePreviewSupport.previewInfo(from: plainText, requireExists: false) else {
            return nil
        }
        return FilePreviewSummary(
            info: info,
            path: info.url.path,
            kind: info.kind,
            isMarkdown: FilePreviewSupport.isMarkdownFile(info.url),
            shouldGenerateThumbnail: FilePreviewSupport.shouldGenerateThumbnail(for: info.url)
        )
    }
}
