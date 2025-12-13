import Foundation

/// RealClipboardService - 兼容层 adapter
///
/// 说明：
/// - UI 仍通过 `@MainActor ClipboardServiceProtocol` 访问后端，因此保留该类型对外形态。
/// - 真实逻辑迁移到 `Scopy/Application/ClipboardService.swift`（actor），此类仅做转发。
@MainActor
final class RealClipboardService: ClipboardServiceProtocol {
    private let clipboardService: ClipboardService

    var eventStream: AsyncStream<ClipboardEvent> {
        clipboardService.eventStream
    }

    init(databasePath: String? = nil, settingsStore: SettingsStore = .shared) {
        self.clipboardService = ClipboardService(databasePath: databasePath, settingsStore: settingsStore)
    }

    // MARK: - Lifecycle

    func start() async throws {
        try await clipboardService.start()
    }

    func stop() {
        Task { [clipboardService] in
            await clipboardService.stop()
        }
    }

    // MARK: - Data Access

    func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
        try await clipboardService.fetchRecent(limit: limit, offset: offset)
    }

    func search(query: SearchRequest) async throws -> SearchResultPage {
        try await clipboardService.search(query: query)
    }

    func pin(itemID: UUID) async throws {
        try await clipboardService.pin(itemID: itemID)
    }

    func unpin(itemID: UUID) async throws {
        try await clipboardService.unpin(itemID: itemID)
    }

    func delete(itemID: UUID) async throws {
        try await clipboardService.delete(itemID: itemID)
    }

    func clearAll() async throws {
        try await clipboardService.clearAll()
    }

    func copyToClipboard(itemID: UUID) async throws {
        try await clipboardService.copyToClipboard(itemID: itemID)
    }

    func updateSettings(_ settings: SettingsDTO) async throws {
        try await clipboardService.updateSettings(settings)
    }

    func getSettings() async throws -> SettingsDTO {
        await clipboardService.getSettings()
    }

    func getStorageStats() async throws -> (itemCount: Int, sizeBytes: Int) {
        try await clipboardService.getStorageStats()
    }

    func getDetailedStorageStats() async throws -> StorageStatsDTO {
        try await clipboardService.getDetailedStorageStats()
    }

    func getImageData(itemID: UUID) async throws -> Data? {
        try await clipboardService.getImageData(itemID: itemID)
    }

    func getRecentApps(limit: Int) async throws -> [String] {
        try await clipboardService.getRecentApps(limit: limit)
    }
}

// MARK: - Service Factory

enum ClipboardServiceFactory {
    @MainActor
    static func create(useMock: Bool = false, databasePath: String? = nil) -> ClipboardServiceProtocol {
        if useMock {
            return MockClipboardService()
        }
        return RealClipboardService(databasePath: databasePath)
    }

    /// Create service for testing with shared in-memory database.
    ///
    /// Notes:
    /// - Search 使用独立 read connection，因此不能使用 `:memory:`（每个连接会得到不同数据库）。
    /// - 使用 shared-cache in-memory URI 让多连接访问同一 DB。
    @MainActor
    static func createForTesting() -> RealClipboardService {
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let sharedMemoryURI = "file:scopy_test_\(unique)?mode=memory&cache=shared"
        return RealClipboardService(databasePath: sharedMemoryURI)
    }
}

