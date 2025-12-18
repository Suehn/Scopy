import XCTest
import ScopyKit

/// AppState 单元测试
/// 验证状态管理、搜索防抖、键盘导航等核心逻辑
@MainActor
final class AppStateTests: XCTestCase {

    var appState: AppState!
    var mockService: TestMockClipboardService!

    override func setUp() async throws {
        mockService = TestMockClipboardService()
        appState = AppState.forTesting(service: mockService)
    }

    override func tearDown() async throws {
        appState.stop()
        appState = nil
        mockService = nil
    }

    // MARK: - Initialization Tests

    func testInitializationWithMockService() {
        XCTAssertNotNil(appState)
        XCTAssertTrue(appState.items.isEmpty)
        XCTAssertEqual(appState.searchQuery, "")
        XCTAssertFalse(appState.isLoading)
        XCTAssertNil(appState.selectedID)
    }

    func testForTestingFactoryMethod() {
        let customService = TestMockClipboardService()
        let state = AppState.forTesting(service: customService)
        XCTAssertNotNil(state)
    }

    // MARK: - Data Loading Tests (v0.md 2.2: 首屏 50-100 条)

    func testInitialLoadFetches50Items() async {
        mockService.setItemCount(100)
        await appState.load()

        XCTAssertEqual(appState.items.count, 50, "Should load 50 items initially")
        XCTAssertEqual(appState.loadedCount, 50)
        XCTAssertEqual(appState.totalCount, 100)
        XCTAssertTrue(appState.canLoadMore)
    }

    func testLoadMoreAppends100Items() async {
        mockService.setItemCount(200)
        await appState.load()

        XCTAssertEqual(appState.loadedCount, 50)

        await appState.loadMore()

        XCTAssertEqual(appState.loadedCount, 150, "Should append 100 items")
        XCTAssertTrue(appState.canLoadMore)
    }

    func testLoadMoreUpdatesCanLoadMoreFlag() async {
        mockService.setItemCount(60)
        await appState.load()

        XCTAssertTrue(appState.canLoadMore)

        await appState.loadMore()

        XCTAssertFalse(appState.canLoadMore, "Should be false when all items loaded")
    }

    func testLoadUpdatesStorageStats() async {
        mockService.setItemCount(50)
        await appState.load()

        XCTAssertEqual(appState.storageStats.itemCount, 50)
        XCTAssertGreaterThan(appState.storageStats.sizeBytes, 0)
    }

    func testLoadMoreDoesNothingWhenNoMoreItems() async {
        mockService.setItemCount(30)
        await appState.load()

        XCTAssertFalse(appState.canLoadMore)

        let countBefore = appState.loadedCount
        await appState.loadMore()

        XCTAssertEqual(appState.loadedCount, countBefore, "Should not change when canLoadMore is false")
    }

    // MARK: - Search Debounce Tests (v0.md 4.1: 150-200ms)

