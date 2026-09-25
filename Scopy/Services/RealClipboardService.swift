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

    func stop() {
        Task { [backend] in
            await backend.stop()
        }
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

    func fetchRecentUnpinned(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
        try await backend.fetchRecentUnpinned(limit: limit, offset: offset)
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

    func delete(itemID: UUID) async throws {
        try await backend.delete(itemID: itemID)
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

    func updateSettings(_ settings: SettingsDTO) async throws {
        try await backend.updateSettings(settings)
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

    /// Create service for testing with shared in-memory database.
    ///
    /// Notes:
    /// - Search 使用独立 read connection，因此不能使用 `:memory:`（每个连接会得到不同数据库）。
    /// - 使用 shared-cache in-memory URI 让多连接访问同一 DB。
    @MainActor
    public static func createForTesting(
        settingsStore: SettingsStore = .shared,
        monitorPasteboardName: String? = nil,
        monitorPollingInterval: TimeInterval? = nil
    ) -> ClipboardServiceProtocol {
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let sharedMemoryURI = "file:scopy_test_\(unique)?mode=memory&cache=shared"
        return RealClipboardService(
            databasePath: sharedMemoryURI,
            settingsStore: settingsStore,
            monitorPasteboardName: monitorPasteboardName,
            monitorPollingInterval: monitorPollingInterval
        )
    }
}
