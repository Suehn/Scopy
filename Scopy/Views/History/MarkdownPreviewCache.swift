import Foundation
import CoreGraphics

// NSCache is thread-safe and this cache stores only value types (structs boxed in an NSObject where
// needed), so one global shared cache is safe; @unchecked Sendable states that intent for concurrency checking.
final class MarkdownPreviewCache: @unchecked Sendable {
    static let shared = MarkdownPreviewCache()

    private final class DocumentBox: NSObject {
        let document: PreparedMarkdownDocument

        init(_ document: PreparedMarkdownDocument) {
            self.document = document
        }
    }

    private final class MetricsBox: NSObject {
        let metrics: MarkdownContentMetrics

        init(_ metrics: MarkdownContentMetrics) {
            self.metrics = metrics
        }
    }

    struct FilePreviewEntry {
        let text: String
        let document: PreparedMarkdownDocument?
        let fetchedAt: Date
    }

    private final class FilePreviewBox: NSObject {
        let entry: FilePreviewEntry

        init(_ entry: FilePreviewEntry) {
            self.entry = entry
        }
    }

    private let documentCache = NSCache<NSString, DocumentBox>()
    private let metricsCache = NSCache<NSString, MetricsBox>()
    private let filePreviewCache = NSCache<NSString, FilePreviewBox>()

    private init() {
        documentCache.countLimit = 200
        documentCache.totalCostLimit = 8 * 1024 * 1024

        // Metrics are tiny; keep a slightly larger count cap to improve re-hover stability.
        metricsCache.countLimit = 400

        // File preview entries can hold the source text + rendered HTML, so keep a lower cap.
        filePreviewCache.countLimit = 64
        filePreviewCache.totalCostLimit = 16 * 1024 * 1024
    }

    func document(forKey key: String) -> PreparedMarkdownDocument? {
        documentCache.object(forKey: key as NSString)?.document
    }

    func setDocument(_ document: PreparedMarkdownDocument) {
        // The HTML embeds all sidecar strings; a second HTML-sized allowance bounds the
        // retained context without re-encoding its potentially large inline images.
        let cost = (document.source.utf16.count + document.html.utf16.count * 2) * 2
        documentCache.setObject(DocumentBox(document), forKey: document.renderKey as NSString, cost: cost)
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
        let htmlCost = (entry.document?.html.utf16.count ?? 0) * 2
        let cost = textCost + htmlCost * 2
        filePreviewCache.setObject(FilePreviewBox(entry), forKey: key as NSString, cost: cost)
    }

    /// Drops rendered documents and file previews; metrics are tiny and keep re-hover stable.
    func removeDocuments() {
        documentCache.removeAllObjects()
        filePreviewCache.removeAllObjects()
    }

    func updateFilePreviewFetchedAt(_ date: Date, forKey key: String) {
        guard let existing = filePreview(forKey: key) else { return }
        let updated = FilePreviewEntry(text: existing.text, document: existing.document, fetchedAt: date)
        setFilePreview(updated, forKey: key)
    }
}
