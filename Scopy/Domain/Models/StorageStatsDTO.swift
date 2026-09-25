import Foundation

/// Detailed storage statistics.
public struct StorageStatsDTO: Sendable {
    public let itemCount: Int
    public let databaseSizeBytes: Int
    public let externalStorageSizeBytes: Int
    public let thumbnailSizeBytes: Int  // Thumbnail cache size.
    public let totalSizeBytes: Int
    public let databasePath: String

    public init(
        itemCount: Int,
        databaseSizeBytes: Int,
        externalStorageSizeBytes: Int,
        thumbnailSizeBytes: Int,
        totalSizeBytes: Int,
        databasePath: String
    ) {
        self.itemCount = itemCount
        self.databaseSizeBytes = databaseSizeBytes
        self.externalStorageSizeBytes = externalStorageSizeBytes
        self.thumbnailSizeBytes = thumbnailSizeBytes
        self.totalSizeBytes = totalSizeBytes
        self.databasePath = databasePath
    }

    public var databaseSizeText: String {
        formatBytes(databaseSizeBytes)
    }

    public var externalStorageSizeText: String {
        formatBytes(externalStorageSizeBytes)
    }

    public var thumbnailSizeText: String {
        formatBytes(thumbnailSizeBytes)
    }

    public var totalSizeText: String {
        formatBytes(totalSizeBytes)
    }

    private func formatBytes(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        } else {
            return String(format: "%.1f MB", kb / 1024)
        }
    }
}
