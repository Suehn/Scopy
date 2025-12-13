import Foundation

enum ScopyThresholds {
    /// ClipboardMonitor: content >= threshold will compute hash off-main (except small text).
    static let ingestHashOffloadBytes = 50 * 1024

    /// StorageService: content >= threshold will be stored in external file (not inline DB blob).
    static let externalStorageBytes = 100 * 1024
}

