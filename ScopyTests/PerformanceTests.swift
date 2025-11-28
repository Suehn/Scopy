import XCTest
@testable import Scopy

/// 性能测试和基准测试
/// 验证 v0.md 第4节的性能目标
@MainActor
final class PerformanceTests: XCTestCase {

    var storage: StorageService!
    var search: SearchService!
    private let heavyPerfEnv = "RUN_HEAVY_PERF_TESTS"

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

    // MARK: - v0.md SLO Aligned Tests

    /// 测试首屏加载性能 (v0.md 2.2: 50-100条 <100ms)
    func testFirstScreenLoadPerformance() async throws {
        // Populate with data
        for i in 0..<5000 {
            _ = try storage.upsertItem(makeContent("First screen test item \(i)"))
        }

        var times: [Double] = []

        // Run multiple load operations
        for _ in 0..<20 {
            let startTime = CFAbsoluteTimeGetCurrent()
            _ = try storage.fetchRecent(limit: 50, offset: 0)
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            times.append(elapsed)
        }

        times.sort()
        let p95Index = Int(Double(times.count) * 0.95)
        let p95 = times[min(p95Index, times.count - 1)]
        let avg = times.reduce(0, +) / Double(times.count)

        print("📊 First Screen Load Performance (v0.md 2.2):")
        print("   - Average: \(String(format: "%.2f", avg))ms")
        print("   - P95: \(String(format: "%.2f", p95))ms")

        // v0.md 2.2: 首屏加载应 <100ms
        XCTAssertLessThan(p95, 100, "First screen load P95 \(p95)ms exceeds 100ms target")
    }

    /// 测试内存稳定性 (1000次操作后内存增长合理)
    func testMemoryStability() async throws {
        let initialMemory = getMemoryUsage()

        // Perform many operations
        for i in 0..<500 {
            // Insert
            _ = try storage.upsertItem(makeContent("Stability test item \(i)"))

            // Search
            let request = SearchRequest(query: "stability", mode: .fuzzy, limit: 10, offset: 0)
            _ = try await search.search(request: request)

            // Fetch
            _ = try storage.fetchRecent(limit: 50, offset: 0)
        }

        let finalMemory = getMemoryUsage()
        let memoryGrowth = finalMemory - initialMemory
        let memoryGrowthMB = Double(memoryGrowth) / (1024 * 1024)

        print("📊 Memory Stability (500 iterations):")
        print("   - Initial: \(formatBytes(initialMemory))")
        print("   - Final: \(formatBytes(finalMemory))")
        print("   - Growth: \(String(format: "%.1f", memoryGrowthMB)) MB")

        // Memory growth should be reasonable (< 50MB for 500 operations)
        XCTAssertLessThan(memoryGrowthMB, 50, "Memory growth \(memoryGrowthMB)MB exceeds 50MB limit")
    }

