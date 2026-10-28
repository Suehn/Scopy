import Foundation
import ScopyKit

// MARK: - Reusable ClipboardServiceProtocol Mock

/// A configurable `ClipboardServiceProtocol` mock that records calls; a fuller version of
/// AppStateTests' `TestMockClipboardService`.
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
        // Nothing to start.
    }

    func stop() {
        eventContinuation?.finish()
    }

    func stopAndWait() async {
        stop()
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
                storageRef: item.storageRef,
                useCount: item.useCount
            )
        }
    }

    // MARK: - Event Emission

    func emitEvent(_ event: ClipboardEvent) {
        eventContinuation?.yield(event)
    }

    // MARK: - ClipboardServiceProtocol

    func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
        fetchRecentCallCount += 1

        let sortedItems = items.sorted { $0.lastUsedAt > $1.lastUsedAt }
        let startIndex = min(offset, sortedItems.count)
        let endIndex = min(offset + limit, sortedItems.count)
        return Array(sortedItems[startIndex..<endIndex])
    }

    func fetchPinned() async throws -> [ClipboardItemDTO] {
        items.filter(\.isPinned).sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    private var mutationSeq: Int64 = 0

    func historyEvent(_ change: HistoryChange) -> ClipboardEvent {
        mutationSeq += 1
        return .history(CommittedHistoryChange(mutationSeq: mutationSeq, totalCount: items.count, change: change))
    }

    func fetchHistoryPage(limit: Int, after cursor: RecentHistoryCursor?) async throws -> RecentHistoryPage {
        RecentHistoryPage(slicing: items, limit: limit, after: cursor, mutationSeq: mutationSeq)
    }

    func fetchHistoryItems(itemIDs: Set<UUID>) async throws -> HistoryItemsSnapshot {
        HistoryItemsSnapshot(requestedItemIDs: itemIDs, items: items.filter { itemIDs.contains($0.id) }, mutationSeq: mutationSeq)
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
                hits: customResults.prefix(query.limit).map {
                    SearchResultHit(item: $0, matchContext: nil)
                },
                total: customResults.count,
                hasMore: customResults.count > query.limit,
                coverage: .complete,
                mutationSeq: mutationSeq
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
            hits: pageItems.map { SearchResultHit(item: $0, matchContext: nil) },
            total: filtered.count,
            hasMore: endIndex < filtered.count,
            coverage: .complete,
            mutationSeq: mutationSeq
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
                storageRef: item.storageRef,
                useCount: item.useCount
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
                storageRef: item.storageRef,
                useCount: item.useCount
            )
        }
    }

    func updateNote(itemID _: UUID, note _: String?) async throws {}

    func delete(itemID: UUID, expectedUseCount: Int) async throws -> HistoryItemsSnapshot {
        deleteCallCount += 1
        if let item = items.first(where: { $0.id == itemID }), item.useCount == expectedUseCount {
            items.removeAll { $0.id == itemID }
            mutationSeq += 1
        }
        return HistoryItemsSnapshot(requestedItemIDs: [itemID], items: items.filter { $0.id == itemID }, mutationSeq: mutationSeq)
    }

    func clearAll() async throws {
        clearAllCallCount += 1
        items = items.filter { $0.isPinned }
    }

    func copyToClipboard(itemID: UUID) async throws {
        copyCallCount += 1
        lastCopiedItemID = itemID
    }

    func copyToClipboardOptimizedForCodex(itemID: UUID) async throws {
        try await copyToClipboard(itemID: itemID)
    }

    func fileURLs(itemID _: UUID) async throws -> [URL] { [] }

    func updateSettings(_ patch: SettingsPatch) async throws -> SettingsDTO {
        settings = settings.applying(patch)
        return settings
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
        // The mock stores no image data.
        return nil
    }

    func optimizeImage(itemID: UUID) async throws -> ImageOptimizationOutcomeDTO {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            return ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: 0, optimizedBytes: 0)
        }
        let item = items[index]
        guard item.type == .image else {
            return ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: item.sizeBytes, optimizedBytes: item.sizeBytes)
        }

        let original = max(0, item.sizeBytes)
        let optimized = max(0, original - max(1, original / 4))
        let updated = ClipboardItemDTO(
            id: item.id,
            type: item.type,
            contentHash: UUID().uuidString,
            plainText: item.plainText,
            appBundleID: item.appBundleID,
            createdAt: item.createdAt,
            lastUsedAt: item.lastUsedAt,
            isPinned: item.isPinned,
            sizeBytes: optimized,
            thumbnailPath: item.thumbnailPath,
            storageRef: item.storageRef,
            useCount: item.useCount
        )
        items[index] = updated
        emitEvent(historyEvent(.itemsChanged([updated], kind: .content)))
        return ImageOptimizationOutcomeDTO(
            result: .optimized,
            originalBytes: original,
            optimizedBytes: optimized,
            resultingContentHash: updated.contentHash
        )
    }

    func syncExternalImageSizeBytesFromDisk() async throws -> Int { 0 }

    func getRecentApps(limit: Int) async throws -> [String] {
        // The apps in the mock data.
        let apps = Set(items.compactMap { $0.appBundleID })
        return Array(apps.prefix(limit))
    }
}

// MARK: - Mock StorageService

/// Mock StorageService for testing, without SQLite.
final class MockInMemoryStorageService {

    private(set) var items: [ClipboardItemDTO] = []
    private(set) var insertCallCount = 0
    private(set) var fetchCallCount = 0

    func setItems(_ items: [ClipboardItemDTO]) {
        self.items = items
    }

    func upsertItem(_ content: ClipboardMonitor.ClipboardContent) throws -> ClipboardItemDTO {
        insertCallCount += 1
        let item = TestDataFactory.makeItem(plainText: content.plainText)
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

/// Mock SearchService for testing, without a real search.
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
            hits: searchResults.map { SearchResultHit(item: $0, matchContext: nil) },
            total: searchResults.count,
            hasMore: false,
            coverage: .complete,
            mutationSeq: 0
        )
    }
}
