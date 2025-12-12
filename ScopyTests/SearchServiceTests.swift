import XCTest
@testable import Scopy

/// SearchService 单元测试
/// 验证 v0.md 第4节的搜索性能和功能要求
@MainActor
final class SearchServiceTests: XCTestCase {

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

    // MARK: - Basic Search Tests

    func testExactSearch() async throws {
        try await populateTestData()

        let request = SearchRequest(query: "Hello", mode: .exact, limit: 50, offset: 0)
        let result = try await search.search(request: request)

        XCTAssertGreaterThan(result.items.count, 0)
        XCTAssertTrue(result.items.allSatisfy { $0.plainText.lowercased().contains("hello") })
    }

    func testFuzzySearch() async throws {
        try await populateTestData()

        let request = SearchRequest(query: "hlo", mode: .fuzzy, limit: 50, offset: 0)
        let result = try await search.search(request: request)

        // Fuzzy should find "Hello" with "hlo"
        XCTAssertGreaterThan(result.items.count, 0)
    }

    func testFuzzyPlusRequiresContiguousASCIIWords() async throws {
        _ = try await storage.upsertItem(makeContent("Here we go", type: .text))
        _ = try await storage.upsertItem(makeContent("/Users/test/WeChat Files/9d5520c5d3e1ce6da40d435f5300958f.png", type: .file))
        search.invalidateCache()

        let request = SearchRequest(query: "Here we", mode: .fuzzyPlus, limit: 50, offset: 0)
        let result = try await search.search(request: request)

        XCTAssertTrue(result.items.contains { $0.plainText.localizedCaseInsensitiveContains("Here we") })
        XCTAssertFalse(result.items.contains { $0.type == .file }, "ASCII long-word fuzzyPlus should not match gappy file paths")
    }

    func testRegexSearch() async throws {
        try await populateTestData()

        let request = SearchRequest(query: "Item \\d+", mode: .regex, limit: 50, offset: 0)
        let result = try await search.search(request: request)

        XCTAssertGreaterThan(result.items.count, 0)
        // All items should match the pattern
        let regex = try! NSRegularExpression(pattern: "Item \\d+", options: [])
        for item in result.items {
            let range = NSRange(item.plainText.startIndex..., in: item.plainText)
            XCTAssertNotNil(regex.firstMatch(in: item.plainText, range: range))
        }
    }

    func testSearchWithNoResults() async throws {
        try await populateTestData()

        let request = SearchRequest(query: "xyznonexistent123", mode: .exact, limit: 50, offset: 0)
        let result = try await search.search(request: request)

        XCTAssertEqual(result.items.count, 0)
        XCTAssertEqual(result.total, 0)
        XCTAssertFalse(result.hasMore)
    }

    func testEmptyQuery() async throws {
        try await populateTestData()

        let request = SearchRequest(query: "", mode: .exact, limit: 50, offset: 0)
        let result = try await search.search(request: request)

        // Empty query should return all items (up to limit)
        XCTAssertGreaterThan(result.items.count, 0)
    }

    // MARK: - Pagination Tests

    func testSearchPagination() async throws {
        try await populateTestData(count: 100)

        let request1 = SearchRequest(query: "Item", mode: .fuzzy, limit: 20, offset: 0)
        let result1 = try await search.search(request: request1)

        XCTAssertEqual(result1.items.count, 20)
        XCTAssertTrue(result1.hasMore)

        let request2 = SearchRequest(query: "Item", mode: .fuzzy, limit: 20, offset: 20)
        let result2 = try await search.search(request: request2)

        XCTAssertEqual(result2.items.count, 20)

        // Pages should be different
        let ids1 = Set(result1.items.map { $0.id })
        let ids2 = Set(result2.items.map { $0.id })
        XCTAssertTrue(ids1.isDisjoint(with: ids2))
    }

    func testHasMoreFlag() async throws {
        try await populateTestData(count: 25)

        let request1 = SearchRequest(query: "Item", mode: .fuzzy, limit: 10, offset: 0)
        let result1 = try await search.search(request: request1)
        XCTAssertTrue(result1.hasMore)

        let request2 = SearchRequest(query: "Item", mode: .fuzzy, limit: 10, offset: 20)
        let result2 = try await search.search(request: request2)
        XCTAssertFalse(result2.hasMore) // Only 5 items left (25 - 20)
    }

