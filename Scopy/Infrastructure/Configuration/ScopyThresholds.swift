import Foundation

enum ScopyThresholds {
    /// ClipboardMonitor: content >= threshold is written as a durable envelope and processed off
    /// the main actor; images take that path at any size.
    static let ingestDurableEnvelopeBytes = 50 * 1024

    /// ClipboardMonitor: content >= threshold will be spooled to disk before emitting into streams.
    ///
    /// Rationale: avoid large `Data` payloads accumulating in memory when consumers are slower.
    static let ingestSpoolBytes = externalStorageBytes

    /// ClipboardMonitor: capacity of the serial ingest FIFO; polling waits once it is full.
    /// Also the backlog size at which pending envelopes are reported as a soft-limit hit.
    static let ingestMaxPendingItems = 32

    /// StorageService: content >= threshold will be stored in external file (not inline DB blob).
    static let externalStorageBytes = 100 * 1024

    /// ClipboardBackend: maximum buffered UI events before applying backpressure.
    static let clipboardEventStreamMaxBufferedItems = 2048

    /// ClipboardMonitor: maximum buffered clipboard contents before applying backpressure.
    static let monitorContentStreamMaxBufferedItems = 256
}
