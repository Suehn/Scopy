import Foundation
import Observation

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
    }

    // MARK: - Settings

    func loadSettings() async {
        do {
            settings = try await service.getSettings()
        } catch {
            ScopyLog.app.error("Failed to load settings: \(error.localizedDescription, privacy: .public)")
            settings = .default
        }
    }

    func updateSettings(_ newSettings: SettingsDTO) async {
        do {
            try await service.updateSettings(newSettings)
            settings = newSettings
        } catch {
            ScopyLog.app.error("Failed to update settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Stats

    func refreshStorageStats() async throws {
        let stats = try await service.getStorageStats()
        storageStats = stats
        await refreshDiskSizeIfNeeded()
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
            ScopyLog.app.error("Failed to get disk size: \(error.localizedDescription, privacy: .public)")
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