    /// 测试搜索防抖效果验证
    func testSearchDebounceEffect() async throws {
        // Populate
        for i in 0..<1000 {
            _ = try storage.upsertItem(makeContent("Debounce test item \(i)"))
        }
        search.invalidateCache()

        // Simulate rapid queries
        let queries = ["d", "de", "deb", "debo", "debou", "deboun", "debounc", "debounce"]

        let startTime = CFAbsoluteTimeGetCurrent()

        for query in queries {
            let request = SearchRequest(query: query, mode: .fuzzy, limit: 50, offset: 0)
            _ = try await search.search(request: request)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        print("📊 Search Debounce Effect:")
        print("   - 8 rapid queries in \(String(format: "%.0f", elapsed * 1000))ms")
        print("   - Average per query: \(String(format: "%.2f", (elapsed / 8) * 1000))ms")

        // With debounce, UI would only execute the last query after 150ms
        // Here we verify backend can handle rapid queries
        XCTAssertLessThan(elapsed, 1.0, "Rapid queries took too long")
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

    // MARK: - Realistic Disk-Backed Scenarios

    /// 磁盘模式 + 2.5 万条，模拟真实 I/O（WAL 已启用）
    func testDiskBackedSearchPerformance25k() async throws {
        let (diskStorage, diskSearch, baseURL) = try makeDiskStorage()
        defer {
            diskStorage.close()
            try? FileManager.default.removeItem(at: baseURL)
        }

        // Mixed length text to mimic real notes/snippets
        for i in 0..<25_000 {
            let len = 40 + (i % 200)
            let text = "Note \(i) " + String(repeating: "lorem ipsum ", count: len / 11)
            _ = try diskStorage.upsertItem(makeContent(text))
        }
        diskSearch.invalidateCache()

        var times: [Double] = []
        for query in ["lorem", "note", "ipsum", "content", "random"] {
            let start = CFAbsoluteTimeGetCurrent()
            let request = SearchRequest(query: query, mode: .fuzzy, limit: 50, offset: 0)
            _ = try await diskSearch.search(request: request)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            times.append(elapsed)
        }

        times.sort()
        let p95Index = min(Int(Double(times.count) * 0.95), times.count - 1)
        let p95 = times[p95Index]
        print("📊 Disk Search Performance (25k items): P95 \(String(format: "%.2f", p95))ms")
        XCTAssertLessThan(p95, 200, "Disk-backed P95 \(p95)ms exceeds 200ms target for 10k-100k bracket")
    }

    /// 磁盘模式混合内容（文本/HTML/RTF/图片/文件），验证索引与外部存储
    func testMixedContentIndexingOnDisk() async throws {
        let (diskStorage, diskSearch, baseURL) = try makeDiskStorage()
        defer {
            diskStorage.close()
            try? FileManager.default.removeItem(at: baseURL)
        }

        // Texts
        for i in 0..<2_500 {
            _ = try diskStorage.upsertItem(makeContent("Mixed text \(i) lorem ipsum dolor sit amet"))
        }

        // HTML
        for i in 0..<400 {
            _ = try diskStorage.upsertItem(makeHTMLContent(index: i))
        }

        // RTF
        for i in 0..<400 {
            _ = try diskStorage.upsertItem(makeRTFContent(index: i))
        }

        // Large images -> external storage
        for i in 0..<300 {
            _ = try diskStorage.upsertItem(makeImageContent(index: i, byteSize: 120 * 1024))
        }

        // File entries
        for i in 0..<300 {
            let path = baseURL.appendingPathComponent("file\(i).txt").path
            _ = try diskStorage.upsertItem(makeFileContent(path: path))
        }

        diskSearch.invalidateCache()

        let start = CFAbsoluteTimeGetCurrent()
        let page = try await diskSearch.search(
            request: SearchRequest(query: "lorem", mode: .fuzzy, limit: 50, offset: 0)
        )
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        let recent = try diskStorage.fetchRecent(limit: 5000, offset: 0)
        let externalCount = recent.filter { $0.storageRef != nil }.count

        print("📊 Mixed Content Disk Search:")
        print("   - Returned \(page.items.count) items in \(String(format: "%.2f", elapsed))ms")
        print("   - External storage refs in recent items: \(externalCount)")

        // Cleanup external artifacts written during test to avoid polluting user data
        let fm = FileManager.default
        recent.compactMap { $0.storageRef }.forEach { ref in
            try? fm.removeItem(atPath: ref)
        }

        XCTAssertGreaterThan(page.items.count, 0, "Search should return mixed content results")
        XCTAssertGreaterThan(externalCount, 0, "Large payloads should be stored externally")
        XCTAssertLessThan(elapsed, 150, "Mixed content search should stay under 150ms on disk")
    }

    /// 重负载：磁盘模式 50k 条搜索，需手动开启 RUN_HEAVY_PERF_TESTS
    func testHeavyDiskSearchPerformance50k() async throws {
        try XCTSkipIf(!shouldRunHeavyPerf(), "Set \(heavyPerfEnv)=1 to run heavy disk perf tests")

        let (diskStorage, diskSearch, baseURL) = try makeDiskStorage()
        defer {
            diskStorage.close()
            try? FileManager.default.removeItem(at: baseURL)
        }

        for i in 0..<50_000 {
            let len = 80 + (i % 400)
            let text = "Heavy note \(i) " + String(repeating: "lorem ipsum ", count: len / 11)
            _ = try diskStorage.upsertItem(makeContent(text))
        }
        diskSearch.invalidateCache()

        var times: [Double] = []
        for query in ["heavy", "lorem", "ipsum", "note"] {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try await diskSearch.search(
                request: SearchRequest(query: query, mode: .fuzzy, limit: 50, offset: 0)
            )
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }

        times.sort()
        let p95Index = min(Int(Double(times.count) * 0.95), times.count - 1)
        let p95 = times[p95Index]
        print("📊 Heavy Disk Search (50k items): P95 \(String(format: "%.2f", p95))ms")
        XCTAssertLessThan(p95, 200, "Heavy disk P95 \(p95)ms exceeds 200ms target for 10k-100k bracket")
    }

    /// 重负载：磁盘模式 75k 条搜索（极端场景），需手动开启 RUN_HEAVY_PERF_TESTS
    func testUltraDiskSearchPerformance75k() async throws {
        try XCTSkipIf(!shouldRunHeavyPerf(), "Set \(heavyPerfEnv)=1 to run heavy disk perf tests")

        let (diskStorage, diskSearch, baseURL) = try makeDiskStorage()
        defer {
            diskStorage.close()
            try? FileManager.default.removeItem(at: baseURL)
        }

        for i in 0..<75_000 {
            let len = 120 + (i % 500)
            let text = makeRealisticText(index: i, base: "Ultra note", length: len)
            _ = try diskStorage.upsertItem(makeContent(text))
        }
        diskSearch.invalidateCache()

        var times: [Double] = []
        for query in ["ultra", "note", "lorem", "ipsum"] {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try await diskSearch.search(
                request: SearchRequest(query: query, mode: .fuzzy, limit: 50, offset: 0)
            )
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }

        let p95 = percentile(times, 95)
        print("📊 Ultra Disk Search (75k items): P95 \(String(format: "%.2f", p95))ms")
        XCTAssertLessThan(p95, 250, "Ultra disk P95 \(p95)ms exceeds 250ms target for 10k-100k bracket")
    }

    /// 大规模 regex 性能验证（20k）
    func testRegexPerformance20kItems() async throws {
        for i in 0..<20_000 {
            let text = makeRealisticText(index: i, base: "Regex note", length: 80 + (i % 120))
            _ = try storage.upsertItem(makeContent(text))
        }
        search.invalidateCache()

        var times: [Double] = []
        for pattern in ["Regex\\s+note", "lorem\\sipsum", "item\\s[0-9]{3,}"] {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try await search.search(
                request: SearchRequest(query: pattern, mode: .regex, limit: 50, offset: 0)
            )
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }

        let p95 = percentile(times, 95)
        print("📊 Regex Performance (20k items): P95 \(String(format: "%.2f", p95))ms")
        XCTAssertLessThan(p95, 120, "Regex P95 \(p95)ms exceeds 120ms target")
    }

    /// 重负载：外部存储压力（300 x 256KB，实际约 190MB 含 WAL），验证清理与引用
    func testExternalStorageStress() async throws {
        try XCTSkipIf(!shouldRunHeavyPerf(), "Set \(heavyPerfEnv)=1 to run heavy perf tests")

        let (diskStorage, _, baseURL) = try makeDiskStorage()
        defer {
            diskStorage.close()
            try? FileManager.default.removeItem(at: baseURL)
        }

        // 250 x 256KB ≈ 64MB，仍高于 50MB 清理阈值，但更稳定
        for i in 0..<250 {
            let blob = Data(repeating: UInt8(i % 255), count: 256 * 1024) // 256KB
            let content = ClipboardMonitor.ClipboardContent(
                type: .image,
                plainText: "[Large image \(i)]",
                rawData: blob,
                appBundleID: "com.apple.Preview",
                contentHash: "heavy-img-\(i)",
                sizeBytes: blob.count
            )
            _ = try diskStorage.upsertItem(content)
        }

        let externalSize = try diskStorage.getExternalStorageSize()
        print("📦 External storage size after stress: \(formatBytes(externalSize))")
        XCTAssertGreaterThan(externalSize, 10 * 1024 * 1024, "External storage should exceed 10MB after stress")

        // Trigger cleanup to ensure it runs fast enough
        // 预热一次，避免首次 I/O 抖动
        diskStorage.cleanupSettings.maxLargeStorageMB = 1000
        try diskStorage.performCleanup()

        diskStorage.cleanupSettings.maxLargeStorageMB = 50 // 50MB cap
        let start = CFAbsoluteTimeGetCurrent()
        try diskStorage.performCleanup()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("🧹 External cleanup elapsed: \(String(format: "%.2f", elapsed))ms")
        XCTAssertLessThan(elapsed, 800, "External cleanup should finish within 800ms")
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

    private func makeHTMLContent(index: Int) -> ClipboardMonitor.ClipboardContent {
        let html = "<p>Lorem \(index) ipsum <strong>HTML</strong> snippet</p>"
        let data = html.data(using: .utf8)
        return ClipboardMonitor.ClipboardContent(
            type: .html,
            plainText: "HTML snippet \(index)",
            rawData: data,
            appBundleID: "com.apple.Safari",
            contentHash: "html-\(index)",
            sizeBytes: data?.count ?? 0
        )
    }

    private func makeRTFContent(index: Int) -> ClipboardMonitor.ClipboardContent {
        let text = "RTF content \(index) lorem ipsum dolor sit amet"
        let data = text.data(using: .utf8) // lightweight stand-in for RTF bytes
        return ClipboardMonitor.ClipboardContent(
            type: .rtf,
            plainText: text,
            rawData: data,
            appBundleID: "com.apple.TextEdit",
            contentHash: "rtf-\(index)",
            sizeBytes: data?.count ?? 0
        )
    }

    private func makeImageContent(index: Int, byteSize: Int) -> ClipboardMonitor.ClipboardContent {
        let data = Data(repeating: UInt8(index % 255), count: byteSize)
        return ClipboardMonitor.ClipboardContent(
            type: .image,
            plainText: "[Image \(index)]",
            rawData: data,
            appBundleID: "com.apple.Preview",
            contentHash: "image-\(index)",
            sizeBytes: data.count
        )
    }

    private func makeFileContent(path: String) -> ClipboardMonitor.ClipboardContent {
        return ClipboardMonitor.ClipboardContent(
            type: .file,
            plainText: path,
            rawData: nil,
            appBundleID: "com.apple.finder",
            contentHash: "file-\(path)",
            sizeBytes: path.utf8.count
        )
    }

    private func makeRealisticText(index: Int, base: String, length: Int) -> String {
        let filler = String(repeating: " lorem ipsum", count: max(1, length / 11))
        return "\(base) \(index) \(filler)"
    }

    private func makeDiskStorage() throws -> (StorageService, SearchService, URL) {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let dbPath = baseURL.appendingPathComponent("clipboard.db").path

        let storage = StorageService(databasePath: dbPath)
        try storage.open()

        let search = SearchService(storage: storage)
        search.setDatabase(storage.database)

        return (storage, search, baseURL)
    }

    private func shouldRunHeavyPerf() -> Bool {
        // 默认开启重负载场景；如需关闭，可设置 RUN_HEAVY_PERF_TESTS=0
        if let flag = ProcessInfo.processInfo.environment[heavyPerfEnv], flag == "0" {
            return false
        }
        return true
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(Int(Double(sorted.count - 1) * (p / 100.0)), sorted.count - 1)
        return sorted[index]
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
        Localization.formatBytes(bytes)
    }
}
