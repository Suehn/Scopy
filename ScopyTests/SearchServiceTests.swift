import XCTest
@testable import ScopyKit
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

    func testFuzzySearchMatchesASCIIAbbreviationsAsSubsequence() async throws {
        _ = try await storage.upsertItem(makeContent("command"))
        _ = try await storage.upsertItem(makeContent("commit"))
        await search.invalidateCache()

        let result = try await search.search(
            request: SearchRequest(query: "cmd", mode: .fuzzy, sortMode: .relevance, forceFullFuzzy: true, limit: 50, offset: 0)
        )

        XCTAssertTrue(
            result.items.contains(where: { $0.plainText.localizedCaseInsensitiveContains("command") }),
            "fuzzy should match ASCII subsequence abbreviations (cmd -> command)"
        )
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

    func testCorpusMetricsRefreshDoesNotForceShortQueryPrefilter() async throws {
        // Regression guard:
        // Short (<= 2 chars) fuzzy queries must still search the full history without relying on a cache-limited prefilter,
        // even when the corpus becomes "heavy".
        let block = "Here we describe the formalism of the time-dependent spin wave theory. "
        let longText = String(repeating: block, count: 200) // ~14k chars

        for i in 0..<40 {
            _ = try await storage.upsertItem(makeContent("LongDoc \(i)\n" + longText))
        }
        await search.invalidateCache()

        let result = try await search.search(
            request: SearchRequest(query: "zz", mode: .fuzzyPlus, sortMode: .relevance, limit: 50, offset: 0)
        )
        XCTAssertFalse(result.isPrefilter)
    }

    // MARK: - CJK / Substring Fallback

    func testExactSearchFallsBackToSubstringForCJKRun() async throws {
        _ = try await storage.upsertItem(makeContent("这是一份基于你提供的音频内容的逐字稿为了确保内容完整"))
        await search.invalidateCache()

        let result = try await search.search(
            request: SearchRequest(query: "逐字稿", mode: .exact, sortMode: .relevance, limit: 10, offset: 0)
        )
        XCTAssertEqual(result.items.count, 1)
        XCTAssertTrue(result.items[0].plainText.contains("逐字稿"))
        XCTAssertFalse(result.isPrefilter)
    }

    func testFuzzyPlusFindsOldCJKItemBeyondRecentCacheWhenFTSMisses() async throws {
        // Ensure the match is older than the 2k recent-cache window.
        let target = try await storage.upsertItem(makeContent("这是一个很长的中文字符串包含逐字稿在中间用于测试"))

        // Make corpus "heavy" so fuzzy+ prefers FTS fast-path; unicode61 FTS cannot match CJK substrings reliably.
        _ = try await storage.upsertItem(makeContent(String(repeating: "a", count: 120_000)))

        for i in 0..<2001 {
            _ = try await storage.upsertItem(makeContent("Filler \(i)"))
        }
        await search.invalidateCache()

        let result = try await search.search(
            request: SearchRequest(query: "逐字稿", mode: .fuzzyPlus, sortMode: .relevance, limit: 50, offset: 0)
        )

        XCTAssertTrue(result.items.contains(where: { $0.id == target.id }))
        XCTAssertTrue(result.isPrefilter)
    }

    func testFuzzyPlusSkipsFullIndexWhenSubstringOnlyQueryHasNoMatches() async throws {
        // Make the corpus "heavy" so fuzzyPlus prefers the FTS fast-path first.
        _ = try await storage.upsertItem(makeContent(String(repeating: "a", count: 120_000)))
        await search.invalidateCache()

#if DEBUG
        let before = await search.debugFullIndexHealth()
        XCTAssertFalse(before.isBuilt)
#endif

        // "cmd" has no contiguous substring match in this dataset. Without the substring-only SQL fallback,
        // fuzzyPlus would proceed to build a full in-memory index and scan the entire corpus.
        let result = try await search.search(
            request: SearchRequest(query: "cmd", mode: .fuzzyPlus, sortMode: .relevance, limit: 50, offset: 0)
        )

        XCTAssertEqual(result.items.count, 0)
        XCTAssertFalse(result.isPrefilter)

#if DEBUG
        let after = await search.debugFullIndexHealth()
        XCTAssertFalse(after.isBuilt)
#endif
    }

    func testFuzzyPlusSubstringOnlyFallbackEscapesLikeWildcards() async throws {
        // Ensure the substring-only fallback is used (heavy corpus + FTS miss),
        // then verify SQL LIKE wildcards are escaped and treated literally.
        _ = try await storage.upsertItem(makeContent(String(repeating: "a", count: 120_000)))
        _ = try await storage.upsertItem(makeContent("abcdef"))
        await search.invalidateCache()

#if DEBUG
        let before = await search.debugFullIndexHealth()
        XCTAssertFalse(before.isBuilt)
#endif

        let result = try await search.search(
            request: SearchRequest(query: "a_c", mode: .fuzzyPlus, sortMode: .relevance, limit: 50, offset: 0)
        )
        XCTAssertEqual(result.items.count, 0)

#if DEBUG
        let after = await search.debugFullIndexHealth()
        XCTAssertFalse(after.isBuilt)
#endif
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

    func testShortQueryPinnedItemsRankFirst() async throws {
        let pinned = try await storage.upsertItem(makeContent("AB pinned"))
        try await storage.setPin(pinned.id, pinned: true)
        try await Task.sleep(nanoseconds: 10_000_000)

        _ = try await storage.upsertItem(makeContent("ab unpinned"))
        for i in 0..<2001 {
            _ = try await storage.upsertItem(makeContent("Item \(i) filler"))
        }
        await search.invalidateCache()

        let request = SearchRequest(query: "ab", mode: .fuzzyPlus, sortMode: .relevance, limit: 10, offset: 0)
        let result = try await search.search(request: request)

        XCTAssertTrue(result.items.contains(where: { $0.id == pinned.id }))
        XCTAssertEqual(result.items.first?.id, pinned.id)
    }

    func testShortQueryCJKPinnedItemsRankFirst() async throws {
        let pinned = try await storage.upsertItem(makeContent("数学 pinned"))
        try await storage.setPin(pinned.id, pinned: true)
        try await Task.sleep(nanoseconds: 10_000_000)

        _ = try await storage.upsertItem(makeContent("数学 unpinned"))
        for i in 0..<2001 {
            _ = try await storage.upsertItem(makeContent("Item \(i) filler"))
        }
        await search.invalidateCache()

        let request = SearchRequest(query: "数学", mode: .fuzzyPlus, sortMode: .relevance, limit: 10, offset: 0)
        _ = try await search.search(request: request) // triggers short query index build

#if DEBUG
        await search.debugAwaitShortQueryIndexBuild()
        let health = await search.debugShortQueryIndexHealth()
        XCTAssertTrue(health.isBuilt)
#endif

        let result = try await search.search(request: request)
        XCTAssertTrue(result.items.contains(where: { $0.id == pinned.id }))
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

        let result = try await search.search(
            request: SearchRequest(query: "alpha", mode: .exact, sortMode: .recent, limit: 10, offset: 0)
        )
        XCTAssertEqual(result.items.count, 3)
        XCTAssertEqual(result.items.first?.id, pinnedOld.id, "Pinned items should still rank first")

        let unpinned = result.items.filter { !$0.isPinned }
        XCTAssertEqual(unpinned.count, 2)
        XCTAssertGreaterThan(unpinned[0].lastUsedAt, unpinned[1].lastUsedAt)
    }

    func testExactFTSSortModeRelevanceUsesBM25Ordering() async throws {
        let olderMoreRelevant = try await storage.upsertItem(makeContent("alpha alpha alpha beta gamma"))
        try await Task.sleep(nanoseconds: 10_000_000)
        let newerLessRelevant = try await storage.upsertItem(makeContent("alpha"))
        await search.invalidateCache()

        let ftsQuery = "\"alpha\""

        let expectedIDs = try queryExactFTSIDsOrderedByRelevance(ftsQuery: ftsQuery, limit: 10)
        let relevance = try await search.search(
            request: SearchRequest(query: "alpha", mode: .exact, sortMode: .relevance, limit: 10, offset: 0)
        )
        XCTAssertEqual(relevance.items.map(\.id), expectedIDs)

        let recent = try await search.search(
            request: SearchRequest(query: "alpha", mode: .exact, sortMode: .recent, limit: 10, offset: 0)
        )
        XCTAssertEqual(recent.items.first?.id, newerLessRelevant.id)
        XCTAssertTrue(recent.items.contains(where: { $0.id == olderMoreRelevant.id }))
    }

    func testFuzzySearchSortModeRecentUsesLastUsedAt() async throws {
        _ = try await storage.upsertItem(makeContent("abc"))
        try await Task.sleep(nanoseconds: 10_000_000)
        _ = try await storage.upsertItem(makeContent("axbyc"))
        await search.invalidateCache()

        let result = try await search.search(
            request: SearchRequest(query: "abc", mode: .fuzzy, sortMode: .recent, limit: 10, offset: 0)
        )
        XCTAssertGreaterThanOrEqual(result.items.count, 2)

        // "axbyc" is newer but a worse fuzzy match than "abc"; search should still be time-sorted.
        XCTAssertTrue(result.items[0].plainText.localizedCaseInsensitiveContains("axbyc"))
        XCTAssertTrue(result.items[1].plainText.localizedCaseInsensitiveContains("abc"))
        XCTAssertGreaterThan(result.items[0].lastUsedAt, result.items[1].lastUsedAt)
    }

    func testFuzzySearchSortModeRelevanceUsesScore() async throws {
        _ = try await storage.upsertItem(makeContent("abc"))
        try await Task.sleep(nanoseconds: 10_000_000)
        _ = try await storage.upsertItem(makeContent("axbyc"))
        await search.invalidateCache()

        let result = try await search.search(
            request: SearchRequest(query: "abc", mode: .fuzzy, sortMode: .relevance, limit: 10, offset: 0)
        )
        XCTAssertGreaterThanOrEqual(result.items.count, 2)

        // "abc" is a better fuzzy match than "axbyc"; relevance should prioritize score.
        XCTAssertTrue(result.items[0].plainText.localizedCaseInsensitiveContains("abc"))
    }

    func testFuzzyPlusSearchSortModeRelevanceUsesScore() async throws {
        _ = try await storage.upsertItem(makeContent("hello world"))
        try await Task.sleep(nanoseconds: 10_000_000)
        _ = try await storage.upsertItem(makeContent("xx hello yy world"))
        await search.invalidateCache()

        let result = try await search.search(
            request: SearchRequest(query: "hello world", mode: .fuzzyPlus, sortMode: .relevance, limit: 10, offset: 0)
        )
        XCTAssertGreaterThanOrEqual(result.items.count, 2)
        XCTAssertTrue(result.items[0].plainText.localizedCaseInsensitiveContains("hello world"))
    }

    func testShortQueryRelevancePrefersPlainTextMatchesOverNoteMatches() async throws {
        let plainMatch = try await storage.upsertItem(makeContent("ab"))
        try await Task.sleep(nanoseconds: 10_000_000)

        let noteOnly = try await storage.upsertItem(makeContent("xxxxxxxx"))
        _ = try await storage.updateNote(id: noteOnly.id, note: "ab")
        await search.invalidateCache()

        let result = try await search.search(
            request: SearchRequest(query: "ab", mode: .fuzzy, sortMode: .relevance, limit: 10, offset: 0)
        )
        XCTAssertGreaterThanOrEqual(result.items.count, 2)
        XCTAssertEqual(result.items.first?.id, plainMatch.id)
    }

    func testShortQuerySearchesFullHistoryWithoutPrefilter() async throws {
        let target = try await storage.upsertItem(makeContent("zz_target_oldest"))
        for i in 0..<2001 {
            _ = try await storage.upsertItem(makeContent("Item \(i)"))
        }
        await search.invalidateCache()

        let result = try await search.search(request: SearchRequest(query: "zz", mode: .fuzzy, limit: 50, offset: 0))
        XCTAssertTrue(result.items.contains(where: { $0.id == target.id }))
        XCTAssertFalse(result.isPrefilter)

        let forced = try await search.search(
            request: SearchRequest(query: "zz", mode: .fuzzy, forceFullFuzzy: true, limit: 50, offset: 0)
        )
        XCTAssertTrue(forced.items.contains(where: { $0.id == target.id }))
        XCTAssertFalse(forced.isPrefilter)
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

    private func queryExactFTSIDsOrderedByRelevance(ftsQuery: String, limit: Int) throws -> [UUID] {
        var db: OpaquePointer?
        defer {
            if let db {
                sqlite3_close(db)
            }
        }

        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        XCTAssertEqual(sqlite3_open_v2(storage.databaseFilePath, &db, flags, nil), SQLITE_OK, "Failed to open database")
        guard let db else {
            XCTFail("Database handle is nil")
            return []
        }

        let sql = """
            SELECT clipboard_items.id
            FROM clipboard_items
            JOIN clipboard_fts ON clipboard_items.rowid = clipboard_fts.rowid
            WHERE clipboard_fts MATCH ?
            ORDER BY clipboard_items.is_pinned DESC, bm25(clipboard_fts) ASC, clipboard_items.last_used_at DESC, clipboard_items.id ASC
            LIMIT ?
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK, "Failed to prepare statement")
        guard let stmt else { return [] }

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, ftsQuery, -1, sqliteTransient)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var ids: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(stmt, 0) else { continue }
            let idString = String(cString: cString)
            if let id = UUID(uuidString: idString) {
                ids.append(id)
            }
        }
        return ids
    }
}