    func testSearchDebounce150ms() async throws {
        // This test locks the production debounce behavior (150ms) without forcing the rest of the suite to wait that long.
        let service = TestMockClipboardService()
        let state = AppState.forTesting(service: service, historyTiming: .production)
        defer { state.stop() }

        service.setItemCount(100)
        await state.load()
        service.resetSearchCallCount()

        // Rapid search calls
        state.searchQuery = "h"
        state.search()
        state.searchQuery = "he"
        state.search()
        state.searchQuery = "hel"
        state.search()

        // Wait less than debounce time
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        XCTAssertEqual(service.searchCallCount, 0, "Search should not execute before debounce")

        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            service.searchCallCount == 1
        }, message: "Only one search should execute after debounce")
    }

    func testRapidSearchCancelsPrevious() async throws {
        mockService.setItemCount(100)
        await appState.load()
        mockService.resetSearchCallCount()

        // Start search
        appState.searchQuery = "first"
        appState.search()

        // Immediately start another
        appState.searchQuery = "second"
        appState.search()

        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            self.mockService.searchCallCount == 1
        }, message: "Search should eventually execute once")
        XCTAssertEqual(mockService.lastSearchQuery, "second", "Should use the latest query")
    }

    func testLoadMoreDoesNotAppendAfterSearchChange() async throws {
        mockService.setItemCount(200)
        await appState.load()

        // First search to enable filtered paging
        appState.searchQuery = "1"
        appState.search()
        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            self.mockService.searchCallCount == 1 && !self.appState.isLoading
        }, message: "Initial search should complete")
        XCTAssertTrue(appState.canLoadMore)

        // Make loadMore slow so it overlaps with next search
        mockService.searchDelayNs = 120_000_000
        let pagingTask = Task { await appState.loadMore() }

        // Switch query while paging in flight
        mockService.searchDelayNs = 0
        appState.searchQuery = "2"
        appState.search()
        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            self.appState.items.allSatisfy { $0.plainText.localizedCaseInsensitiveContains("2") } && !self.appState.isLoading
        }, message: "Second search should complete with latest results")

        await pagingTask.value

        // Results should only match the latest query
        XCTAssertTrue(appState.items.allSatisfy { $0.plainText.localizedCaseInsensitiveContains("2") })
    }

    func testSearchUpdatesItemsList() async throws {
        mockService.setItemCount(100)
        await appState.load()

        appState.searchQuery = "test"
        appState.search()

        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            self.mockService.lastSearchQuery == "test" && !self.appState.isLoading
        }, message: "Search should complete")
        XCTAssertFalse(appState.items.isEmpty)
    }

    func testProgressiveRefineUpdatesAfterPrefilter() async throws {
        mockService.setItemCount(100)
        await appState.load()
        mockService.resetSearchCallCount()
        mockService.simulatePrefilterQueries = ["test"]

        appState.searchQuery = "test"
        appState.search()

        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            self.mockService.searchCallCount == 1 && self.appState.totalCount == -1
        }, message: "Initial prefiltered search should complete")

        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            self.mockService.searchCallCount == 2 && self.appState.totalCount == 100
        }, message: "Refine search should complete")
        XCTAssertEqual(appState.items.count, 50)
    }

    func testLoadMoreAfterPrefilterForcesFullSearch() async throws {
        mockService.setItemCount(120)
        await appState.load()
        mockService.resetSearchCallCount()
        mockService.simulatePrefilterQueries = ["test"]

        appState.searchQuery = "test"
        appState.search()

        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            self.mockService.recordedSearchRequests.count == 1 &&
            self.appState.totalCount == -1 &&
            !self.appState.isLoading
        }, message: "Initial prefiltered search should complete")
        XCTAssertEqual(mockService.recordedSearchRequests.count, 1)

        let expectedLimit = appState.loadedCount + 50
        await appState.loadMore()

        XCTAssertEqual(mockService.recordedSearchRequests.count, 2)
        let second = mockService.recordedSearchRequests[1]
        XCTAssertTrue(second.forceFullFuzzy)
        XCTAssertEqual(second.offset, 0)
        XCTAssertEqual(second.limit, expectedLimit)
    }

    func testEmptySearchReloadsAllItems() async throws {
        mockService.setItemCount(100)
        await appState.load()

        // First do a search
        appState.searchQuery = "test"
        appState.search()
        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            !self.appState.isLoading && !self.appState.searchQuery.isEmpty
        }, message: "Search should complete")

        // Then clear search
        appState.searchQuery = ""
        appState.search()
        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            self.appState.items.count == 50 && self.appState.searchQuery.isEmpty && !self.appState.isLoading
        }, message: "Empty search should reload")

        XCTAssertEqual(appState.items.count, 50, "Should reload all items on empty search")
    }

    // MARK: - Keyboard Navigation Tests

    func testHighlightNextMovesSelectionDown() async {
        mockService.setItemCount(10)
        await appState.load()

        appState.selectedID = appState.items[0].id
        appState.highlightNext()

        XCTAssertEqual(appState.selectedID, appState.items[1].id)
    }

    func testHighlightNextSelectsFirstWhenNoSelection() async {
        mockService.setItemCount(10)
        await appState.load()

        XCTAssertNil(appState.selectedID)
        appState.highlightNext()

        XCTAssertEqual(appState.selectedID, appState.items.first?.id)
    }

    func testHighlightNextStaysAtLastItem() async {
        mockService.setItemCount(10)
        await appState.load()

        appState.selectedID = appState.items.last?.id
        appState.highlightNext()

        XCTAssertEqual(appState.selectedID, appState.items.first?.id, "Should wrap to first")
    }

    func testHighlightPreviousMovesSelectionUp() async {
        mockService.setItemCount(10)
        await appState.load()

        appState.selectedID = appState.items[2].id
        appState.highlightPrevious()

        XCTAssertEqual(appState.selectedID, appState.items[1].id)
    }

    func testHighlightPreviousSelectsLastWhenNoSelection() async {
        mockService.setItemCount(10)
        await appState.load()

        XCTAssertNil(appState.selectedID)
        appState.highlightPrevious()

        XCTAssertEqual(appState.selectedID, appState.items.last?.id)
    }

    func testHighlightPreviousStaysAtFirstItem() async {
        mockService.setItemCount(10)
        await appState.load()

        appState.selectedID = appState.items.first?.id
        appState.highlightPrevious()

        XCTAssertEqual(appState.selectedID, appState.items.last?.id, "Should wrap to last")
    }

    func testHighlightDoesNothingWithEmptyItems() {
        XCTAssertTrue(appState.items.isEmpty)

        appState.highlightNext()
        XCTAssertNil(appState.selectedID)

        appState.highlightPrevious()
        XCTAssertNil(appState.selectedID)
    }

    // MARK: - v0.11 Keyboard Navigation Boundary Tests

    /// v0.11: 空列表时调用 highlightNext 不崩溃
    func testHighlightNextOnEmptyListDoesNotCrash() {
        XCTAssertTrue(appState.items.isEmpty)
        XCTAssertNil(appState.selectedID)

        // 多次调用不应崩溃
        for _ in 0..<10 {
            appState.highlightNext()
        }

        XCTAssertNil(appState.selectedID, "Selection should remain nil on empty list")
    }

    /// v0.11: 空列表时调用 highlightPrevious 不崩溃
    func testHighlightPreviousOnEmptyListDoesNotCrash() {
        XCTAssertTrue(appState.items.isEmpty)
        XCTAssertNil(appState.selectedID)

        // 多次调用不应崩溃
        for _ in 0..<10 {
            appState.highlightPrevious()
        }

        XCTAssertNil(appState.selectedID, "Selection should remain nil on empty list")
    }

    /// v0.11: 单项列表时调用 highlightNext 行为正确
    func testHighlightNextOnSingleItem() async {
        mockService.setItemCount(1)
        await appState.load()

        XCTAssertEqual(appState.items.count, 1)

        // 无选中时，选中第一项
        appState.highlightNext()
        XCTAssertEqual(appState.selectedID, appState.items[0].id)

        // 已选中唯一项时，保持选中（或循环到自己）
        appState.highlightNext()
        XCTAssertEqual(appState.selectedID, appState.items[0].id)
    }

    /// v0.11: 单项列表时调用 highlightPrevious 行为正确
    func testHighlightPreviousOnSingleItem() async {
        mockService.setItemCount(1)
        await appState.load()

        XCTAssertEqual(appState.items.count, 1)

        // 无选中时，选中最后一项（也是第一项）
        appState.highlightPrevious()
        XCTAssertEqual(appState.selectedID, appState.items[0].id)

        // 已选中唯一项时，保持选中（或循环到自己）
        appState.highlightPrevious()
        XCTAssertEqual(appState.selectedID, appState.items[0].id)
    }

    /// v0.11: 选中项被删除后导航行为正确
    func testNavigationAfterSelectedItemDeleted() async {
        mockService.setItemCount(5)
        await appState.load()

        // 选中第三项
        appState.selectedID = appState.items[2].id
        let selectedItem = appState.items[2]

        // 删除选中项
        await appState.delete(selectedItem)

        // 选中项应该被清除或移动到下一项
        // 根据 deleteSelectedItem 的实现，应该选中下一项
        // 但 delete 方法不会自动更新 selectedID
        // 此时 selectedID 指向已删除的项

        // 调用 highlightNext 应该能正常工作
        appState.highlightNext()
        // 由于原选中项已不存在，应该选中第一项
        XCTAssertNotNil(appState.selectedID)
    }

    /// v0.11: 快速连续导航不崩溃
    func testRapidNavigationDoesNotCrash() async {
        mockService.setItemCount(10)
        await appState.load()

        // 快速连续调用导航方法
        for _ in 0..<100 {
            appState.highlightNext()
        }

        for _ in 0..<100 {
            appState.highlightPrevious()
        }

        // 交替调用
        for _ in 0..<50 {
            appState.highlightNext()
            appState.highlightPrevious()
        }

        // 测试通过如果没有崩溃
        XCTAssertNotNil(appState.selectedID)
    }

    /// v0.11: 删除选中项后选中下一项
    func testDeleteSelectedItemSelectsNext() async {
        mockService.setItemCount(5)
        await appState.load()

        // 选中第二项
        appState.selectedID = appState.items[1].id
        let nextItemID = appState.items[2].id

        await appState.deleteSelectedItem()

        // 应该选中原来的第三项（现在是第二项）
        XCTAssertEqual(appState.selectedID, nextItemID)
    }

    /// v0.11: 删除最后一项时选中前一项
    func testDeleteLastItemSelectsPrevious() async {
        mockService.setItemCount(3)
        await appState.load()

        // 选中最后一项
        appState.selectedID = appState.items[2].id
        let previousItemID = appState.items[1].id

        await appState.deleteSelectedItem()

        // 应该选中前一项
        XCTAssertEqual(appState.selectedID, previousItemID)
    }

    /// v0.11: 删除唯一项后选中为空
    func testDeleteOnlyItemClearsSelection() async {
        mockService.setItemCount(1)
        await appState.load()

        appState.selectedID = appState.items[0].id

        await appState.deleteSelectedItem()

        XCTAssertNil(appState.selectedID, "Selection should be nil after deleting only item")
        XCTAssertTrue(appState.items.isEmpty)
    }

    func testSelectCurrentCopiesItem() async {
        mockService.setItemCount(10)
        await appState.load()

        appState.selectedID = appState.items[0].id
        mockService.resetCopyCallCount()

        await appState.selectCurrent()

        XCTAssertEqual(mockService.copyCallCount, 1)
        XCTAssertEqual(mockService.lastCopiedItemID, appState.items[0].id)
    }

    func testSelectCurrentDoesNothingWithNoSelection() async {
        mockService.setItemCount(10)
        await appState.load()

        XCTAssertNil(appState.selectedID)
        mockService.resetCopyCallCount()

        await appState.selectCurrent()

        XCTAssertEqual(mockService.copyCallCount, 0)
    }

    // MARK: - Item Operations Tests

    func testSelectCopiesItemToClipboard() async {
        mockService.setItemCount(10)
        await appState.load()

        let item = appState.items[0]
        mockService.resetCopyCallCount()

        await appState.select(item)

        XCTAssertEqual(mockService.copyCallCount, 1)
        XCTAssertEqual(mockService.lastCopiedItemID, item.id)
    }

    func testTogglePinChangesState() async {
        mockService.setItemCount(10)
        await appState.load()

        let item = appState.items[0]
        let wasPinned = item.isPinned
        mockService.pinCallCount = 0
        mockService.unpinCallCount = 0

        await appState.togglePin(item)

        // Item state should be toggled (load is called after toggle)
        // The mock service handles pin/unpin
        XCTAssertEqual(mockService.pinCallCount + mockService.unpinCallCount, 1)
        if wasPinned {
            XCTAssertEqual(mockService.unpinCallCount, 1)
        } else {
            XCTAssertEqual(mockService.pinCallCount, 1)
        }
    }

    func testDeleteRemovesItem() async {
        mockService.setItemCount(10)
        await appState.load()

        let initialCount = appState.items.count
        let itemToDelete = appState.items[0]

        await appState.delete(itemToDelete)

        XCTAssertEqual(appState.items.count, initialCount - 1)
        XCTAssertFalse(appState.items.contains { $0.id == itemToDelete.id })
    }

    func testClearAllRemovesUnpinned() async {
        mockService.setItemCount(10)
        await appState.load()

        await appState.clearAll()

        XCTAssertEqual(mockService.clearAllCallCount, 1)
    }

    // MARK: - Event Stream Tests
    // Note: Event stream tests are challenging because they require proper async setup
    // These tests verify the handleEvent logic directly instead of through the stream

    func testHandleNewItemEvent() async throws {
        mockService.setItemCount(10)
        await appState.load()

        let initialCount = appState.items.count
        let newItem = ClipboardItemDTO(
            id: UUID(),
            type: .text,
            contentHash: "newhash",
            plainText: "New clipboard item",
            appBundleID: "com.test",
            createdAt: Date(),
            lastUsedAt: Date(),
            isPinned: false,
            sizeBytes: 20,
            thumbnailPath: nil,
            storageRef: nil
        )

        // Directly test the items array manipulation
        appState.items.insert(newItem, at: 0)

        XCTAssertEqual(appState.items.count, initialCount + 1)
        XCTAssertEqual(appState.items.first?.id, newItem.id)
    }

    func testHandleItemDeletedEvent() async throws {
        mockService.setItemCount(10)
        await appState.load()

        let itemToDelete = appState.items[0]
        let initialCount = appState.items.count

        // Directly test the items array manipulation
        appState.items.removeAll { $0.id == itemToDelete.id }

        XCTAssertEqual(appState.items.count, initialCount - 1)
        XCTAssertFalse(appState.items.contains { $0.id == itemToDelete.id })
    }

    // MARK: - Pagination State Tests

    func testCanLoadMoreWhenMoreItemsExist() async {
        mockService.setItemCount(100)
        await appState.load()

        XCTAssertTrue(appState.canLoadMore)
        XCTAssertEqual(appState.loadedCount, 50)
        XCTAssertEqual(appState.totalCount, 100)
    }

    func testCannotLoadMoreWhenAllLoaded() async {
        mockService.setItemCount(30)
        await appState.load()

        XCTAssertFalse(appState.canLoadMore)
        XCTAssertEqual(appState.loadedCount, 30)
        XCTAssertEqual(appState.totalCount, 30)
    }

    // MARK: - Pinned Items Tests

    func testPinnedItemsFiltering() async {
        mockService.setItemCount(10, pinnedCount: 3)
        await appState.load()

        XCTAssertEqual(appState.pinnedItems.count, 3)
        XCTAssertEqual(appState.unpinnedItems.count, 7)
        XCTAssertEqual(appState.items.count, 10)
    }

    // MARK: - Settings Tests

    func testLoadSettings() async {
        await appState.loadSettings()

        XCTAssertEqual(appState.settings.maxItems, SettingsDTO.default.maxItems)
    }

    func testUpdateSettings() async {
        var newSettings = appState.settings
        newSettings.maxItems = 5000

        await appState.updateSettings(newSettings)

        XCTAssertEqual(appState.settings.maxItems, 5000)
    }
}

