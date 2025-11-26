import AppKit
import Foundation
import SQLite3

/// RealClipboardService - 真实剪贴板服务实现
/// 整合 ClipboardMonitor + StorageService + SearchService
/// 符合 v0.md 的完整后端架构
@MainActor
final class RealClipboardService: ClipboardServiceProtocol {
    // MARK: - Properties

    private let monitor: ClipboardMonitor
    private let storage: StorageService
    private let search: SearchService
    private var settings: SettingsDTO = .default

    private var eventContinuation: AsyncStream<ClipboardEvent>.Continuation?
    private var monitorTask: Task<Void, Never>?

    private(set) var eventStream: AsyncStream<ClipboardEvent>

    // For direct database access (needed by SearchService)
    private var db: OpaquePointer? {
        // Access storage's db through a method we'll add
        nil // SearchService will use storage directly
    }

    // MARK: - Initialization

    init(databasePath: String? = nil) {
        self.monitor = ClipboardMonitor()
        self.storage = StorageService(databasePath: databasePath)
        self.search = SearchService(storage: storage)

        var continuation: AsyncStream<ClipboardEvent>.Continuation!
        self.eventStream = AsyncStream { cont in
            continuation = cont
        }
        self.eventContinuation = continuation
    }

    deinit {
        monitorTask?.cancel()
    }

    // MARK: - Lifecycle

