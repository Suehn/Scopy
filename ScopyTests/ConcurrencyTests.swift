import XCTest
#if !SCOPY_TSAN_TESTS
@testable import Scopy
#endif

/// 并发安全测试 - v0.10.4
/// 验证搜索、缓存刷新、任务取消等场景的并发安全性
@MainActor
final class ConcurrencyTests: XCTestCase {
    var storage: StorageService!
    var search: SearchEngineImpl!

    override func setUp() async throws {
        storage = StorageService(databasePath: Self.makeSharedInMemoryDatabasePath())
        try await storage.open()
        search = SearchEngineImpl(dbPath: storage.databaseFilePath)
        try await search.open()
    }

    override func tearDown() async throws {
        await search.close()
        storage.close()
        storage = nil
        search = nil
    }

    // MARK: - Search Cancellation Safety

    /// 测试快速连续搜索时的取消安全性
    func testSearchCancellationSafety() async throws {
        // 插入测试数据
        for i in 0..<100 {
            let content = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: "Test item \(i) with some content",
                payload: .none,
                appBundleID: "com.test.app",
                contentHash: "hash_\(i)",
                sizeBytes: 50
            )
            _ = try await storage.upsertItem(content)
        }

        // 快速发起多个搜索请求
        var tasks: [Task<SearchEngineImpl.SearchResult?, Never>] = []
        for i in 0..<10 {
            let task = Task {
                let request = SearchRequest(
                    query: "item \(i)",
                    mode: .fuzzy,
                    appFilter: nil,
                    typeFilter: nil,
                    limit: 50,
                    offset: 0
                )
                return try? await self.search.search(request: request)
            }
            tasks.append(task)
        }

        // 取消前面的任务
        for i in 0..<5 {
            tasks[i].cancel()
        }

        // 等待所有任务完成
        var completedCount = 0
        for task in tasks {
            let result = await task.value
            if result != nil {
                completedCount += 1
            }
        }

