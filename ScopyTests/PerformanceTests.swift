import AppKit
import XCTest
import ScopyKit

/// 性能测试和基准测试
/// 验证 v0.md 第4节的性能目标
@MainActor
final class PerformanceTests: XCTestCase {

    var storage: StorageService!
    var search: SearchEngineImpl!

    override func setUp() async throws {
        try XCTSkipIf(!shouldRunPerf(), "Run: make test-perf")
        storage = StorageService(databasePath: Self.makeSharedInMemoryDatabasePath())
        try await storage.open()
        search = SearchEngineImpl(dbPath: storage.databaseFilePath)
        try await search.open()
    }

    override func tearDown() async throws {
        if let search {
            await search.close()
        }
        if let storage {
            await storage.close()
        }
        storage = nil
        search = nil
    }

    // MARK: - Storage Performance

    /// 测试批量插入性能
    func testBulkInsertPerformance() async throws {
        let startTime = CFAbsoluteTimeGetCurrent()

        for i in 0..<1000 {
            let content = makeContent("Bulk insert test item \(i) with some content")
            _ = try await storage.upsertItem(content)
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
            _ = try await storage.upsertItem(makeContent("Performance test item \(i)"))
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        for _ in 0..<100 {
            _ = try await storage.fetchRecent(limit: 50, offset: 0)
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
            _ = try await storage.upsertItem(makeContent(texts[i % texts.count]))
        }
        await search.invalidateCache()

        // Default mode is fuzzyPlus (SettingsDTO.defaultSearchMode).
        // Measure cold (index build) separately from steady-state latency.
        let coldStart = CFAbsoluteTimeGetCurrent()
        _ = try await search.search(
            request: SearchRequest(query: "hello world", mode: .fuzzyPlus, limit: 1, offset: 0)
        )
        let coldMs = (CFAbsoluteTimeGetCurrent() - coldStart) * 1000
        print("📊 Search Cold Start (5k items, fuzzyPlus): \(String(format: "%.2f", coldMs))ms")
        XCTAssertLessThan(coldMs, 1500, "Cold index build took too long: \(coldMs)ms")

        var times: [Double] = []

        // Run multiple searches
        for query in ["Hello", "search test", "random data", "brown fox", "benchmark"] {
            let startTime = CFAbsoluteTimeGetCurrent()
            let request = SearchRequest(query: query, mode: .fuzzyPlus, limit: 50, offset: 0)
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
            _ = try await storage.upsertItem(makeContent("Search benchmark item \(i) with text"))
        }
        await search.invalidateCache()

        // Default mode is fuzzyPlus (SettingsDTO.defaultSearchMode).
        // Measure cold (index build) separately from steady-state latency.
        let coldStart = CFAbsoluteTimeGetCurrent()
        _ = try await search.search(
            request: SearchRequest(query: "search benchmark", mode: .fuzzyPlus, limit: 1, offset: 0)
        )
        let coldMs = (CFAbsoluteTimeGetCurrent() - coldStart) * 1000
        print("📊 Search Cold Start (10k items, fuzzyPlus): \(String(format: "%.2f", coldMs))ms")
        XCTAssertLessThan(coldMs, 3000, "Cold index build took too long: \(coldMs)ms")

        var times: [Double] = []
        let queries = ["search", "benchmark", "benchmark item", "with text", "search benchmark"]
        let sampleRounds = 10

        // More samples => less flaky P95 under transient system load.
        for _ in 0..<sampleRounds {
            for query in queries {
                let startTime = CFAbsoluteTimeGetCurrent()
                let request = SearchRequest(query: query, mode: .fuzzyPlus, limit: 50, offset: 0)
                _ = try await search.search(request: request)
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                times.append(elapsed)
            }
        }

        times.sort()
        let p95Index = Int(Double(times.count) * 0.95)
        let p95 = times[min(p95Index, times.count - 1)]

        print("📊 Search Performance (10k items):")
        print("   - Samples: \(times.count)")
        print("   - P95: \(String(format: "%.2f", p95))ms")

        // v0.md 4.1: P95 ≤ 100-150ms for 10k-100k items (Normal power mode).
        // Low Power Mode will throttle CPU; keep the test meaningful with a relaxed bound.
        let isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let maxP95 = isLowPowerMode ? 300.0 : 150.0
        if isLowPowerMode {
            print("   - Low Power Mode enabled: relaxed target to \(String(format: "%.0f", maxP95))ms")
        }
        XCTAssertLessThan(p95, maxP95, "P95 search latency \(p95)ms exceeds \(maxP95)ms target")
    }

    /// 混合文本（含 Emoji / CJK 等非 ASCII）场景：验证 fuzzy（非 fuzzyPlus）在 ~6k 条时仍可用。
    ///
    /// 说明：
    /// - 真实使用中，clipboard 内容常混入 emoji/CJK，导致 `textLowerIsASCII == false`。
    /// - 对 ASCII query（如 url/token/命令）应尽量命中 substring fast-path，避免退化到逐字符 fuzzy 扫描造成延迟飙升。
    func testFuzzySearchPerformanceMixedUnicode6kItems() async throws {
        try XCTSkipIf(!shouldRunHeavyPerf(), "Run: make test-perf-heavy")

        let itemCount = 6000
        let fillerUnit = "abcdefghijklmnopqrstuvwxyz0123456789 "
        let filler = String(repeating: fillerUnit, count: 25) // ~925 chars
        for i in 0..<itemCount {
            let text = "Item \(i) 😀 \(filler) keyword \(i)"
            _ = try await storage.upsertItem(makeContent(text))
        }
        await search.invalidateCache()

        // Warmup: build index once.
        let cold = try await search.search(
            request: SearchRequest(query: "keyword", mode: .fuzzy, limit: 1, offset: 0)
        )
        print("📊 Fuzzy Cold Start (6k mixed unicode, fuzzy): \(String(format: "%.2f", cold.searchTimeMs))ms")
        XCTAssertGreaterThan(cold.items.count, 0)

        var times: [Double] = []
        let sampleRounds = 20
        for _ in 0..<sampleRounds {
            let result = try await search.search(
                request: SearchRequest(query: "keyword", mode: .fuzzy, limit: 50, offset: 0)
            )
            XCTAssertEqual(result.items.count, 50)
            times.append(result.searchTimeMs)
        }

        let p95 = percentile(times, 95)
        let avg = times.reduce(0, +) / Double(times.count)
        print("📊 Fuzzy Performance (6k mixed unicode, fuzzy):")
        print("   - Samples: \(times.count)")
        print("   - Average: \(String(format: "%.2f", avg))ms")
        print("   - P95: \(String(format: "%.2f", p95))ms")

        let isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let maxP95 = isLowPowerMode ? 600.0 : 200.0
        if isLowPowerMode {
            print("   - Low Power Mode enabled: relaxed target to \(String(format: "%.0f", maxP95))ms")
        }
        XCTAssertLessThan(p95, maxP95, "Mixed unicode fuzzy P95 \(p95)ms exceeds \(maxP95)ms target")
    }

    /// 长文场景：验证 FTS exact 查询在长文本下仍保持可用延迟。
    ///
    /// 说明：
    /// - 覆盖“单条文本很长”的压力，与 10k/25k 的“条目数量压力”互补。
    /// - 控制规模，使其可在常规 test-run 中执行，避免依赖 scheme/env 传参。
    func testExactSearchPerformanceLongDocuments() async throws {
        let docCount = 40
        let block = "Here, we describe the formalism of the time-dependent spin wave theory. "
        let body = String(repeating: block, count: 220) // ~16k chars

        for i in 0..<docCount {
            let token = "WASSERSTEIN_TOKEN_\(i)"
            let text = "LongDoc \(i)\n" + body + "\nTail \(token)\n"
            _ = try await storage.upsertItem(makeContent(text))
        }
        await search.invalidateCache()

        // Warmup: first exact search may pay some sqlite page-cache misses.
        let lastIndex = docCount - 1
        _ = try await search.search(request: SearchRequest(query: "Tail WASSERSTEIN_TOKEN_\(lastIndex)", mode: .exact, limit: 10, offset: 0))

        var times: [Double] = []
        let queries = [
            "WASSERSTEIN_TOKEN_\(lastIndex)",
            "LongDoc 12",
            "spin wave theory",
            "Tail WASSERSTEIN_TOKEN_3"
        ]

        for _ in 0..<5 {
            for q in queries {
                let start = CFAbsoluteTimeGetCurrent()
                let result = try await search.search(request: SearchRequest(query: q, mode: .exact, limit: 50, offset: 0))
                XCTAssertGreaterThan(result.items.count, 0, "Query should return some results: \(q)")
                times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
        }

        let p95 = percentile(times, 95)
        let avg = times.reduce(0, +) / Double(times.count)
        print("📊 Exact Search Long Documents (\(docCount) docs, ~\(body.utf16.count) chars):")
        print("   - Samples: \(times.count)")
        print("   - Average: \(String(format: "%.2f", avg))ms")
        print("   - P95: \(String(format: "%.2f", p95))ms")

        let isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let maxP95 = isLowPowerMode ? 450.0 : 250.0
        XCTAssertLessThan(p95, maxP95, "Long-doc exact P95 \(p95)ms exceeds \(maxP95)ms")
    }

    /// 测试短词搜索性能（缓存优化）
    func testShortQueryPerformance() async throws {
        // Populate
        for i in 0..<1000 {
            _ = try await storage.upsertItem(makeContent("Test item \(i) a b c"))
        }
        await search.invalidateCache()

        // First query populates cache
        let request1 = SearchRequest(query: "a", mode: .fuzzyPlus, limit: 50, offset: 0)
        let result1 = try await search.search(request: request1)
        let time1 = result1.searchTimeMs

        // Second query should hit cache
        let request2 = SearchRequest(query: "b", mode: .fuzzyPlus, limit: 50, offset: 0)
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
        for i in 0..<1000 {
            _ = try await storage.upsertItem(makeContent("Mode comparison test item \(i)"))
        }
        await search.invalidateCache()

        let query = "comparison"

        // Exact search
        let exactStart = CFAbsoluteTimeGetCurrent()
        let exactRequest = SearchRequest(query: query, mode: .exact, limit: 50, offset: 0)
        _ = try await search.search(request: exactRequest)
        let exactTime = (CFAbsoluteTimeGetCurrent() - exactStart) * 1000

        // Fuzzy search
        await search.invalidateCache()
        let fuzzyStart = CFAbsoluteTimeGetCurrent()
        let fuzzyRequest = SearchRequest(query: query, mode: .fuzzy, limit: 50, offset: 0)
        _ = try await search.search(request: fuzzyRequest)
        let fuzzyTime = (CFAbsoluteTimeGetCurrent() - fuzzyStart) * 1000

        // Regex search
        await search.invalidateCache()
        let regexStart = CFAbsoluteTimeGetCurrent()
        let regexRequest = SearchRequest(query: "comparison", mode: .regex, limit: 50, offset: 0)
        _ = try await search.search(request: regexRequest)
        let regexTime = (CFAbsoluteTimeGetCurrent() - regexStart) * 1000

        print("📊 Search Mode Comparison (1k items):")
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
            _ = try await storage.upsertItem(makeContent("Memory test item \(i) with some content data"))
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
            _ = try await storage.upsertItem(makeContent("Concurrent test item \(i)"))
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        // Run sequential reads (simulating concurrent access pattern)
        // Note: MainActor isolation prevents true concurrent testing
        for _ in 0..<100 {
            _ = try? await storage.fetchRecent(limit: 50, offset: 0)
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
            _ = try await storage.upsertItem(content)
        }

        // Second pass - all duplicates
        for content in uniqueContents {
            _ = try await storage.upsertItem(content)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        print("📊 Deduplication Performance:")
        print("   - 200 upserts (100 unique, 100 dups) in \(String(format: "%.2f", elapsed * 1000))ms")

        // Should only have 100 items
        let count = try await storage.getItemCount()
        XCTAssertEqual(count, 100)
    }

    // MARK: - v0.md SLO Aligned Tests

    /// 测试首屏加载性能 (v0.md 2.2: 50-100条 <100ms)
    func testFirstScreenLoadPerformance() async throws {
        // Populate with data
        for i in 0..<5000 {
            _ = try await storage.upsertItem(makeContent("First screen test item \(i)"))
        }

        var times: [Double] = []

        // Run multiple load operations
        for _ in 0..<20 {
            let startTime = CFAbsoluteTimeGetCurrent()
            _ = try await storage.fetchRecent(limit: 50, offset: 0)
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
            _ = try await storage.upsertItem(makeContent("Stability test item \(i)"))

            // Search
            let request = SearchRequest(query: "stability", mode: .fuzzyPlus, limit: 10, offset: 0)
            _ = try await search.search(request: request)

            // Fetch
            _ = try await storage.fetchRecent(limit: 50, offset: 0)
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
            _ = try await storage.upsertItem(makeContent("Debounce test item \(i)"))
        }
        await search.invalidateCache()

        // Simulate rapid queries
        let queries = ["d", "de", "deb", "debo", "debou", "deboun", "debounc", "debounce"]

        let startTime = CFAbsoluteTimeGetCurrent()

        for query in queries {
            let request = SearchRequest(query: query, mode: .fuzzyPlus, limit: 50, offset: 0)
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
            _ = try await storage.upsertItem(makeContent("Cleanup test item \(i)"))
        }

        storage.cleanupSettings.maxItems = 100

        let startTime = CFAbsoluteTimeGetCurrent()
        try await storage.performCleanup()
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        print("📊 Cleanup Performance:")
        print("   - Cleaned 900 items in \(String(format: "%.2f", elapsed * 1000))ms")

        let remaining = try await storage.getItemCount()
        XCTAssertLessThanOrEqual(remaining, 100)
    }

    // MARK: - v0.11 Cleanup Performance Benchmarks

    /// v0.14: 内联存储清理性能测试 (10k 项，纯 SQLite)
    /// 目标: P95 < 500ms（调整目标以反映真实场景：每次循环重新插入数据导致 WAL 膨胀）
    /// 真实场景：单次清理 9000 条约 200-300ms，但测试循环累积 WAL 开销
    func testInlineCleanupPerformance10k() async throws {
        try XCTSkipIf(!shouldRunHeavyPerf(), "Run: make test-perf-heavy")

        try await withDiskStorage { diskStorage, _, _ in
            // 插入 10k 小内容项（内联存储）
            for i in 0..<10_000 {
                let text = "Inline cleanup test item \(i) with some text content"
                _ = try await diskStorage.upsertItem(makeContent(text))
            }

            diskStorage.cleanupSettings.maxItems = 1000

            var times: [Double] = []
            for iteration in 0..<5 {
                // 重新插入数据
                for i in 0..<9000 {
                    _ = try await diskStorage.upsertItem(makeContent("Refill item \(i) \(UUID().uuidString)"))
                }

                // v0.14: 在每次清理前执行 WAL checkpoint，模拟真实场景
                await diskStorage.performWALCheckpoint()

                let start = CFAbsoluteTimeGetCurrent()
                try await diskStorage.performCleanup()
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                times.append(elapsed)
                print("   - Iteration \(iteration + 1): \(String(format: "%.2f", elapsed))ms")
            }

            let p95 = percentile(times, 95)
            print("📊 Inline Cleanup Performance (10k items): P95 \(String(format: "%.2f", p95))ms")
            // v0.14: 调整目标为 500ms，反映测试循环的累积开销
            XCTAssertLessThan(p95, 500, "Inline cleanup P95 \(p95)ms exceeds 500ms target")
        }
    }

    /// v0.14: 外部存储清理性能测试 (10k 项，含文件 I/O)
    /// 目标: P95 < 1800ms（当前基线：10k 大文件写入 + 9k 文件删除 + 数据库清理）
    /// 真实场景：外部存储清理涉及大量文件 I/O，性能受磁盘速度影响
    func testExternalCleanupPerformance10k() async throws {
        try XCTSkipIf(!shouldRunHeavyPerf(), "Run: make test-perf-heavy")

        try await withDiskStorage { diskStorage, _, _ in
            // 插入 10k 大内容项（外部存储）
            for i in 0..<10_000 {
                let blob = Data(repeating: UInt8(i % 255), count: 120 * 1024) // 120KB
                let content = ClipboardMonitor.ClipboardContent(
                    type: .image,
                    plainText: "[External cleanup test \(i)]",
                    payload: .data(blob),
                    appBundleID: "com.test.cleanup",
                    contentHash: "ext-cleanup-\(i)-\(UUID().uuidString)",
                    sizeBytes: blob.count
                )
                _ = try await diskStorage.upsertItem(content)
            }

            diskStorage.cleanupSettings.maxItems = 1000
            diskStorage.cleanupSettings.maxLargeStorageMB = 100 // 100MB

            // v0.14: WAL checkpoint 确保数据落盘
            await diskStorage.performWALCheckpoint()

            let start = CFAbsoluteTimeGetCurrent()
            try await diskStorage.performCleanup()
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

            print("📊 External Cleanup Performance (10k items): \(String(format: "%.2f", elapsed))ms")
            let targetMs = ProcessInfo.processInfo.environment["SCOPY_EXTERNAL_CLEANUP_TARGET_MS"]
                .flatMap(Double.init) ?? 1800
            XCTAssertLessThan(elapsed, targetMs, "External cleanup \(elapsed)ms exceeds \(targetMs)ms target")
        }
    }

    /// v0.14: 大规模清理性能测试 (50k 项)
    /// 目标: P95 < 2000ms（调整目标：50k 插入后 WAL 膨胀 + 45k 删除 + FTS5 同步）
    func testCleanupPerformance50k() async throws {
        try XCTSkipIf(!shouldRunHeavyPerf(), "Run: make test-perf-heavy")

        try await withDiskStorage { diskStorage, _, _ in
            // 插入 50k 项
            for i in 0..<50_000 {
                let text = "Large scale cleanup test item \(i) with content"
                _ = try await diskStorage.upsertItem(makeContent(text))
            }

            diskStorage.cleanupSettings.maxItems = 5000

            // v0.14: WAL checkpoint 确保数据落盘
            await diskStorage.performWALCheckpoint()

            let start = CFAbsoluteTimeGetCurrent()
            try await diskStorage.performCleanup()
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

            print("📊 Large Scale Cleanup Performance (50k items): \(String(format: "%.2f", elapsed))ms")
            // v0.14: 调整目标为 2000ms，反映 45k 删除 + FTS5 同步开销
            XCTAssertLessThan(elapsed, 2000, "50k cleanup \(elapsed)ms exceeds 2000ms target")

            let remaining = try await diskStorage.getItemCount()
            XCTAssertLessThanOrEqual(remaining, 5000)
        }
    }

    // MARK: - Realistic Disk-Backed Scenarios

    /// 端到端：走 ClipboardService 搜索路径（含 DTO 转换/actor hop），更接近 UI 体验。
    func testServiceSearchPerformanceDisk10k() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-service-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path

        let storage = StorageService(databasePath: dbPath)
        try await storage.open()
        for i in 0..<10_000 {
            let len = 50 + (i % 200)
            let text = makeRealisticText(index: i, base: "Service note", length: len)
            _ = try await storage.upsertItem(makeContent(text))
        }
        await storage.performWALCheckpoint()
        await storage.close()

        let suiteName = "scopy-service-perf-settings-\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        let settingsStore = SettingsStore(suiteName: suiteName)

        let pasteboard = NSPasteboard.withUniqueName()
        let service = ClipboardServiceFactory.create(
            useMock: false,
            databasePath: dbPath,
            settingsStore: settingsStore,
            monitorPasteboardName: pasteboard.name.rawValue,
            monitorPollingInterval: 5.0
        )

        func cleanup() async {
            await service.stopAndWait()
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseURL)
        }

        do {
            try await service.start()

            // Cold search includes full index build.
            let coldStart = CFAbsoluteTimeGetCurrent()
            _ = try await service.search(query: SearchRequest(query: "service note", mode: .fuzzyPlus, limit: 50, offset: 0))
            let coldMs = (CFAbsoluteTimeGetCurrent() - coldStart) * 1000
            print("📊 Service Search Cold Start (10k items, fuzzyPlus): \(String(format: "%.2f", coldMs))ms")
            XCTAssertLessThan(coldMs, 8000, "Service cold search took too long: \(coldMs)ms")

            var times: [Double] = []
            let queries = ["service", "service note", "lorem", "note 9999", "ipsum"]
            let sampleRounds = 10
            for _ in 0..<sampleRounds {
                for query in queries {
                    let start = CFAbsoluteTimeGetCurrent()
                    _ = try await service.search(query: SearchRequest(query: query, mode: .fuzzyPlus, limit: 50, offset: 0))
                    times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                }
            }

            let p95 = percentile(times, 95)
            let avg = times.reduce(0, +) / Double(times.count)

            print("📊 Service Search Performance (10k items, fuzzyPlus):")
            print("   - Samples: \(times.count)")
            print("   - Average: \(String(format: "%.2f", avg))ms")
            print("   - P95: \(String(format: "%.2f", p95))ms")

            PerformanceAssertions.assertSearchLatency(p95, itemCount: 10_000)

            let isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            let maxP95 = isLowPowerMode ? 500.0 : 250.0
            XCTAssertLessThan(p95, maxP95, "Service P95 \(p95)ms exceeds \(maxP95)ms target")
        } catch {
            await cleanup()
            throw error
        }

        await cleanup()
    }

    /// 磁盘模式 + 2.5 万条，模拟真实 I/O（WAL 已启用）
    func testDiskBackedSearchPerformance25k() async throws {
        try await withDiskStorage { diskStorage, diskSearch, _ in
            // Mixed length text to mimic real notes/snippets
            for i in 0..<25_000 {
                let len = 40 + (i % 200)
                let localePrefix: String
                switch i % 12 {
                case 0: localePrefix = "你好世界"
                case 1: localePrefix = "こんにちは世界"
                case 2: localePrefix = "안녕하세요세계"
                case 3: localePrefix = "🚀Launch"
                default: localePrefix = "Note"
                }

                let path = "/Users/test/Documents/file\(i).txt"
                let text = "\(localePrefix) \(i) " + String(repeating: "lorem ipsum ", count: len / 11) + " \(path)"
                _ = try await diskStorage.upsertItem(makeContent(text))
            }
            await diskSearch.invalidateCache()

            // Default mode is fuzzyPlus; measure cold build separately.
            let coldStart = CFAbsoluteTimeGetCurrent()
            _ = try await diskSearch.search(
                request: SearchRequest(query: "lorem ipsum", mode: .fuzzyPlus, limit: 1, offset: 0)
            )
            let coldMs = (CFAbsoluteTimeGetCurrent() - coldStart) * 1000
            print("📊 Disk Search Cold Start (25k items, fuzzyPlus): \(String(format: "%.2f", coldMs))ms")
            XCTAssertLessThan(coldMs, 5000, "Disk cold index build took too long: \(coldMs)ms")

            var times: [Double] = []
            let queries = ["lorem", "lorem ipsum", "note", "你好世界", "documents", "file123"]
            let sampleRounds = 10

            // More samples => less flaky P95 under transient system load.
            for _ in 0..<sampleRounds {
                for query in queries {
                    let start = CFAbsoluteTimeGetCurrent()
                    let request = SearchRequest(query: query, mode: .fuzzyPlus, limit: 50, offset: 0)
                    _ = try await diskSearch.search(request: request)
                    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    times.append(elapsed)
                }
            }

            times.sort()
            let p95Index = min(Int(Double(times.count) * 0.95), times.count - 1)
            let p95 = times[p95Index]
            print("📊 Disk Search Performance (25k items): P95 \(String(format: "%.2f", p95))ms")
            print("   - Samples: \(times.count)")
            XCTAssertLessThan(p95, 200, "Disk-backed P95 \(p95)ms exceeds 200ms target for 10k-100k bracket")
        }
    }

    /// 磁盘模式混合内容（文本/HTML/RTF/图片/文件），验证索引与外部存储
    func testMixedContentIndexingOnDisk() async throws {
        try await withDiskStorage { diskStorage, diskSearch, baseURL in
            // Texts
            for i in 0..<2_500 {
                _ = try await diskStorage.upsertItem(makeContent("Mixed text \(i) lorem ipsum dolor sit amet"))
            }

            // HTML
            for i in 0..<400 {
                _ = try await diskStorage.upsertItem(makeHTMLContent(index: i))
            }

            // RTF
            for i in 0..<400 {
                _ = try await diskStorage.upsertItem(makeRTFContent(index: i))
            }

            // Large images -> external storage
            for i in 0..<300 {
                _ = try await diskStorage.upsertItem(makeImageContent(index: i, byteSize: 120 * 1024))
            }

            // File entries
            for i in 0..<300 {
                let path = baseURL.appendingPathComponent("file\(i).txt").path
                _ = try await diskStorage.upsertItem(makeFileContent(path: path))
            }

            await diskSearch.invalidateCache()

            // Warm up (build caches/index) to reduce one-off variance.
            _ = try await diskSearch.search(
                request: SearchRequest(query: "warmup", mode: .fuzzyPlus, limit: 1, offset: 0)
            )

            let start = CFAbsoluteTimeGetCurrent()
            let page = try await diskSearch.search(
                request: SearchRequest(query: "lorem", mode: .fuzzyPlus, limit: 50, offset: 0)
            )
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

            let recent = try await diskStorage.fetchRecent(limit: 5000, offset: 0)
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
    }

    /// 重负载：磁盘模式 50k 条搜索（可选，较慢）
    func testHeavyDiskSearchPerformance50k() async throws {
        try XCTSkipIf(!shouldRunHeavyPerf(), "Run: make test-perf-heavy")

        try await withDiskStorage { diskStorage, diskSearch, _ in
            for i in 0..<50_000 {
                let len = 80 + (i % 400)
                let text = "Heavy note \(i) " + String(repeating: "lorem ipsum ", count: len / 11)
                _ = try await diskStorage.upsertItem(makeContent(text))
            }
            await diskSearch.invalidateCache()

            _ = try await diskSearch.search(
                request: SearchRequest(query: "warmup", mode: .fuzzyPlus, limit: 1, offset: 0)
            )

            var times: [Double] = []
            for query in ["heavy", "lorem", "ipsum", "note"] {
                let start = CFAbsoluteTimeGetCurrent()
                _ = try await diskSearch.search(
                    request: SearchRequest(query: query, mode: .fuzzyPlus, limit: 50, offset: 0)
                )
                times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }

            times.sort()
            let p95Index = min(Int(Double(times.count) * 0.95), times.count - 1)
            let p95 = times[p95Index]
            print("📊 Heavy Disk Search (50k items): P95 \(String(format: "%.2f", p95))ms")
            XCTAssertLessThan(p95, 200, "Heavy disk P95 \(p95)ms exceeds 200ms target for 10k-100k bracket")
        }
    }

    /// 重负载：磁盘模式 75k 条搜索（极端场景，可选，较慢）
    func testUltraDiskSearchPerformance75k() async throws {
        try XCTSkipIf(!shouldRunHeavyPerf(), "Run: make test-perf-heavy")

        try await withDiskStorage { diskStorage, diskSearch, _ in
            for i in 0..<75_000 {
                let len = 120 + (i % 500)
                let text = makeRealisticText(index: i, base: "Ultra note", length: len)
                _ = try await diskStorage.upsertItem(makeContent(text))
            }
            await diskSearch.invalidateCache()

            _ = try await diskSearch.search(
                request: SearchRequest(query: "warmup", mode: .fuzzyPlus, limit: 1, offset: 0)
            )

            var times: [Double] = []
            for query in ["ultra", "note", "lorem", "ipsum"] {
                let start = CFAbsoluteTimeGetCurrent()
                _ = try await diskSearch.search(
                    request: SearchRequest(query: query, mode: .fuzzyPlus, limit: 50, offset: 0)
                )
                times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }

            let p95 = percentile(times, 95)
            print("📊 Ultra Disk Search (75k items): P95 \(String(format: "%.2f", p95))ms")
            XCTAssertLessThan(p95, 250, "Ultra disk P95 \(p95)ms exceeds 250ms target for 10k-100k bracket")
        }
    }

    /// 大规模 regex 性能验证（20k）
    func testRegexPerformance20kItems() async throws {
        for i in 0..<20_000 {
            let text = makeRealisticText(index: i, base: "Regex note", length: 80 + (i % 120))
            _ = try await storage.upsertItem(makeContent(text))
        }
        await search.invalidateCache()

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
        try XCTSkipIf(!shouldRunHeavyPerf(), "Run: make test-perf-heavy")

        try await withDiskStorage { diskStorage, _, _ in
            // 250 x 256KB ≈ 64MB，仍高于 50MB 清理阈值，但更稳定
            for i in 0..<250 {
                let blob = Data(repeating: UInt8(i % 255), count: 256 * 1024) // 256KB
                let content = ClipboardMonitor.ClipboardContent(
                    type: .image,
                    plainText: "[Large image \(i)]",
                    payload: .data(blob),
                    appBundleID: "com.apple.Preview",
                    contentHash: "heavy-img-\(i)",
                    sizeBytes: blob.count
                )
                _ = try await diskStorage.upsertItem(content)
            }

            let externalSize = try await diskStorage.getExternalStorageSize()
            print("📦 External storage size after stress: \(formatBytes(externalSize))")
            XCTAssertGreaterThan(externalSize, 10 * 1024 * 1024, "External storage should exceed 10MB after stress")

            // Trigger cleanup to ensure it runs fast enough
            // 预热一次，避免首次 I/O 抖动
            diskStorage.cleanupSettings.maxLargeStorageMB = 1000
            try await diskStorage.performCleanup()

            diskStorage.cleanupSettings.maxLargeStorageMB = 50 // 50MB cap
            let start = CFAbsoluteTimeGetCurrent()
            try await diskStorage.performCleanup()
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            print("🧹 External cleanup elapsed: \(String(format: "%.2f", elapsed))ms")
            XCTAssertLessThan(elapsed, 800, "External cleanup should finish within 800ms")
        }
    }

    // MARK: - Helpers

    private func makeContent(_ text: String) -> ClipboardMonitor.ClipboardContent {
        ClipboardMonitor.ClipboardContent(
            type: .text,
            plainText: text,
            payload: .none,
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
            payload: data.map { .data($0) } ?? .none,
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
            payload: data.map { .data($0) } ?? .none,
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
            payload: .data(data),
            appBundleID: "com.apple.Preview",
            contentHash: "image-\(index)",
            sizeBytes: data.count
        )
    }

    private func makeFileContent(path: String) -> ClipboardMonitor.ClipboardContent {
        return ClipboardMonitor.ClipboardContent(
            type: .file,
            plainText: path,
            payload: .none,
            appBundleID: "com.apple.finder",
            contentHash: "file-\(path)",
            sizeBytes: path.utf8.count
        )
    }

    private func makeRealisticText(index: Int, base: String, length: Int) -> String {
        let filler = String(repeating: " lorem ipsum", count: max(1, length / 11))
        return "\(base) \(index) \(filler)"
    }

    private static func makeSharedInMemoryDatabasePath() -> String {
        "file:scopy_test_\(UUID().uuidString)?mode=memory&cache=shared"
    }

    private func makeDiskStorage() async throws -> (StorageService, SearchEngineImpl, URL) {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let dbPath = baseURL.appendingPathComponent("clipboard.db").path

        let storage = StorageService(databasePath: dbPath)
        try await storage.open()

        let search = SearchEngineImpl(dbPath: storage.databaseFilePath)

        return (storage, search, baseURL)
    }

    private func withDiskStorage(
        _ body: (StorageService, SearchEngineImpl, URL) async throws -> Void
    ) async throws {
        let (storage, search, baseURL) = try await makeDiskStorage()

        do {
            try await body(storage, search, baseURL)
        } catch {
            await cleanupDiskResources(storage: storage, search: search, baseURL: baseURL)
            throw error
        }

        await cleanupDiskResources(storage: storage, search: search, baseURL: baseURL)
    }

    private func cleanupDiskResources(storage: StorageService, search: SearchEngineImpl, baseURL: URL) async {
        await search.close()
        await storage.close()
        try? FileManager.default.removeItem(at: baseURL)
    }

    private func shouldRunHeavyPerf() -> Bool {
#if SCOPY_HEAVY_PERF_TESTS
        return true
#else
        return false
#endif
    }

    private func shouldRunPerf() -> Bool {
#if SCOPY_PERF_TESTS || SCOPY_HEAVY_PERF_TESTS
        return true
#else
        return false
#endif
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
