import Foundation
@testable import Scopy

// MARK: - Reusable Mock ClipboardService

/// 可配置的 Mock ClipboardService (通用版本)
/// 用于单元测试，支持调用追踪和行为配置
/// 注意：与 AppStateTests 中的 TestMockClipboardService 接口相同但更完整
@MainActor
final class ReusableMockClipboardService: ClipboardServiceProtocol {

    // MARK: - Properties

    private(set) var items: [ClipboardItemDTO] = []
    private var settings: SettingsDTO = .default
    private var eventContinuation: AsyncStream<ClipboardEvent>.Continuation?

    // MARK: - Call Tracking

    private(set) var searchCallCount = 0
    private(set) var copyCallCount = 0
    private(set) var pinCallCount = 0
    private(set) var unpinCallCount = 0
    private(set) var deleteCallCount = 0
    private(set) var clearAllCallCount = 0
    private(set) var fetchRecentCallCount = 0

    private(set) var lastSearchQuery: String?
    private(set) var lastSearchMode: SearchMode?
    private(set) var lastCopiedItemID: UUID?

    // MARK: - Configuration

    var searchDelay: TimeInterval = 0
    var shouldFailSearch = false
    var searchError: Error?
    var customSearchResults: [ClipboardItemDTO]?

    // MARK: - Event Stream

    var eventStream: AsyncStream<ClipboardEvent> {
        AsyncStream { continuation in
            self.eventContinuation = continuation
        }
    }

    // MARK: - Lifecycle

    func start() async throws {
        // Mock 服务无需启动，空实现
    }

    func stop() {
        eventContinuation?.finish()
    }

    // MARK: - Setup Helpers

    func setItems(_ items: [ClipboardItemDTO]) {
        self.items = items
    }

    func setItemCount(_ count: Int, pinnedCount: Int = 0) {
        items = TestDataFactory.makeItems(count: count)
        // Set pinned status for first `pinnedCount` items
        for i in 0..<min(pinnedCount, count) {
            let item = items[i]
            items[i] = ClipboardItemDTO(
                id: item.id,
                type: item.type,
                contentHash: item.contentHash,
                plainText: item.plainText,
                appBundleID: item.appBundleID,
                createdAt: item.createdAt,
                lastUsedAt: item.lastUsedAt,
                isPinned: true,
                sizeBytes: item.sizeBytes,
                thumbnailPath: item.thumbnailPath,
                storageRef: item.storageRef
            )
        }
    }

    func resetCallCounts() {
        searchCallCount = 0
        copyCallCount = 0
        pinCallCount = 0
        unpinCallCount = 0
        deleteCallCount = 0
        clearAllCallCount = 0
        fetchRecentCallCount = 0
        lastSearchQuery = nil
        lastSearchMode = nil
        lastCopiedItemID = nil
    }

    // MARK: - Event Emission

    func emitEvent(_ event: ClipboardEvent) {
        eventContinuation?.yield(event)
    }

    func emitNewItem(_ item: ClipboardItemDTO) {
        items.insert(item, at: 0)
        emitEvent(.newItem(item))
    }

    // MARK: - ClipboardServiceProtocol

    func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
        fetchRecentCallCount += 1

