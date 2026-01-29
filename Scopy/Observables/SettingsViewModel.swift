import Foundation
import Observation
import ScopyKit
import ScopyUISupport

@Observable
@MainActor
final class SettingsViewModel {
    // MARK: - Properties

    @ObservationIgnored private var service: ClipboardServiceProtocol

    var settings: SettingsDTO = .default

    var storageStats: (itemCount: Int, sizeBytes: Int) = (0, 0)

    @ObservationIgnored private var diskSizeCache: (size: Int, timestamp: Date)?
    @ObservationIgnored private let diskSizeCacheTTL: TimeInterval = 120
    var diskSizeBytes: Int = 0

    @ObservationIgnored private var externalImageSizeSyncTask: Task<Void, Never>?
    @ObservationIgnored private var lastExternalImageSizeSyncAttemptAt: Date?
    @ObservationIgnored private let externalImageSizeSyncAttemptTTL: TimeInterval = 3600
    @ObservationIgnored private let externalImageSizeMismatchSlackBytes: Int = 5 * 1024 * 1024

    var storageSizeText: String {
        let contentSize = formatBytes(storageStats.sizeBytes)
        let diskSize = formatBytes(diskSizeBytes)
        return "\(contentSize) / \(diskSize)"
    }

    // MARK: - Init

    init(service: ClipboardServiceProtocol) {
        self.service = service
    }

    func updateService(_ service: ClipboardServiceProtocol) {
        self.service = service
        externalImageSizeSyncTask?.cancel()
        externalImageSizeSyncTask = nil
        lastExternalImageSizeSyncAttemptAt = nil
    }

    // MARK: - Settings

    func updateDefaultSearchMode(_ mode: SearchMode) async {
        do {
            var latest = try await service.getSettings()
            latest.defaultSearchMode = mode
            try await service.updateSettings(latest)
            settings = latest
        } catch {
            ScopyLog.app.error("Failed to update default search mode: \(error.localizedDescription, privacy: .private)")
        }
    }

    func getLatestSettingsOrThrow() async throws -> SettingsDTO {
        try await service.getSettings()
    }

    func loadSettings() async {
        do {
            settings = try await service.getSettings()
        } catch {
            ScopyLog.app.error("Failed to load settings: \(error.localizedDescription, privacy: .private)")
            settings = .default
        }
    }

    func updateSettings(_ newSettings: SettingsDTO) async {
        do {
            try await updateSettingsOrThrow(newSettings)
        } catch {
            ScopyLog.app.error("Failed to update settings: \(error.localizedDescription, privacy: .private)")
        }
    }

    func updateSettingsOrThrow(_ newSettings: SettingsDTO) async throws {
        let oldSettings = settings
        try await service.updateSettings(newSettings)
        settings = newSettings

        if oldSettings.thumbnailHeight != newSettings.thumbnailHeight
            || oldSettings.showImageThumbnails != newSettings.showImageThumbnails
        {
            ThumbnailCache.shared.clear()
        }
    }

    // MARK: - Stats

    func refreshStorageStats() async throws {
        let stats = try await service.getStorageStats()
        storageStats = stats
        await refreshDiskSizeIfNeeded()
        syncExternalImageSizeBytesFromDiskIfNeeded()
    }

    func refreshDiskSizeIfNeeded() async {
        if let cache = diskSizeCache,
           Date().timeIntervalSince(cache.timestamp) < diskSizeCacheTTL {
            diskSizeBytes = cache.size
            return
        }

        do {
            let detailed = try await service.getDetailedStorageStats()
            diskSizeBytes = detailed.totalSizeBytes
            diskSizeCache = (diskSizeBytes, Date())
        } catch {
            ScopyLog.app.error("Failed to get disk size: \(error.localizedDescription, privacy: .private)")
        }
    }

    func syncExternalImageSizeBytesFromDiskIfNeeded() {
        guard externalImageSizeSyncTask == nil else { return }

        let estimated = storageStats.sizeBytes
        let disk = diskSizeBytes
        guard estimated > 0, disk > 0 else { return }

        // v0.50.fix19: 当用户在应用外部覆盖/压缩了 content/ 下的图片后，
        // DB 的 size_bytes 可能仍为旧值，导致估算值反而 > 真实磁盘占用。
        // 这里加一个轻量阈值，避免在极小差异/四舍五入情况下反复触发扫描。
        guard estimated > disk + externalImageSizeMismatchSlackBytes else { return }

        let now = Date()
        if let last = lastExternalImageSizeSyncAttemptAt,
           now.timeIntervalSince(last) < externalImageSizeSyncAttemptTTL {
            return
        }
        lastExternalImageSizeSyncAttemptAt = now

        externalImageSizeSyncTask = Task {
            defer { externalImageSizeSyncTask = nil }

            do {
                let updated = try await service.syncExternalImageSizeBytesFromDisk()
                guard !Task.isCancelled else { return }
                guard updated > 0 else { return }
                storageStats = try await service.getStorageStats()
            } catch {
                if !Task.isCancelled {
                    ScopyLog.app.error("Failed to sync external image size_bytes: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }

    func getDetailedStorageStats() async throws -> StorageStatsDTO {
        try await service.getDetailedStorageStats()
    }

    // MARK: - Private

    private func formatBytes(_ bytes: Int) -> String {
        let kb = Double(max(0, bytes)) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        return String(format: "%.1f MB", kb / 1024)
    }
}
