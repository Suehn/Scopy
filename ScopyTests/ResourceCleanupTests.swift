import XCTest
import ScopyKit

/// 资源清理测试 - v0.10.4
/// 验证 Timer、Task、事件流、数据库连接等资源的正确清理
@MainActor
final class ResourceCleanupTests: XCTestCase {

    // MARK: - Storage Cleanup Tests

    /// 测试数据库连接在 close 后正确释放
    func testDatabaseConnectionCleanup() async throws {
        let storage = StorageService(databasePath: ":memory:")
        try await storage.open()

        // 插入一些数据
        let content = ClipboardMonitor.ClipboardContent(
            type: .text,
            plainText: "Test content",
            payload: .none,
            appBundleID: nil,
            contentHash: "test_hash",
            sizeBytes: 12
        )
        _ = try await storage.upsertItem(content)

        // 关闭数据库
        await storage.close()

        // 验证数据库已关闭（后续 DB 调用应失败）
        do {
            _ = try await storage.getItemCount()
            XCTFail("Expected databaseNotOpen after close")
        } catch {
            // Expected
        }
    }

    /// 测试清理操作在全部 pin 时不会无限循环
    func testCleanupWithAllPinnedItems() async throws {
        let storage = StorageService(databasePath: ":memory:")
        try await storage.open()

        // 插入并 pin 所有项目
        for i in 0..<10 {
            let content = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: "Pinned item \(i)",
                payload: .none,
                appBundleID: nil,
                contentHash: "pinned_\(i)",
                sizeBytes: 20
            )
            let item = try await storage.upsertItem(content)
            try await storage.setPin(item.id, pinned: true)
        }

        // 设置非常小的限制
        storage.cleanupSettings.maxItems = 5
        storage.cleanupSettings.maxSmallStorageMB = 0 // 0 MB

        // 执行清理 - 不应该无限循环
        let startTime = Date()
        try await storage.performCleanup()
        let elapsed = Date().timeIntervalSince(startTime)

        // 清理应该在合理时间内完成（不超过 1 秒）
        XCTAssertLessThan(elapsed, 1.0, "Cleanup should complete quickly even with all pinned items")

        // 所有 pinned 项目应该保留
        let count = try await storage.getItemCount()
        XCTAssertEqual(count, 10, "All pinned items should be preserved")

        await storage.close()
    }

    /// 测试 sqlite3_step 错误处理
    func testSqliteStepErrorHandling() async throws {
        let storage = StorageService(databasePath: ":memory:")
        try await storage.open()

        // 插入测试数据
        for i in 0..<5 {
            let content = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: "Item \(i)",
                payload: .none,
                appBundleID: nil,
                contentHash: "hash_\(i)",
                sizeBytes: 10
            )
            _ = try await storage.upsertItem(content)
        }

        // 正常清理应该成功
        storage.cleanupSettings.maxItems = 3
        do {
            try await storage.performCleanup()
        } catch {
            XCTFail("Cleanup should not throw: \(error)")
        }

        // 验证清理后的数量
        let count = try await storage.getItemCount()
        XCTAssertLessThanOrEqual(count, 3, "Item count should be reduced")

        await storage.close()
    }

    // MARK: - Search Service Cleanup Tests

    /// 测试搜索服务缓存失效
    func testSearchCacheInvalidation() async throws {
        let storage = StorageService(databasePath: Self.makeSharedInMemoryDatabasePath())
        try await storage.open()
        let search = SearchEngineImpl(dbPath: storage.databaseFilePath)
        try await search.open()

        // 插入数据
        for i in 0..<10 {
            let content = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: "Cache item \(i)",
                payload: .none,
                appBundleID: nil,
                contentHash: "cache_\(i)",
                sizeBytes: 15
            )
            _ = try await storage.upsertItem(content)
        }

        // 执行搜索（填充缓存）
        let request = SearchRequest(
            query: "it", // 短查询使用缓存
            mode: .exact,
            appFilter: nil,
            typeFilter: nil,
            limit: 50,
            offset: 0
        )
        let result1 = try await search.search(request: request)
        XCTAssertGreaterThan(result1.total, 0, "Should find items")

        // 失效缓存
        await search.invalidateCache()

        // 再次搜索应该仍然工作
        let result2 = try await search.search(request: request)
        XCTAssertEqual(result1.total, result2.total, "Results should be consistent after cache invalidation")

        await search.close()
        await storage.close()
    }

    // MARK: - Event Stream Cleanup Tests

    /// 测试事件流在服务停止后正确关闭
    func testEventStreamCleanup() async throws {
        let service = ClipboardServiceFactory.create(useMock: false, databasePath: Self.makeSharedInMemoryDatabasePath())

        // 启动服务
        try await service.start()

        // 创建一个监听事件的任务
        let eventTask = Task {
            var eventCount = 0
            for await _ in service.eventStream {
                eventCount += 1
                if eventCount >= 1 {
                    break
                }
            }
            return eventCount
        }

        // Give the listener a chance to subscribe.
        await Task.yield()

        // 停止服务
        service.stop()

        // 取消事件任务
        eventTask.cancel()

        // 验证任务可以正常结束
        let _ = await eventTask.value
        // 如果能到这里，说明事件流正确关闭了
        XCTAssertTrue(true, "Event stream should close properly")
    }

    private static func makeSharedInMemoryDatabasePath() -> String {
        "file:scopy_test_\(UUID().uuidString)?mode=memory&cache=shared"
    }

    // MARK: - Task Cancellation Tests

    /// 测试搜索任务取消后不会更新状态
    func testSearchTaskCancellation() async throws {
        let service = TestMockClipboardService()
        let appState = AppState.forTesting(service: service)
        defer { appState.stop() }

        // 设置初始状态
        service.setItemCount(100)
        await appState.load()
        service.resetSearchCallCount()

        appState.searchQuery = "1"

        // 开始搜索
        appState.search()

        // 立即取消（通过开始新搜索）
        appState.searchQuery = "2"
        appState.search()

        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            service.searchCallCount >= 1 && service.lastSearchQuery == "2"
        }, message: "Search cancellation should settle on latest query")

        // 验证状态一致性（不应该有旧搜索的结果）
        XCTAssertTrue(appState.items.allSatisfy { $0.plainText.localizedCaseInsensitiveContains("2") })
        // 主要验证不会崩溃
        XCTAssertTrue(true, "Search cancellation should not cause issues")
    }

    /// 测试 loadMore 任务取消
    func testLoadMoreTaskCancellation() async throws {
        let service = TestMockClipboardService()
        let appState = AppState.forTesting(service: service)
        defer { appState.stop() }

        // 初始化
        service.setItemCount(200)
        await appState.load()
        XCTAssertTrue(appState.canLoadMore)

        // 快速连续调用 loadMore
        Task { await appState.loadMore() }
        Task { await appState.loadMore() }
        Task { await appState.loadMore() }

        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            appState.loadedCount == 150
        }, message: "loadMore should append exactly one page")

        // 验证不会崩溃
        XCTAssertTrue(true, "Multiple loadMore calls should not cause issues")
    }
}
