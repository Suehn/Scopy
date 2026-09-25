import Foundation
import CoreGraphics

// NSCache is thread-safe and this cache stores only value types (String, structs, boxed in an NSObject where
// needed), so one global shared cache is safe; @unchecked Sendable states that intent for concurrency checking.
final class MarkdownPreviewCache: @unchecked Sendable {
    static let shared = MarkdownPreviewCache()

    private final class MetricsBox: NSObject {
        let metrics: MarkdownContentMetrics

        init(_ metrics: MarkdownContentMetrics) {
            self.metrics = metrics
        }
    }

    struct FilePreviewEntry {
        let text: String
        let html: String?
        let metrics: MarkdownContentMetrics?
        let fetchedAt: Date
    }

    private final class FilePreviewBox: NSObject {
        let entry: FilePreviewEntry

        init(_ entry: FilePreviewEntry) {
            self.entry = entry
        }
    }

    private let htmlCache = NSCache<NSString, NSString>()
    private let metricsCache = NSCache<NSString, MetricsBox>()
    private let filePreviewCache = NSCache<NSString, FilePreviewBox>()

    private init() {
        htmlCache.countLimit = 200
        htmlCache.totalCostLimit = 8 * 1024 * 1024

        // Metrics are tiny; keep a slightly larger count cap to improve re-hover stability.
        metricsCache.countLimit = 400

        // File preview entries can hold the source text + rendered HTML, so keep a lower cap.
        filePreviewCache.countLimit = 64
        filePreviewCache.totalCostLimit = 16 * 1024 * 1024
    }

    func html(forKey key: String) -> String? {
        htmlCache.object(forKey: key as NSString) as String?
    }

    func setHTML(_ html: String, forKey key: String) {
        let cost = html.utf16.count * 2
        htmlCache.setObject(html as NSString, forKey: key as NSString, cost: cost)
    }

    func metrics(forKey key: String) -> MarkdownContentMetrics? {
        metricsCache.object(forKey: key as NSString)?.metrics
    }

    func setMetrics(_ metrics: MarkdownContentMetrics, forKey key: String) {
        metricsCache.setObject(MetricsBox(metrics), forKey: key as NSString)
    }

    func filePreview(forKey key: String) -> FilePreviewEntry? {
        filePreviewCache.object(forKey: key as NSString)?.entry
    }

    func setFilePreview(_ entry: FilePreviewEntry, forKey key: String) {
        let textCost = entry.text.utf16.count * 2
        let htmlCost = entry.html?.utf16.count ?? 0
        let cost = textCost + htmlCost * 2
        filePreviewCache.setObject(FilePreviewBox(entry), forKey: key as NSString, cost: cost)
    }

    /// Drops rendered documents and file previews; metrics are tiny and keep re-hover stable.
    func removeDocuments() {
        htmlCache.removeAllObjects()
        filePreviewCache.removeAllObjects()
    }

    func updateFilePreviewFetchedAt(_ date: Date, forKey key: String) {
        guard let existing = filePreview(forKey: key) else { return }
        let updated = FilePreviewEntry(text: existing.text, html: existing.html, metrics: existing.metrics, fetchedAt: date)
        setFilePreview(updated, forKey: key)
    }
}
