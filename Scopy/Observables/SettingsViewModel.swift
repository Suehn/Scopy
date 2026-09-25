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
        let contentSize = Localization.formatBytes(storageStats.sizeBytes)
        let diskSize = Localization.formatBytes(diskSizeBytes)
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

        // After images under content/ are overwritten or compressed outside the app, the stored
        // size_bytes can exceed the real disk usage. The slack keeps rounding and tiny differences
        // from triggering a rescan every time.
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

}