        let sortedItems = items.sorted { $0.lastUsedAt > $1.lastUsedAt }
        let startIndex = min(offset, sortedItems.count)
        let endIndex = min(offset + limit, sortedItems.count)
        return Array(sortedItems[startIndex..<endIndex])
    }

    func search(query: SearchRequest) async throws -> SearchResultPage {
        searchCallCount += 1
        lastSearchQuery = query.query
        lastSearchMode = query.mode

        if searchDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(searchDelay * 1_000_000_000))
        }

        if shouldFailSearch {
            throw searchError ?? NSError(domain: "MockError", code: -1)
        }

        if let customResults = customSearchResults {
            return SearchResultPage(
                items: Array(customResults.prefix(query.limit)),
                total: customResults.count,
                hasMore: customResults.count > query.limit
            )
        }

        let filtered: [ClipboardItemDTO]
        if query.query.isEmpty {
            filtered = items
        } else {
            filtered = items.filter {
                $0.plainText.localizedCaseInsensitiveContains(query.query)
            }
        }

        let startIndex = min(query.offset, filtered.count)
        let endIndex = min(query.offset + query.limit, filtered.count)
        let pageItems = Array(filtered[startIndex..<endIndex])

        return SearchResultPage(
            items: pageItems,
            total: filtered.count,
            hasMore: endIndex < filtered.count
        )
    }

    func pin(itemID: UUID) async throws {
        pinCallCount += 1
        if let index = items.firstIndex(where: { $0.id == itemID }) {
            let item = items[index]
            items[index] = ClipboardItemDTO(
                id: item.id,
                type: item.type,
                contentHash: item.contentHash,
                plainText: item.plainText,
                appBundleID: item.appBundleID,
                createdAt: item.createdAt,
                lastUsedAt: item.lastUsedAt,
                isPinned: true,
                sizeBytes: item.sizeBytes,
                thumbnailPath: item.thumbnailPath,
                storageRef: item.storageRef
            )
        }
    }

    func unpin(itemID: UUID) async throws {
        unpinCallCount += 1
        if let index = items.firstIndex(where: { $0.id == itemID }) {
            let item = items[index]
            items[index] = ClipboardItemDTO(
                id: item.id,
                type: item.type,
                contentHash: item.contentHash,
                plainText: item.plainText,
                appBundleID: item.appBundleID,
                createdAt: item.createdAt,
                lastUsedAt: item.lastUsedAt,
                isPinned: false,
                sizeBytes: item.sizeBytes,
                thumbnailPath: item.thumbnailPath,
                storageRef: item.storageRef
            )
        }
    }

    func delete(itemID: UUID) async throws {
        deleteCallCount += 1
        items.removeAll { $0.id == itemID }
    }

    func clearAll() async throws {
        clearAllCallCount += 1
        items = items.filter { $0.isPinned }
    }

    func copyToClipboard(itemID: UUID) async throws {
        copyCallCount += 1
        lastCopiedItemID = itemID
    }

    func updateSettings(_ newSettings: SettingsDTO) async throws {
        settings = newSettings
    }

    func getSettings() async throws -> SettingsDTO {
        return settings
    }

    func getStorageStats() async throws -> (itemCount: Int, sizeBytes: Int) {
        let totalBytes = items.reduce(0) { $0 + $1.sizeBytes }
        return (items.count, totalBytes)
    }

    func getDetailedStorageStats() async throws -> StorageStatsDTO {
        let totalBytes = items.reduce(0) { $0 + $1.sizeBytes }
        return StorageStatsDTO(
            itemCount: items.count,
            databaseSizeBytes: totalBytes,
            externalStorageSizeBytes: 0,
            thumbnailSizeBytes: 0,
            totalSizeBytes: totalBytes,
            databasePath: "~/Library/Application Support/Scopy/"
        )
    }

    func getImageData(itemID: UUID) async throws -> Data? {
        // Mock 服务不存储实际图片数据
        return nil
    }

    func getRecentApps(limit: Int) async throws -> [String] {
        // 返回 mock 数据中的 app 列表
        let apps = Set(items.compactMap { $0.appBundleID })
        return Array(apps.prefix(limit))
    }
}

// MARK: - Mock StorageService

/// Mock StorageService for testing (不依赖 SQLite)
final class MockInMemoryStorageService {

    private(set) var items: [ClipboardItemDTO] = []
    private(set) var insertCallCount = 0
    private(set) var fetchCallCount = 0

    func setItems(_ items: [ClipboardItemDTO]) {
        self.items = items
    }

    func upsertItem(_ content: ClipboardMonitor.ClipboardContent) throws -> ClipboardItemDTO {
        insertCallCount += 1
        let item = TestDataFactory.makeItem(plainText: content.plainText ?? "")
        items.insert(item, at: 0)
        return item
    }

    func fetchRecent(limit: Int, offset: Int) throws -> [ClipboardItemDTO] {
        fetchCallCount += 1
        let startIndex = min(offset, items.count)
        let endIndex = min(offset + limit, items.count)
        return Array(items[startIndex..<endIndex])
    }
}

// MARK: - Mock SearchService

/// Mock SearchService for testing (不依赖真实搜索)
final class MockInMemorySearchService {

    private(set) var searchCallCount = 0
    private(set) var lastQuery: String?
    var searchResults: [ClipboardItemDTO] = []
    var searchDelay: TimeInterval = 0

    func search(request: SearchRequest) async throws -> SearchResultPage {
        searchCallCount += 1
        lastQuery = request.query

        if searchDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(searchDelay * 1_000_000_000))
        }

        return SearchResultPage(
            items: searchResults,
            total: searchResults.count,
            hasMore: false
        )
    }
}