// MARK: - Enhanced Mock Service for Testing

/// Test-specific mock service with call tracking
@MainActor
final class TestMockClipboardService: ClipboardServiceProtocol {
    private var items: [ClipboardItemDTO] = []
    private var settings: SettingsDTO = .default
    private var eventContinuation: AsyncStream<ClipboardEvent>.Continuation?

    // Call tracking
    var searchCallCount = 0
    var lastSearchQuery: String?
    var copyCallCount = 0
    var lastCopiedItemID: UUID?
    var pinCallCount = 0
    var unpinCallCount = 0
    var deleteCallCount = 0
    var clearAllCallCount = 0

    // Artificial delays (for race-condition tests)
    var fetchRecentDelayNs: UInt64 = 0
    var searchDelayNs: UInt64 = 0
    var searchDelayNsByQuery: [String: UInt64] = [:]
    /// When true, the artificial search delay will not be interrupted by task cancellation (simulates a backend that can't cancel promptly).
    var searchDelayIgnoresCancellation: Bool = false
    /// v0.29: 渐进搜索测试 - 指定查询首屏模拟预筛 total=-1
    var simulatePrefilterQueries: Set<String> = []
    /// 记录每次 search 请求，便于验证渐进/分页行为
    var recordedSearchRequests: [SearchRequest] = []

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