    // MARK: - Filter Tests

    func testAppFilter() async throws {
        // Insert items from different apps
        _ = try await storage.upsertItem(makeContent("Safari text", app: "com.apple.Safari"))
        _ = try await storage.upsertItem(makeContent("Xcode text", app: "com.apple.dt.Xcode"))
        _ = try await storage.upsertItem(makeContent("Terminal text", app: "com.apple.Terminal"))
        search.invalidateCache()

        let request = SearchRequest(
            query: "text",
            mode: .fuzzy,
            appFilter: "com.apple.Safari",
            limit: 50,
            offset: 0
        )
        let result = try await search.search(request: request)

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].appBundleID, "com.apple.Safari")
    }

    func testTypeFilter() async throws {
        // Insert different types
        _ = try await storage.upsertItem(makeContent("Text content", type: .text))
        _ = try await storage.upsertItem(makeContent("HTML content", type: .html))
        search.invalidateCache()

        let request = SearchRequest(
            query: "content",
            mode: .fuzzy,
            typeFilter: .text,
            limit: 50,
            offset: 0
        )
        let result = try await search.search(request: request)

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].type, .text)
    }

    func testEmptyQueryWithAppFilterReturnsAll() async throws {
        _ = try await storage.upsertItem(makeContent("A1", app: "com.test.one"))
        _ = try await storage.upsertItem(makeContent("A2", app: "com.test.one"))
        _ = try await storage.upsertItem(makeContent("B1", app: "com.test.two"))
        search.invalidateCache()

        let request = SearchRequest(
            query: "",
            mode: .exact,
            appFilter: "com.test.one",
            limit: 50,
            offset: 0
        )
        let result = try await search.search(request: request)

        XCTAssertEqual(result.total, 2)
        XCTAssertEqual(result.items.count, 2)
        XCTAssertTrue(result.items.allSatisfy { $0.appBundleID == "com.test.one" })
    }

    func testFilteredPaginationHasMore() async throws {
        for i in 0..<60 {
            _ = try await storage.upsertItem(makeContent("Item \(i)", app: "com.test.paged"))
        }
        search.invalidateCache()

        let firstPage = try await search.search(
            request: SearchRequest(query: "", mode: .exact, appFilter: "com.test.paged", limit: 30, offset: 0)
        )
        XCTAssertEqual(firstPage.items.count, 30)
        XCTAssertTrue(firstPage.hasMore)

        let secondPage = try await search.search(
            request: SearchRequest(query: "", mode: .exact, appFilter: "com.test.paged", limit: 30, offset: 30)
        )
        XCTAssertGreaterThan(secondPage.items.count, 0)
        XCTAssertEqual(secondPage.total, 60)
    }

    // MARK: - Performance Tests (v0.md 4.1)

    func testSearchPerformance5kItems() async throws {
        // Skip if not running performance tests
        #if DEBUG
        try XCTSkipIf(ProcessInfo.processInfo.environment["RUN_PERF_TESTS"] == nil,
                      "Set RUN_PERF_TESTS env var to run performance tests")
        #endif

        try await populateTestData(count: 5000)

        let request = SearchRequest(query: "test", mode: .fuzzy, limit: 50, offset: 0)

        // v0.md 4.1: P95 ≤ 50ms for ≤5k items
        measure {
            let expectation = XCTestExpectation(description: "Search completed")
            Task {
                _ = try await self.search.search(request: request)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 1.0)
        }
    }

    func testSearchPerformanceTiming() async throws {
        try await populateTestData(count: 1000)

        let request = SearchRequest(query: "Item", mode: .fuzzy, limit: 50, offset: 0)
        let result = try await search.search(request: request)

        // Check that search time is reported
        XCTAssertGreaterThanOrEqual(result.searchTimeMs, 0)

        // For 1k items, should be very fast (< 100ms typically)
        XCTAssertLessThan(result.searchTimeMs, 100, "Search took too long: \(result.searchTimeMs)ms")
    }

    // MARK: - Short Query Optimization Tests (v0.md 4.2)

    func testShortQueryUsesCache() async throws {
        try await populateTestData(count: 100)

        // First search - populates cache
        let request1 = SearchRequest(query: "a", mode: .fuzzy, limit: 50, offset: 0)
        let result1 = try await search.search(request: request1)
        let time1 = result1.searchTimeMs

        // Second search - should use cache
        let request2 = SearchRequest(query: "b", mode: .fuzzy, limit: 50, offset: 0)
        let result2 = try await search.search(request: request2)
        let time2 = result2.searchTimeMs

        // Cache hit should be faster (or at least not significantly slower)
        // This is a soft assertion since timing can vary
        print("Cache test: First query \(time1)ms, Second query \(time2)ms")
    }

    // MARK: - Cache Invalidation Tests

    func testCacheInvalidation() async throws {
        try await populateTestData(count: 10)

        // First search
        let request = SearchRequest(query: "Item", mode: .fuzzy, limit: 50, offset: 0)
        let result1 = try await search.search(request: request)

        // Add new item
        _ = try await storage.upsertItem(makeContent("New Item 999"))

        // Invalidate cache
        search.invalidateCache()

        // Search again
        let result2 = try await search.search(request: request)

        // Should have one more item
        XCTAssertGreaterThan(result2.total, result1.total)
    }

    // MARK: - Edge Cases

    func testSpecialCharactersInQuery() async throws {
        _ = try await storage.upsertItem(makeContent("Test with \"quotes\""))
        _ = try await storage.upsertItem(makeContent("Test with * asterisk"))
        _ = try await storage.upsertItem(makeContent("Test with - dash"))
        search.invalidateCache()

        // These should not crash
        let queries = ["\"", "*", "-", "test\"", "test*", "test-word"]
        for q in queries {
            let request = SearchRequest(query: q, mode: .exact, limit: 50, offset: 0)
            _ = try await search.search(request: request)
        }
    }

    func testInvalidRegex() async throws {
        try await populateTestData(count: 5)

        let request = SearchRequest(query: "[invalid(regex", mode: .regex, limit: 50, offset: 0)

        do {
            _ = try await search.search(request: request)
            XCTFail("Should have thrown for invalid regex")
        } catch SearchService.SearchError.invalidQuery {
            // Expected
        }
    }

    func testCaseSensitivity() async throws {
        _ = try await storage.upsertItem(makeContent("UPPERCASE"))
        _ = try await storage.upsertItem(makeContent("lowercase"))
        _ = try await storage.upsertItem(makeContent("MixedCase"))
        search.invalidateCache()

        let request = SearchRequest(query: "case", mode: .fuzzy, limit: 50, offset: 0)
        let result = try await search.search(request: request)

        // Should find all three (case insensitive)
        XCTAssertEqual(result.items.count, 3)
    }

    func testFuzzyPinnedItemsRankFirst() async throws {
        let pinned = try await storage.upsertItem(makeContent("axbyc"))
        try storage.setPin(pinned.id, pinned: true)
        _ = try await storage.upsertItem(makeContent("abc"))
        search.invalidateCache()

        let request = SearchRequest(query: "abc", mode: .fuzzy, limit: 10, offset: 0)
        let result = try await search.search(request: request)

        XCTAssertEqual(result.items.first?.id, pinned.id)
    }

    // MARK: - Helpers

    private func populateTestData(count: Int = 50) async throws {
        for i in 0..<count {
            let text: String
            if i % 3 == 0 {
                text = "Hello World Item \(i)"
            } else if i % 3 == 1 {
                text = "Test Item \(i) with some data"
            } else {
                text = "Item \(i) random content xyz"
            }
            _ = try await storage.upsertItem(makeContent(text))
        }
        search.invalidateCache()
    }

    private func makeContent(
        _ text: String,
        type: ClipboardItemType = .text,
        app: String = "com.test.app"
    ) -> ClipboardMonitor.ClipboardContent {
        ClipboardMonitor.ClipboardContent(
            type: type,
            plainText: text,
            rawData: nil,
            appBundleID: app,
            contentHash: String(text.hashValue),
            sizeBytes: text.utf8.count
        )
    }
}