    func start() async throws {
        // Open storage
        try storage.open()

        // Set up search service with database reference
        search.setDatabase(storage.database)

        // Load settings
        settings = try await getSettings()

        // Apply settings to cleanup
        storage.cleanupSettings.maxItems = settings.maxItems
        storage.cleanupSettings.maxSmallStorageMB = settings.maxStorageMB

        // Start clipboard monitoring
        monitor.startMonitoring()

        // Listen for clipboard events
        monitorTask = Task { [weak self] in
            guard let self = self else { return }
            for await content in self.monitor.contentStream {
                // 避免阻塞事件循环
                Task { @MainActor in
                    await self.handleNewContent(content)
                }
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        monitor.stopMonitoring()
        storage.close()
    }

    // MARK: - ClipboardServiceProtocol Implementation

    func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
        let items = try storage.fetchRecent(limit: limit, offset: offset)
        return items.map { toDTO($0) }
    }

    func search(query: SearchRequest) async throws -> SearchResultPage {
        // Invalidate cache on new search
        if query.offset == 0 {
            search.invalidateCache()
        }

        let result = try await search.search(request: query)
        return SearchResultPage(
            items: result.items.map { toDTO($0) },
            total: result.total,
            hasMore: result.hasMore
        )
    }

    func pin(itemID: UUID) async throws {
        try storage.setPin(itemID, pinned: true)
        search.invalidateCache()
        eventContinuation?.yield(.itemPinned(itemID))
    }

    func unpin(itemID: UUID) async throws {
        try storage.setPin(itemID, pinned: false)
        search.invalidateCache()
        eventContinuation?.yield(.itemUnpinned(itemID))
    }

    func delete(itemID: UUID) async throws {
        try storage.deleteItem(itemID)
        search.invalidateCache()
        eventContinuation?.yield(.itemDeleted(itemID))
    }

    func clearAll() async throws {
        try storage.deleteAllExceptPinned()
        search.invalidateCache()
        eventContinuation?.yield(.settingsChanged)
    }

    func copyToClipboard(itemID: UUID) async throws {
        guard let item = try storage.findByID(itemID) else { return }

        switch item.type {
        case .text:
            monitor.copyToClipboard(text: item.plainText)
        case .rtf, .html, .image:
            if let storageRef = item.storageRef {
                let data = try storage.loadExternalData(path: storageRef)
                let pasteboardType: NSPasteboard.PasteboardType
                switch item.type {
                case .rtf: pasteboardType = .rtf
                case .html: pasteboardType = .html
                case .image: pasteboardType = .png
                default: pasteboardType = .string
                }
                monitor.copyToClipboard(data: data, type: pasteboardType)
            }
        case .file:
            // For files, copy the path
            monitor.copyToClipboard(text: item.plainText)
        case .other:
            monitor.copyToClipboard(text: item.plainText)
        }

        // Update usage stats
        var updated = item
        updated.lastUsedAt = Date()
        updated.useCount += 1
        try? storage.updateItem(updated)
    }

    func updateSettings(_ newSettings: SettingsDTO) async throws {
        settings = newSettings

        // Update cleanup settings
        storage.cleanupSettings.maxItems = newSettings.maxItems
        storage.cleanupSettings.maxSmallStorageMB = newSettings.maxStorageMB

        // Save to UserDefaults
        saveSettingsToDefaults(newSettings)

        // Trigger cleanup if needed
        try? storage.performCleanup()

        eventContinuation?.yield(.settingsChanged)
    }

    func getSettings() async throws -> SettingsDTO {
        return loadSettingsFromDefaults()
    }

    func getStorageStats() async throws -> (itemCount: Int, sizeBytes: Int) {
        let count = try storage.getItemCount()
        let size = try storage.getTotalSize()
        return (count, size)
    }

    // MARK: - Private Methods

    private func handleNewContent(_ content: ClipboardMonitor.ClipboardContent) async {
        // Skip if not saving images/files based on settings
        if content.type == .image && !settings.saveImages { return }
        if content.type == .file && !settings.saveFiles { return }

        do {
            let storedItem = try storage.upsertItem(content)
            search.invalidateCache()
            eventContinuation?.yield(.newItem(toDTO(storedItem)))

            // Periodic cleanup
            try? storage.performCleanup()
        } catch {
            print("Failed to store clipboard item: \(error)")
        }
    }

    private func toDTO(_ item: StorageService.StoredItem) -> ClipboardItemDTO {
        ClipboardItemDTO(
            id: item.id,
            type: item.type,
            contentHash: item.contentHash,
            plainText: item.plainText,
            appBundleID: item.appBundleID,
            createdAt: item.createdAt,
            lastUsedAt: item.lastUsedAt,
            isPinned: item.isPinned,
            sizeBytes: item.sizeBytes
        )
    }

    // MARK: - Settings Persistence

    private let settingsKey = "ScopySettings"

    private func saveSettingsToDefaults(_ settings: SettingsDTO) {
        let dict: [String: Any] = [
            "maxItems": settings.maxItems,
            "maxStorageMB": settings.maxStorageMB,
            "saveImages": settings.saveImages,
            "saveFiles": settings.saveFiles
        ]
        UserDefaults.standard.set(dict, forKey: settingsKey)
    }

    private func loadSettingsFromDefaults() -> SettingsDTO {
        guard let dict = UserDefaults.standard.dictionary(forKey: settingsKey) else {
            return .default
        }
        return SettingsDTO(
            maxItems: dict["maxItems"] as? Int ?? SettingsDTO.default.maxItems,
            maxStorageMB: dict["maxStorageMB"] as? Int ?? SettingsDTO.default.maxStorageMB,
            saveImages: dict["saveImages"] as? Bool ?? SettingsDTO.default.saveImages,
            saveFiles: dict["saveFiles"] as? Bool ?? SettingsDTO.default.saveFiles
        )
    }
}

// MARK: - Service Factory

/// Factory for creating clipboard services
enum ClipboardServiceFactory {
    /// Create appropriate service based on environment
    @MainActor
    static func create(useMock: Bool = false, databasePath: String? = nil) -> ClipboardServiceProtocol {
        if useMock {
            return MockClipboardService()
        } else {
            return RealClipboardService(databasePath: databasePath)
        }
    }

    /// Create service for testing with in-memory database
    @MainActor
    static func createForTesting() -> RealClipboardService {
        RealClipboardService(databasePath: ":memory:")
    }
}