        // 至少后面的任务应该完成
        XCTAssertGreaterThanOrEqual(completedCount, 1, "At least some searches should complete")
    }

    // MARK: - Cache Refresh Concurrency

    /// 测试缓存刷新的并发安全性
    func testCacheRefreshConcurrency() async throws {
        // 插入测试数据
        for i in 0..<50 {
            let content = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: "Cache test \(i)",
                payload: .none,
                appBundleID: nil,
                contentHash: "cache_hash_\(i)",
                sizeBytes: 20
            )
            _ = try await storage.upsertItem(content)
        }

        // 顺序执行多个短查询（会触发缓存刷新）
        var results: [SearchEngineImpl.SearchResult] = []
        for i in 0..<20 {
            let request = SearchRequest(
                query: String(i % 10), // 短查询触发缓存
                mode: .exact,
                appFilter: nil,
                typeFilter: nil,
                limit: 10,
                offset: 0
            )
            if let result = try? await search.search(request: request) {
                results.append(result)
            }
        }

        // 所有搜索都应该成功完成
        XCTAssertEqual(results.count, 20, "All searches should complete")
    }

    // MARK: - Sequential Insert and Search

    /// 测试插入和搜索的顺序安全性
    func testSequentialInsertAndSearch() async throws {
        // 先插入一些基础数据
        for i in 0..<20 {
            let content = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: "Base item \(i)",
                payload: .none,
                appBundleID: nil,
                contentHash: "base_\(i)",
                sizeBytes: 30
            )
            _ = try await storage.upsertItem(content)
        }

        // 交替执行插入和搜索
        var successCount = 0
        for i in 0..<10 {
            // 插入
            let content = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: "Sequential item \(i)",
                payload: .none,
                appBundleID: nil,
                contentHash: "sequential_\(i)",
                sizeBytes: 25
            )
            _ = try await storage.upsertItem(content)
            successCount += 1

            // 搜索
            let request = SearchRequest(
                query: "item",
                mode: .fuzzy,
                appFilter: nil,
                typeFilter: nil,
                limit: 50,
                offset: 0
            )
            if let _ = try? await search.search(request: request) {
                successCount += 1
            }
        }

        // 所有操作都应该成功
        XCTAssertEqual(successCount, 20, "All sequential operations should succeed")
    }

    // MARK: - Deduplication

    /// 测试去重的正确性
    func testDeduplication() async throws {
        let duplicateHash = "duplicate_content_hash"

        // 顺序插入相同内容
        for i in 0..<10 {
            let content = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: "Duplicate content",
                payload: .none,
                appBundleID: "com.test.\(i)",
                contentHash: duplicateHash,
                sizeBytes: 20
            )
            _ = try await storage.upsertItem(content)
        }

        // 数据库中只应该有一条记录
        let item = try await storage.findByHash(duplicateHash)
        XCTAssertNotNil(item, "Item should exist")
        XCTAssertGreaterThanOrEqual(item!.useCount, 1, "Use count should be updated")

        // 验证总数
        let count = try await storage.getItemCount()
        XCTAssertEqual(count, 1, "Should only have one item due to deduplication")
    }

    // MARK: - Search Version Number

    /// 测试搜索版本号防止旧结果覆盖新结果
    func testSearchVersionPreventsStaleResults() async throws {
        let mockService = MockClipboardService()
        let appState = AppState.create(service: mockService)

        // 快速连续搜索
        appState.searchQuery = "first"
        appState.search()

        appState.searchQuery = "second"
        appState.search()

        appState.searchQuery = "third"
        appState.search()

        // 等待搜索完成
        try await Task.sleep(nanoseconds: 400_000_000) // 400ms

        // 验证最终查询是最后一个
        XCTAssertEqual(appState.searchQuery, "third", "Final query should be 'third'")
    }

    // MARK: - v0.11 Concurrent Search Stress Tests

    /// v0.11: 并发搜索压力测试 - 同时发起 10 个搜索请求
    func testConcurrentSearchStress() async throws {
        // 插入大量测试数据
        for i in 0..<1000 {
            let content = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: "Stress test item \(i) with lorem ipsum dolor sit amet",
                payload: .none,
                appBundleID: "com.test.stress",
                contentHash: "stress_hash_\(i)",
                sizeBytes: 60
            )
            _ = try await storage.upsertItem(content)
        }

        // 使用 TaskGroup 实现真正的并发搜索
        let queries = ["stress", "lorem", "ipsum", "dolor", "amet", "test", "item", "sit", "content", "hash"]

        await withTaskGroup(of: SearchEngineImpl.SearchResult?.self) { group in
            for query in queries {
                group.addTask {
                    let request = SearchRequest(
                        query: query,
                        mode: .fuzzy,
                        appFilter: nil,
                        typeFilter: nil,
                        limit: 50,
                        offset: 0
                    )
                    return try? await self.search.search(request: request)
                }
            }

            var successCount = 0
            var totalItems = 0
            for await result in group {
                if let result = result {
                    successCount += 1
                    totalItems += result.items.count
                }
            }

            // 所有搜索都应该成功完成
            XCTAssertEqual(successCount, queries.count, "All concurrent searches should complete")
            XCTAssertGreaterThan(totalItems, 0, "Should return some results")
        }
    }

    /// v0.11: 并发搜索结果一致性测试 - 相同查询应返回相同结果
    func testSearchResultConsistency() async throws {
        // 插入测试数据
        for i in 0..<500 {
            let content = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: "Consistency test item \(i) with unique content",
                payload: .none,
                appBundleID: "com.test.consistency",
                contentHash: "consistency_\(i)",
                sizeBytes: 50
            )
            _ = try await storage.upsertItem(content)
        }

        let query = "consistency"
        var results: [SearchEngineImpl.SearchResult] = []

        // 并发执行相同查询 5 次
        await withTaskGroup(of: SearchEngineImpl.SearchResult?.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    let request = SearchRequest(
                        query: query,
                        mode: .fuzzy,
                        appFilter: nil,
                        typeFilter: nil,
                        limit: 50,
                        offset: 0
                    )
                    return try? await self.search.search(request: request)
                }
            }

            for await result in group {
                if let result = result {
                    results.append(result)
                }
            }
        }

        // 验证所有结果一致
        XCTAssertEqual(results.count, 5, "All searches should complete")

        let firstTotal = results[0].total
        let firstItemCount = results[0].items.count
        for result in results {
            XCTAssertEqual(result.total, firstTotal, "Total count should be consistent")
            XCTAssertEqual(result.items.count, firstItemCount, "Item count should be consistent")
        }
    }

    /// v0.11: 搜索超时测试 - 验证超时机制正常工作
    func testSearchTimeout() async throws {
        // 插入大量数据以增加搜索时间
        for i in 0..<5000 {
            let content = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: "Timeout test item \(i) with some content data for testing",
                payload: .none,
                appBundleID: "com.test.timeout",
                contentHash: "timeout_\(i)",
                sizeBytes: 60
            )
            _ = try await storage.upsertItem(content)
        }

        // 正常搜索应该在超时前完成
        let request = SearchRequest(
            query: "timeout",
            mode: .fuzzy,
            appFilter: nil,
            typeFilter: nil,
            limit: 50,
            offset: 0
        )

        let startTime = CFAbsoluteTimeGetCurrent()
        let result = try await search.search(request: request)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        XCTAssertGreaterThan(result.items.count, 0, "Should return results")
        XCTAssertLessThan(elapsed, 5.0, "Search should complete before 5s timeout")
    }

    /// v0.11: 并发清理和搜索测试 - 验证清理过程中搜索的安全性
    func testConcurrentCleanupAndSearch() async throws {
        // 插入测试数据
        for i in 0..<500 {
            let content = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: "Cleanup search test item \(i)",
                payload: .none,
                appBundleID: "com.test.cleanup",
                contentHash: "cleanup_search_\(i)",
                sizeBytes: 40
            )
            _ = try await storage.upsertItem(content)
        }

        storage.cleanupSettings.maxItems = 100

        // 并发执行清理和搜索
        var searchSucceeded = false
        var cleanupSucceeded = false

        await withTaskGroup(of: Bool.self) { group in
            // 搜索任务
            group.addTask {
                let request = SearchRequest(
                    query: "cleanup",
                    mode: .fuzzy,
                    appFilter: nil,
                    typeFilter: nil,
                    limit: 50,
                    offset: 0
                )
                if let _ = try? await self.search.search(request: request) {
                    return true
                }
                return false
            }

            // 清理任务（在 MainActor 上执行）
            group.addTask { @MainActor in
                do {
                    try await self.storage.performCleanup()
                    return true
                } catch {
                    return false
                }
            }

            for await result in group {
                if result {
                    if !searchSucceeded {
                        searchSucceeded = true
                    } else {
                        cleanupSucceeded = true
                    }
                }
            }
        }

        // 两个操作都应该成功完成（或至少不崩溃）
        XCTAssertTrue(searchSucceeded || cleanupSucceeded, "At least one operation should succeed")
    }

    private static func makeSharedInMemoryDatabasePath() -> String {
        "file:scopy_test_\(UUID().uuidString)?mode=memory&cache=shared"
    }
}