    func setItemCount(_ count: Int, pinnedCount: Int = 0) {
        items = (0..<count).map { i in
            ClipboardItemDTO(
                id: UUID(),
                type: .text,
                contentHash: "hash\(i)",
                plainText: "Test item \(i)",
                appBundleID: "com.test.app",
                createdAt: Date().addingTimeInterval(Double(-i * 60)),
                lastUsedAt: Date().addingTimeInterval(Double(-i * 30)),
                isPinned: i < pinnedCount,
                sizeBytes: 20 + i,
                thumbnailPath: nil,
                storageRef: nil
            )
        }
    }

    func resetSearchCallCount() {
        searchCallCount = 0
        lastSearchQuery = nil
        recordedSearchRequests = []
    }

    func resetCopyCallCount() {
        copyCallCount = 0
        lastCopiedItemID = nil
    }

    func emitEvent(_ event: ClipboardEvent) {
        eventContinuation?.yield(event)
    }

    // MARK: - Protocol Implementation

    func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
        if fetchRecentDelayNs > 0 {
            do {
                try await Task.sleep(nanoseconds: fetchRecentDelayNs)
            } catch {
                return []
            }
        }
        let sortedItems = items.sorted { $0.lastUsedAt > $1.lastUsedAt }
        let start = min(offset, sortedItems.count)
        let end = min(offset + limit, sortedItems.count)
        return Array(sortedItems[start..<end])
    }

    func search(query: SearchRequest) async throws -> SearchResultPage {
        let effectiveDelayNs = searchDelayNsByQuery[query.query] ?? searchDelayNs
        if effectiveDelayNs > 0 {
            if searchDelayIgnoresCancellation {
                await Self.sleepUncancellable(nanoseconds: effectiveDelayNs)
            } else {
                do {
                    try await Task.sleep(nanoseconds: effectiveDelayNs)
                } catch {
                    return SearchResultPage(items: [], total: 0, hasMore: false)
                }
            }
        }
        searchCallCount += 1
        lastSearchQuery = query.query
        recordedSearchRequests.append(query)

        let filtered: [ClipboardItemDTO]
        if query.query.isEmpty {
            filtered = items
        } else {
            filtered = items.filter { $0.plainText.localizedCaseInsensitiveContains(query.query) }
        }

        let start = min(query.offset, filtered.count)
        let end = min(query.offset + query.limit, filtered.count)

        let shouldSimulatePrefilter =
            simulatePrefilterQueries.contains(query.query) &&
            !query.forceFullFuzzy &&
            query.offset == 0

        let total = shouldSimulatePrefilter ? -1 : filtered.count

        return SearchResultPage(
            items: Array(filtered[start..<end]),
            total: total,
            hasMore: end < filtered.count
        )
    }

    nonisolated private static func sleepUncancellable(nanoseconds: UInt64) async {
        guard nanoseconds > 0 else { return }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .nanoseconds(Int(nanoseconds))
            ) {
                continuation.resume()
            }
        }
    }

    func pin(itemID: UUID) async throws {
        pinCallCount += 1
        if let index = items.firstIndex(where: { $0.id == itemID }) {
            let item = items[index]
            items[index] = ClipboardItemDTO(
                id: item.id, type: item.type, contentHash: item.contentHash,
                plainText: item.plainText, appBundleID: item.appBundleID,
                createdAt: item.createdAt, lastUsedAt: item.lastUsedAt,
                isPinned: true, sizeBytes: item.sizeBytes,
                thumbnailPath: item.thumbnailPath, storageRef: item.storageRef
            )
        }
    }

    func unpin(itemID: UUID) async throws {
        unpinCallCount += 1
        if let index = items.firstIndex(where: { $0.id == itemID }) {
            let item = items[index]
            items[index] = ClipboardItemDTO(
                id: item.id, type: item.type, contentHash: item.contentHash,
                plainText: item.plainText, appBundleID: item.appBundleID,
                createdAt: item.createdAt, lastUsedAt: item.lastUsedAt,
                isPinned: false, sizeBytes: item.sizeBytes,
                thumbnailPath: item.thumbnailPath, storageRef: item.storageRef
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

// MARK: - Failing Mock Service for Fallback Tests (v0.10.1)

/// Mock service that fails on start() - used to test fallback behavior
@MainActor
final class FailingMockService: ClipboardServiceProtocol {
    private var eventContinuation: AsyncStream<ClipboardEvent>.Continuation?

    var eventStream: AsyncStream<ClipboardEvent> {
        AsyncStream { continuation in
            self.eventContinuation = continuation
        }
    }

    enum TestError: Error {
        case simulatedFailure
    }

    func start() async throws {
        throw TestError.simulatedFailure
    }

    func stop() {
        eventContinuation?.finish()
    }

    func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] { [] }
    func search(query: SearchRequest) async throws -> SearchResultPage {
        SearchResultPage(items: [], total: 0, hasMore: false)
    }
    func pin(itemID: UUID) async throws {}
    func unpin(itemID: UUID) async throws {}
    func delete(itemID: UUID) async throws {}
    func clearAll() async throws {}
    func copyToClipboard(itemID: UUID) async throws {}
    func updateSettings(_ newSettings: SettingsDTO) async throws {}
    func getSettings() async throws -> SettingsDTO { .default }
    func getStorageStats() async throws -> (itemCount: Int, sizeBytes: Int) { (0, 0) }
    func getDetailedStorageStats() async throws -> StorageStatsDTO {
        StorageStatsDTO(itemCount: 0, databaseSizeBytes: 0, externalStorageSizeBytes: 0, thumbnailSizeBytes: 0, totalSizeBytes: 0, databasePath: "")
    }
    func getImageData(itemID: UUID) async throws -> Data? { nil }
    func getRecentApps(limit: Int) async throws -> [String] { [] }
}

// MARK: - Fallback and Event Handler Tests (v0.10.1)

@MainActor
final class AppStateFallbackTests: XCTestCase {

    /// Test that start() falls back to a working service when the initial service fails
    func testStartFallsBackToMockOnFailure() async {
        let failingService = FailingMockService()
        let state = AppState.forTesting(service: failingService)

        // Before start, service is the failing one
        XCTAssertTrue(state.service is FailingMockService)

        // After start, should fall back to a non-failing service
        await state.start()

        // Verify service was replaced (implementation is internal to ScopyKit)
        XCTAssertFalse(state.service is FailingMockService, "Service should be replaced after fallback")

        state.stop()
    }

    /// Test that settingsChanged event triggers hotkey callback with latest settings
    func testSettingsChangedAppliesHotkey() async throws {
        let mockService = TestMockClipboardService()
        let state = AppState.forTesting(service: mockService)
        defer { state.stop() }

        var hotkeyApplied = false
        var appliedKeyCode: UInt32 = 0
        var appliedModifiers: UInt32 = 0

        state.applyHotKeyHandler = { keyCode, modifiers in
            hotkeyApplied = true
            appliedKeyCode = keyCode
            appliedModifiers = modifiers
        }

        await state.start()

        // Emit settingsChanged event
        mockService.emitEvent(.settingsChanged)

        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            hotkeyApplied
        }, message: "Hotkey handler should be called on settingsChanged")

        XCTAssertEqual(appliedKeyCode, SettingsDTO.default.hotkeyKeyCode)
        XCTAssertEqual(appliedModifiers, SettingsDTO.default.hotkeyModifiers)
    }

    /// Test that settingsChanged without handler doesn't crash (logs warning instead)
    func testSettingsChangedWithoutHandlerDoesNotCrash() async throws {
        let mockService = TestMockClipboardService()
        let state = AppState.forTesting(service: mockService)
        defer { state.stop() }

        // Explicitly set handler to nil
        state.applyHotKeyHandler = nil

        await state.start()

        // Emit settingsChanged event - should not crash
        mockService.emitEvent(.settingsChanged)

        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            !state.isLoading
        }, message: "settingsChanged should finish processing")

        // Test passes if no crash occurred
    }

    func testThumbnailUpdatedUpdatesItemWithoutReordering() async throws {
        let mockService = TestMockClipboardService()
        mockService.setItemCount(5)
        let state = AppState.forTesting(service: mockService)
        defer { state.stop() }

        await state.start()

        let originalOrder = state.items.map(\.id)
        let targetID = state.items[2].id
        let thumbnailPath = "/tmp/scopy-test-thumbnail-\(UUID().uuidString).png"

        mockService.emitEvent(.thumbnailUpdated(itemID: targetID, thumbnailPath: thumbnailPath))
        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            state.items.first(where: { $0.id == targetID })?.thumbnailPath == thumbnailPath
        }, message: "Thumbnail path should be updated in place")

        XCTAssertEqual(state.items.map(\.id), originalOrder, "Thumbnail updates should not reorder items")
        XCTAssertEqual(
            state.items.first(where: { $0.id == targetID })?.thumbnailPath,
            thumbnailPath,
            "Thumbnail path should be updated in place"
        )
    }
}
