import XCTest
@testable import Scopy

/// 性能测试和基准测试
/// 验证 v0.md 第4节的性能目标
@MainActor
final class PerformanceTests: XCTestCase {

    var storage: StorageService!
    var search: SearchService!

    override func setUp() async throws {
        try await super.setUp()
        storage = StorageService(databasePath: ":memory:")
        try storage.open()
        search = SearchService(storage: storage)
        search.setDatabase(storage.database)
    }

    override func tearDown() async throws {
        storage.close()
        storage = nil
        search = nil
        try await super.tearDown()
    }

    // MARK: - Storage Performance

    /// 测试批量插入性能
    func testBulkInsertPerformance() async throws {
        let startTime = CFAbsoluteTimeGetCurrent()

        for i in 0..<1000 {
            let content = makeContent("Bulk insert test item \(i) with some content")
            _ = try storage.upsertItem(content)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let itemsPerSecond = 1000.0 / elapsed

        print("📊 Bulk Insert Performance:")
        print("   - 1000 items in \(String(format: "%.2f", elapsed * 1000))ms")
        print("   - \(String(format: "%.0f", itemsPerSecond)) items/second")

        // Should insert at least 500 items per second
        XCTAssertGreaterThan(itemsPerSecond, 500)
    }

    /// 测试读取性能
    func testFetchRecentPerformance() async throws {
        // Populate with data
        for i in 0..<5000 {
            _ = try storage.upsertItem(makeContent("Performance test item \(i)"))
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        for _ in 0..<100 {
            _ = try storage.fetchRecent(limit: 50, offset: 0)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let avgMs = (elapsed / 100) * 1000

        print("📊 Fetch Recent Performance:")
        print("   - 100 fetches (50 items each) in \(String(format: "%.2f", elapsed * 1000))ms")
        print("   - Average: \(String(format: "%.2f", avgMs))ms per fetch")

        // v0.md 4.1: P95 ≤ 50ms for ≤5k items
        XCTAssertLessThan(avgMs, 50)
    }

    // MARK: - Search Performance (v0.md 4.1)

    /// 测试小规模搜索性能（≤5k条）
    func testSearchPerformance5kItems() async throws {
        // Populate with 5000 items
        for i in 0..<5000 {
            let texts = [
                "Hello World item \(i)",
                "Search test content \(i)",
                "Random text data \(i)",
                "Performance benchmark \(i)",
                "Quick brown fox \(i)"
            ]
            _ = try storage.upsertItem(makeContent(texts[i % texts.count]))
        }
        search.invalidateCache()

        var times: [Double] = []

        // Run multiple searches
        for query in ["Hello", "test", "random", "fox", "data"] {
            let startTime = CFAbsoluteTimeGetCurrent()
            let request = SearchRequest(query: query, mode: .fuzzy, limit: 50, offset: 0)
            _ = try await search.search(request: request)
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            times.append(elapsed)
        }

        // Calculate P95
        times.sort()
        let p95Index = Int(Double(times.count) * 0.95)
        let p95 = times[min(p95Index, times.count - 1)]
        let avg = times.reduce(0, +) / Double(times.count)

        print("📊 Search Performance (5k items):")
        print("   - Average: \(String(format: "%.2f", avg))ms")
        print("   - P95: \(String(format: "%.2f", p95))ms")
        print("   - Min: \(String(format: "%.2f", times.first!))ms")
        print("   - Max: \(String(format: "%.2f", times.last!))ms")

        // v0.md 4.1: P95 ≤ 50ms for ≤5k items
        XCTAssertLessThan(p95, 50, "P95 search latency \(p95)ms exceeds 50ms target")
    }

    /// 测试中等规模搜索性能（10k条）
    func testSearchPerformance10kItems() async throws {
        // Populate with 10000 items
        for i in 0..<10000 {
            _ = try storage.upsertItem(makeContent("Search benchmark item \(i) with text"))
        }
        search.invalidateCache()

        var times: [Double] = []

        for query in ["search", "benchmark", "item", "text", "with"] {
            let startTime = CFAbsoluteTimeGetCurrent()
            let request = SearchRequest(query: query, mode: .fuzzy, limit: 50, offset: 0)
            _ = try await search.search(request: request)
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            times.append(elapsed)
        }

        times.sort()
        let p95Index = Int(Double(times.count) * 0.95)
        let p95 = times[min(p95Index, times.count - 1)]

        print("📊 Search Performance (10k items):")
        print("   - P95: \(String(format: "%.2f", p95))ms")

        // v0.md 4.1: P95 ≤ 100-150ms for 10k-100k items
        XCTAssertLessThan(p95, 150, "P95 search latency \(p95)ms exceeds 150ms target")
    }

    /// 测试短词搜索性能（缓存优化）
    func testShortQueryPerformance() async throws {
        // Populate
        for i in 0..<1000 {
            _ = try storage.upsertItem(makeContent("Test item \(i) a b c"))
        }
        search.invalidateCache()

        // First query populates cache
        let request1 = SearchRequest(query: "a", mode: .fuzzy, limit: 50, offset: 0)
        let result1 = try await search.search(request: request1)
        let time1 = result1.searchTimeMs

        // Second query should hit cache
        let request2 = SearchRequest(query: "b", mode: .fuzzy, limit: 50, offset: 0)
        let result2 = try await search.search(request: request2)
        let time2 = result2.searchTimeMs

        print("📊 Short Query Cache Performance:")
        print("   - First query: \(String(format: "%.2f", time1))ms")
        print("   - Cached query: \(String(format: "%.2f", time2))ms")

        // Cache should be faster
        XCTAssertLessThan(time2, time1 * 2, "Cache not providing performance benefit")
    }

    // MARK: - Search Mode Comparison

    /// 比较三种搜索模式的性能
    func testSearchModeComparison() async throws {
        // Populate
        for i in 0..<3000 {
            _ = try storage.upsertItem(makeContent("Mode comparison test item \(i)"))
        }
        search.invalidateCache()

        let query = "comparison"

        // Exact search
        let exactStart = CFAbsoluteTimeGetCurrent()
        let exactRequest = SearchRequest(query: query, mode: .exact, limit: 50, offset: 0)
        _ = try await search.search(request: exactRequest)
        let exactTime = (CFAbsoluteTimeGetCurrent() - exactStart) * 1000

        // Fuzzy search
        search.invalidateCache()
        let fuzzyStart = CFAbsoluteTimeGetCurrent()
        let fuzzyRequest = SearchRequest(query: query, mode: .fuzzy, limit: 50, offset: 0)
        _ = try await search.search(request: fuzzyRequest)
        let fuzzyTime = (CFAbsoluteTimeGetCurrent() - fuzzyStart) * 1000

        // Regex search
        search.invalidateCache()
        let regexStart = CFAbsoluteTimeGetCurrent()
        let regexRequest = SearchRequest(query: "comparison", mode: .regex, limit: 50, offset: 0)
        _ = try await search.search(request: regexRequest)
        let regexTime = (CFAbsoluteTimeGetCurrent() - regexStart) * 1000

        print("📊 Search Mode Comparison (3k items):")
        print("   - Exact: \(String(format: "%.2f", exactTime))ms")
        print("   - Fuzzy: \(String(format: "%.2f", fuzzyTime))ms")
        print("   - Regex: \(String(format: "%.2f", regexTime))ms")

        // All modes should be reasonably fast
        XCTAssertLessThan(exactTime, 100)
        XCTAssertLessThan(fuzzyTime, 100)
        XCTAssertLessThan(regexTime, 200) // Regex is allowed to be slower
    }

    // MARK: - Memory Performance

    /// 测试大量项目的内存效率
    func testMemoryEfficiency() async throws {
        let initialMemory = getMemoryUsage()

        // Insert 5000 items
        for i in 0..<5000 {
            _ = try storage.upsertItem(makeContent("Memory test item \(i) with some content data"))
        }

        let afterInsertMemory = getMemoryUsage()
        let memoryIncrease = afterInsertMemory - initialMemory

        print("📊 Memory Usage:")
        print("   - Initial: \(formatBytes(initialMemory))")
        print("   - After 5k inserts: \(formatBytes(afterInsertMemory))")
        print("   - Increase: \(formatBytes(memoryIncrease))")
        print("   - Per item: \(formatBytes(memoryIncrease / 5000))")

        // Should use reasonable memory (< 100KB per item average)
        XCTAssertLessThan(memoryIncrease / 5000, 100 * 1024)
    }

    // MARK: - Concurrent Access

    /// 测试并发读取性能
    func testConcurrentReadPerformance() async throws {
        // Populate
        for i in 0..<1000 {
            _ = try storage.upsertItem(makeContent("Concurrent test item \(i)"))
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        // Run sequential reads (simulating concurrent access pattern)
        // Note: MainActor isolation prevents true concurrent testing
        for _ in 0..<100 {
            _ = try? storage.fetchRecent(limit: 50, offset: 0)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        print("📊 Read Performance (100 operations):")
        print("   - 100 reads in \(String(format: "%.2f", elapsed * 1000))ms")
        print("   - \(String(format: "%.0f", 100 / elapsed)) reads/second")

        // Should handle reads efficiently
        XCTAssertLessThan(elapsed, 5.0) // 100 reads in under 5 seconds
    }

    // MARK: - Deduplication Performance

    /// 测试去重性能
    func testDeduplicationPerformance() async throws {
        // Insert 100 unique items, then repeat them
        var uniqueContents: [ClipboardMonitor.ClipboardContent] = []
        for i in 0..<100 {
            uniqueContents.append(makeContent("Unique item \(i)"))
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        // First pass - all unique
        for content in uniqueContents {
            _ = try storage.upsertItem(content)
        }

        // Second pass - all duplicates
        for content in uniqueContents {
            _ = try storage.upsertItem(content)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        print("📊 Deduplication Performance:")
        print("   - 200 upserts (100 unique, 100 dups) in \(String(format: "%.2f", elapsed * 1000))ms")

        // Should only have 100 items
        let count = try storage.getItemCount()
        XCTAssertEqual(count, 100)
    }

    // MARK: - Cleanup Performance

    /// 测试清理性能
    func testCleanupPerformance() async throws {
        // Insert many items
        for i in 0..<1000 {
            _ = try storage.upsertItem(makeContent("Cleanup test item \(i)"))
        }

        storage.cleanupSettings.maxItems = 100

        let startTime = CFAbsoluteTimeGetCurrent()
        try storage.performCleanup()
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        print("📊 Cleanup Performance:")
        print("   - Cleaned 900 items in \(String(format: "%.2f", elapsed * 1000))ms")

        let remaining = try storage.getItemCount()
        XCTAssertLessThanOrEqual(remaining, 100)
    }

    // MARK: - Helpers

    private func makeContent(_ text: String) -> ClipboardMonitor.ClipboardContent {
        ClipboardMonitor.ClipboardContent(
            type: .text,
            plainText: text,
            rawData: nil,
            appBundleID: "com.test.perf",
            contentHash: String(text.hashValue),
            sizeBytes: text.utf8.count
        )
    }

    private func getMemoryUsage() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    private func formatBytes(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        let mb = kb / 1024
        return String(format: "%.1f MB", mb)
    }
}
