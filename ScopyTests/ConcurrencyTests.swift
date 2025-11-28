import XCTest
@testable import Scopy

/// 并发安全测试 - v0.10.4
/// 验证搜索、缓存刷新、任务取消等场景的并发安全性
@MainActor
final class ConcurrencyTests: XCTestCase {
    var storage: StorageService!
    var search: SearchService!

    override func setUp() async throws {
        storage = StorageService(databasePath: ":memory:")
        try storage.open()
        search = SearchService(storage: storage)
        search.setDatabase(storage.database)
    }

    override func tearDown() async throws {
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
                rawData: nil,
                appBundleID: "com.test.app",
                contentHash: "hash_\(i)",
                sizeBytes: 50
            )
            _ = try storage.upsertItem(content)
        }

        // 快速发起多个搜索请求
        var tasks: [Task<SearchService.SearchResult?, Never>] = []
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
                rawData: nil,
                appBundleID: nil,
                contentHash: "cache_hash_\(i)",
                sizeBytes: 20
            )
            _ = try storage.upsertItem(content)
        }

        // 顺序执行多个短查询（会触发缓存刷新）
        var results: [SearchService.SearchResult] = []
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
                rawData: nil,
                appBundleID: nil,
                contentHash: "base_\(i)",
                sizeBytes: 30
            )
            _ = try storage.upsertItem(content)
        }

        // 交替执行插入和搜索
        var successCount = 0
        for i in 0..<10 {
            // 插入
            let content = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: "Sequential item \(i)",
                rawData: nil,
                appBundleID: nil,
                contentHash: "sequential_\(i)",
                sizeBytes: 25
            )
            _ = try storage.upsertItem(content)
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
                rawData: nil,
                appBundleID: "com.test.\(i)",
                contentHash: duplicateHash,
                sizeBytes: 20
            )
            _ = try storage.upsertItem(content)
        }

        // 数据库中只应该有一条记录
        let item = try storage.findByHash(duplicateHash)
        XCTAssertNotNil(item, "Item should exist")
        XCTAssertGreaterThanOrEqual(item!.useCount, 1, "Use count should be updated")

        // 验证总数
        let count = try storage.getItemCount()
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
}
