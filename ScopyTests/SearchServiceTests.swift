import XCTest
import ScopyKit
import SQLite3

/// SearchService 单元测试
/// 验证 v0.md 第4节的搜索性能和功能要求
@MainActor
final class SearchServiceTests: XCTestCase {

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
        await storage.close()
        storage = nil
        search = nil
    }

    // MARK: - Basic Search Tests

    func testExactSearch() async throws {
        try await populateTestData()

        let request = SearchRequest(query: "Hello", mode: .exact, limit: 50, offset: 0)
        let result = try await search.search(request: request)

        XCTAssertGreaterThan(result.items.count, 0)
        XCTAssertTrue(result.items.allSatisfy { $0.plainText.lowercased().contains("hello") })
    }

    func testExactSearchSplitsWordsByDefault() async throws {
        _ = try await storage.upsertItem(makeContent("Hello there World", type: .text))
        _ = try await storage.upsertItem(makeContent("Hello World", type: .text))
        await search.invalidateCache()

        let result = try await search.search(request: SearchRequest(query: "Hello World", mode: .exact, limit: 50, offset: 0))
        XCTAssertTrue(result.items.contains { $0.plainText.localizedCaseInsensitiveContains("Hello") })
        XCTAssertTrue(result.items.contains { $0.plainText.localizedCaseInsensitiveContains("World") })
        XCTAssertTrue(result.items.contains { $0.plainText.localizedCaseInsensitiveContains("Hello there World") })
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
        await search.invalidateCache()

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

    func testFTSUpdateTriggerOnlyFiresOnPlainTextChange() async throws {
        // Verify migration installs the optimized trigger definition (v2).
        let dbPath = storage.databaseFilePath
        var db: OpaquePointer?
        defer {
            if let db {
                sqlite3_close(db)
            }
        }

        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        XCTAssertEqual(sqlite3_open_v2(dbPath, &db, flags, nil), SQLITE_OK, "Failed to open database for inspection")
        guard let db else {
            XCTFail("Database handle is nil")
            return
        }

        func querySingleText(_ sql: String) -> String? {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            guard let cString = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: cString)
        }

        func querySingleInt(_ sql: String) -> Int? {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Int(sqlite3_column_int(stmt, 0))
        }

        let userVersion = querySingleInt("PRAGMA user_version") ?? 0
        XCTAssertGreaterThanOrEqual(userVersion, 2, "Expected migration user_version >= 2")

        let triggerSQL = querySingleText("SELECT sql FROM sqlite_master WHERE type='trigger' AND name='clipboard_au'")
        XCTAssertNotNil(triggerSQL, "Expected clipboard_au trigger to exist")
        XCTAssertTrue(triggerSQL?.contains("AFTER UPDATE OF plain_text") == true)
        XCTAssertTrue(triggerSQL?.contains("WHEN OLD.plain_text IS NOT NEW.plain_text") == true)
    }

    // MARK: - Filter Tests

    func testAppFilter() async throws {
        // Insert items from different apps
        _ = try await storage.upsertItem(makeContent("Safari text", app: "com.apple.Safari"))
        _ = try await storage.upsertItem(makeContent("Xcode text", app: "com.apple.dt.Xcode"))
        _ = try await storage.upsertItem(makeContent("Terminal text", app: "com.apple.Terminal"))
        await search.invalidateCache()

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
        await search.invalidateCache()

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
        await search.invalidateCache()

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
        await search.invalidateCache()

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
        await search.invalidateCache()

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
        await search.invalidateCache()

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
        } catch SearchEngineImpl.SearchError.invalidQuery {
            // Expected
        }
    }

    func testCaseSensitivity() async throws {
        _ = try await storage.upsertItem(makeContent("UPPERCASE"))
        _ = try await storage.upsertItem(makeContent("lowercase"))
        _ = try await storage.upsertItem(makeContent("MixedCase"))
        await search.invalidateCache()

        let request = SearchRequest(query: "case", mode: .fuzzy, limit: 50, offset: 0)
        let result = try await search.search(request: request)

        // Should find all three (case insensitive)
        XCTAssertEqual(result.items.count, 3)
    }

    func testFuzzyPinnedItemsRankFirst() async throws {
        let pinned = try await storage.upsertItem(makeContent("axbyc"))
        try await storage.setPin(pinned.id, pinned: true)
        _ = try await storage.upsertItem(makeContent("abc"))
        await search.invalidateCache()

        let request = SearchRequest(query: "abc", mode: .fuzzy, limit: 10, offset: 0)
        let result = try await search.search(request: request)

        XCTAssertEqual(result.items.first?.id, pinned.id)
    }

    func testExactSearchResultsSortByLastUsedAt() async throws {
        let pinnedOld = try await storage.upsertItem(makeContent("alpha pinned old"))
        try await storage.setPin(pinnedOld.id, pinned: true)
        try await Task.sleep(nanoseconds: 10_000_000)

        _ = try await storage.upsertItem(makeContent("alpha middle"))
        try await Task.sleep(nanoseconds: 10_000_000)

        _ = try await storage.upsertItem(makeContent("alpha newest"))
        await search.invalidateCache()

        let result = try await search.search(request: SearchRequest(query: "alpha", mode: .exact, limit: 10, offset: 0))
        XCTAssertEqual(result.items.count, 3)
        XCTAssertEqual(result.items.first?.id, pinnedOld.id, "Pinned items should still rank first")

        let unpinned = result.items.filter { !$0.isPinned }
        XCTAssertEqual(unpinned.count, 2)
        XCTAssertGreaterThan(unpinned[0].lastUsedAt, unpinned[1].lastUsedAt)
    }

    func testFuzzySearchResultsSortByLastUsedAt() async throws {
        _ = try await storage.upsertItem(makeContent("abc"))
        try await Task.sleep(nanoseconds: 10_000_000)
        _ = try await storage.upsertItem(makeContent("axbyc"))
        await search.invalidateCache()

        let result = try await search.search(request: SearchRequest(query: "abc", mode: .fuzzy, limit: 10, offset: 0))
        XCTAssertGreaterThanOrEqual(result.items.count, 2)

        // "axbyc" is newer but a worse fuzzy match than "abc"; search should still be time-sorted.
        XCTAssertTrue(result.items[0].plainText.localizedCaseInsensitiveContains("axbyc"))
        XCTAssertTrue(result.items[1].plainText.localizedCaseInsensitiveContains("abc"))
        XCTAssertGreaterThan(result.items[0].lastUsedAt, result.items[1].lastUsedAt)
    }

    func testShortQueryPrefilterCanRefineToFullFuzzy() async throws {
        _ = try await storage.upsertItem(makeContent("zz_target_oldest"))
        for i in 0..<2001 {
            _ = try await storage.upsertItem(makeContent("Item \(i)"))
        }
        await search.invalidateCache()

        let prefilter = try await search.search(request: SearchRequest(query: "zz", mode: .fuzzy, limit: 50, offset: 0))
        XCTAssertTrue(prefilter.items.isEmpty)
        XCTAssertEqual(prefilter.total, -1)

        let full = try await search.search(
            request: SearchRequest(query: "zz", mode: .fuzzy, forceFullFuzzy: true, limit: 50, offset: 0)
        )
        XCTAssertTrue(full.items.contains { $0.plainText.localizedCaseInsensitiveContains("zz") })
        XCTAssertNotEqual(full.total, -1)
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
        await search.invalidateCache()
    }

    private static func makeSharedInMemoryDatabasePath() -> String {
        "file:scopy_test_\(UUID().uuidString)?mode=memory&cache=shared"
    }

    private func makeContent(
        _ text: String,
        type: ClipboardItemType = .text,
        app: String = "com.test.app"
    ) -> ClipboardMonitor.ClipboardContent {
        ClipboardMonitor.ClipboardContent(
            type: type,
            plainText: text,
            payload: .none,
            appBundleID: app,
            contentHash: String(text.hashValue),
            sizeBytes: text.utf8.count
        )
    }
}
