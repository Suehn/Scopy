import Foundation

/// 存储统计详情 DTO
struct StorageStatsDTO: Sendable {
    let itemCount: Int
    let databaseSizeBytes: Int
    let externalStorageSizeBytes: Int
    let thumbnailSizeBytes: Int  // v0.15.2: 缩略图缓存大小
    let totalSizeBytes: Int
    let databasePath: String

    var databaseSizeText: String {
        formatBytes(databaseSizeBytes)
    }

    var externalStorageSizeText: String {
        formatBytes(externalStorageSizeBytes)
    }

    var thumbnailSizeText: String {
        formatBytes(thumbnailSizeBytes)
    }

    var totalSizeText: String {
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

