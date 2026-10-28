import Foundation

/// Bridges the main-actor UI protocol to the ClipboardBackend actor.

@MainActor
final class RealClipboardService: ClipboardServiceProtocol {
    private let backend: ClipboardBackend

    var eventStream: AsyncStream<ClipboardEvent> {
        backend.eventStream
    }

    init(
        databasePath: String? = nil,
        settingsStore: SettingsStore = .shared,
        monitorPasteboardName: String? = nil,
        monitorPollingInterval: TimeInterval? = nil
    ) {
        self.backend = ClipboardBackend(
            databasePath: databasePath,
            settingsStore: settingsStore,
            monitorPasteboardName: monitorPasteboardName,
            monitorPollingInterval: monitorPollingInterval
        )
    }

    // MARK: - Lifecycle

    func start() async throws {
        try await backend.start()
    }

    func stopAndWait() async {
        await backend.stop()
    }

    // MARK: - Data Access

    func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
        try await backend.fetchRecent(limit: limit, offset: offset)
    }

    func fetchPinned() async throws -> [ClipboardItemDTO] {
        try await backend.fetchPinned()
    }

    func fetchHistoryPage(limit: Int, after cursor: RecentHistoryCursor?) async throws -> RecentHistoryPage {
        try await backend.fetchHistoryPage(limit: limit, after: cursor)
    }

    func fetchHistoryItems(itemIDs: Set<UUID>) async throws -> HistoryItemsSnapshot {
        try await backend.fetchHistoryItems(itemIDs: itemIDs)
    }

    func search(query: SearchRequest) async throws -> SearchResultPage {
        try await backend.search(query: query)
    }

    func pin(itemID: UUID) async throws {
        try await backend.pin(itemID: itemID)
    }

    func unpin(itemID: UUID) async throws {
        try await backend.unpin(itemID: itemID)
    }

    func updateNote(itemID: UUID, note: String?) async throws {
        try await backend.updateNote(itemID: itemID, note: note)
    }

    func delete(itemID: UUID, expectedUseCount: Int) async throws -> HistoryItemsSnapshot {
        try await backend.delete(itemID: itemID, expectedUseCount: expectedUseCount)
    }

    func clearAll() async throws {
        try await backend.clearAll()
    }

    func copyToClipboard(itemID: UUID) async throws {
        try await backend.copyToClipboard(itemID: itemID)
    }

    func copyToClipboardOptimizedForCodex(itemID: UUID) async throws {
        try await backend.copyToClipboardOptimizedForCodex(itemID: itemID)
    }

    func fileURLs(itemID: UUID) async throws -> [URL] {
        try await backend.fileURLs(itemID: itemID)
    }

    func updateSettings(_ patch: SettingsPatch) async throws -> SettingsDTO {
        try await backend.updateSettings(patch)
    }

    func getSettings() async throws -> SettingsDTO {
        await backend.getSettings()
    }

    func getStorageStats() async throws -> (itemCount: Int, sizeBytes: Int) {
        try await backend.getStorageStats()
    }

    func getDetailedStorageStats() async throws -> StorageStatsDTO {
        try await backend.getDetailedStorageStats()
    }

    func getImageData(itemID: UUID) async throws -> Data? {
        try await backend.getImageData(itemID: itemID)
    }

    func optimizeImage(itemID: UUID) async throws -> ImageOptimizationOutcomeDTO {
        try await backend.optimizeImage(itemID: itemID)
    }

    func syncExternalImageSizeBytesFromDisk() async throws -> Int {
        try await backend.syncExternalImageSizeBytesFromDisk()
    }

    func getRecentApps(limit: Int) async throws -> [String] {
        try await backend.getRecentApps(limit: limit)
    }
}

// MARK: - Service Factory

public enum ClipboardServiceFactory {
    @MainActor
    public static func create(
        databasePath: String? = nil,
        settingsStore: SettingsStore = .shared,
        monitorPasteboardName: String? = nil,
        monitorPollingInterval: TimeInterval? = nil
    ) -> ClipboardServiceProtocol {
        RealClipboardService(
            databasePath: databasePath,
            settingsStore: settingsStore,
            monitorPasteboardName: monitorPasteboardName,
            monitorPollingInterval: monitorPollingInterval
        )
    }

}
