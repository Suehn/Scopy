import Foundation

enum ScopyThresholds {
    /// ClipboardMonitor: content >= threshold will compute hash off-main (except small text).
    static let ingestHashOffloadBytes = 50 * 1024

    /// ClipboardMonitor: content >= threshold will be spooled to disk before emitting into streams.
    ///
    /// Rationale: avoid large `Data` payloads accumulating in memory when consumers are slower.
    static let ingestSpoolBytes = externalStorageBytes

    /// ClipboardMonitor: maximum concurrent background ingest tasks.
    static let ingestMaxConcurrentTasks = 3

    /// ClipboardMonitor: maximum pending large ingests before dropping the oldest.
    static let ingestMaxPendingItems = 32

    /// StorageService: content >= threshold will be stored in external file (not inline DB blob).
    static let externalStorageBytes = 100 * 1024

    /// ClipboardService: maximum buffered UI events before applying backpressure.
    static let clipboardEventStreamMaxBufferedItems = 2048

    /// ClipboardMonitor: maximum buffered clipboard contents before applying backpressure.
    static let monitorContentStreamMaxBufferedItems = 256
}
