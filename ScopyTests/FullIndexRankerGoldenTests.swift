import XCTest
@testable import ScopyKit

/// Locks the fuzzy ranking rules on an in-memory index: pinned first, the recent/relevance
/// tie-breaks, the UUID fallback, the recent early stop, staged-vs-complete agreement, deep-paging
/// cache pages, and the fuzzy+ substring-versus-subsequence scoring split.
final class FullIndexRankerGoldenTests: XCTestCase {
    private struct Row {
        let number: Int
        let text: String
        var app: String = "com.a"
        let t: TimeInterval
        var pinned: Bool = false
        var type: ClipboardItemType = .text
    }

    // Fuzzy "abc" scores: 1, 4, 6, 7, 8 = 28; 2 = 27; 3 = 24; 5 never matches.
    private static let rows: [Row] = [
        Row(number: 1, text: "abc first", t: 100),
        Row(number: 2, text: "xabc", t: 200),
        Row(number: 3, text: "a_b_c", app: "com.b", t: 300),
        Row(number: 4, text: "abc pinned", app: "com.b", t: 50, pinned: true),
        Row(number: 5, text: "zzz", t: 400),
        Row(number: 6, text: "abc same time", app: "com.c", t: 200),
        Row(number: 7, text: "abc uuid tie", app: "com.c", t: 200),
        Row(number: 8, text: "abc image", t: 150, type: .image),
        Row(number: 9, text: "数学题", t: 10),
    ]

    // Recent-sort (pinned, last used) groups that straddle page boundaries, with different "abc"
    // scores inside each group: the best row is scanned last at t = 300 and first at t = 200.
    private static let sameTimeRows: [Row] = [
        Row(number: 11, text: "a_b_c", t: 300),
        Row(number: 12, text: "xabc", t: 300),
        Row(number: 13, text: "abc best", t: 300),
        Row(number: 14, text: "abc pinned", t: 10, pinned: true),
        Row(number: 15, text: "abc best", t: 200),
        Row(number: 16, text: "a_b_c", t: 200),
        Row(number: 17, text: "zzz", t: 250),
        Row(number: 18, text: "xabc", t: 200),
        Row(number: 19, text: "xabc", t: 100),
        Row(number: 20, text: "abc x", t: 100),
        Row(number: 21, text: "a_b_c", t: 50),
    ]
    private static let sameTimeRecentOrder = [14, 13, 12, 11, 15, 18, 16, 20, 19, 21]

    private static func uuid(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012X", number))!
    }

    private static func makeIndex(_ rows: [Row]) -> FullFuzzyIndex {
        var index = FullFuzzyIndex(reserveSlots: rows.count)
        for row in rows {
            index.append(
                IndexedItem(
                    id: uuid(row.number),
                    type: row.type,
                    plainTextLower: row.text,
                    appBundleID: row.app,
                    lastUsedAt: Date(timeIntervalSince1970: row.t),
                    isPinned: row.pinned
                )
            )
        }
        return index
    }

    private let index = FullIndexRankerGoldenTests.makeIndex(FullIndexRankerGoldenTests.rows)

    private func numbers(_ slots: [Int], in rows: [Row] = FullIndexRankerGoldenTests.rows) -> [Int] {
        slots.map { rows[$0].number }
    }

    private func request(
        _ query: String,
        mode: SearchMode = .fuzzy,
        sort: SearchSortMode,
        app: String? = nil,
        type: ClipboardItemType? = nil,
        types: Set<ClipboardItemType>? = nil,
        limit: Int = 10,
        offset: Int = 0
    ) -> SearchRequest {
        SearchRequest(
            query: query,
            mode: mode,
            sortMode: sort,
            appFilter: app,
            typeFilter: type,
            typeFilters: types,
            limit: limit,
            offset: offset
        )
    }

    private func complete(
        _ request: SearchRequest,
        in index: FullFuzzyIndex? = nil,
        cache: inout FullIndexRanker.SortedMatchesCache?
    ) throws -> FullIndexRanker.Page {
        let index = index ?? self.index
        let queryLower = request.query.lowercased()
        return try FullIndexRanker.rankComplete(
            index: index,
            request: request,
            mode: request.mode,
            queryLower: queryLower,
            scorer: FuzzyMatcher.Scorer(queryLower: queryLower, mode: request.mode),
            candidateSlots: FullIndexRanker.candidateSlots(index: index, queryLower: queryLower),
            indexContentVersion: 1,
            cache: &cache,
            perf: nil
        )
    }

    private func complete(_ request: SearchRequest) throws -> FullIndexRanker.Page {
        var cache: FullIndexRanker.SortedMatchesCache?
        return try complete(request, cache: &cache)
    }

    private func staged(_ request: SearchRequest) throws -> FullIndexRanker.Page {
        let queryLower = request.query.lowercased()
        return try FullIndexRanker.rankStaged(
            index: index,
            request: request,
            scorer: FuzzyMatcher.Scorer(queryLower: queryLower, mode: request.mode),
            candidateSlots: FullIndexRanker.candidateSlots(index: index, queryLower: queryLower),
            perf: nil
        )
    }

    // MARK: - Candidates

    func testCandidateSlotsRequireEveryQueryCharacterAndIgnoreWhitespace() {
        XCTAssertEqual(numbers(FullIndexRanker.candidateSlots(index: index, queryLower: "abc")), [1, 2, 3, 4, 6, 7, 8])
        XCTAssertEqual(numbers(FullIndexRanker.candidateSlots(index: index, queryLower: "a b")), [1, 2, 3, 4, 6, 7, 8])
        XCTAssertEqual(numbers(FullIndexRanker.candidateSlots(index: index, queryLower: "学")), [9])
        XCTAssertEqual(FullIndexRanker.candidateSlots(index: index, queryLower: "q"), [])
        XCTAssertEqual(FullIndexRanker.candidateSlots(index: index, queryLower: " ").count, 9)
    }

    // MARK: - Ordering

    func testRelevanceOrdersPinnedThenScoreThenRecencyThenUUID() throws {
        let page = try complete(request("abc", sort: .relevance))
        XCTAssertEqual(numbers(page.slots), [4, 6, 7, 8, 1, 2, 3])
        XCTAssertEqual(page.total, 7)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.coverage, .complete)
    }

    func testRecentOrdersPinnedThenRecencyThenScoreThenUUID() throws {
        let page = try complete(request("abc", sort: .recent))
        XCTAssertEqual(numbers(page.slots), [4, 3, 6, 7, 2, 8, 1])
    }

    func testFiltersApplyBeforeRanking() throws {
        XCTAssertEqual(numbers(try complete(request("abc", sort: .relevance, app: "com.a")).slots), [8, 1, 2])
        XCTAssertEqual(numbers(try complete(request("abc", sort: .relevance, type: .text)).slots), [4, 6, 7, 1, 2, 3])
        XCTAssertEqual(numbers(try complete(request("abc", sort: .relevance, type: .text, types: [.image])).slots), [8])
    }

    func testPagesAreConsecutiveAndReportHasMore() throws {
        let first = try complete(request("abc", sort: .relevance, limit: 3, offset: 0))
        let second = try complete(request("abc", sort: .relevance, limit: 3, offset: 3))
        let third = try complete(request("abc", sort: .relevance, limit: 3, offset: 6))
        XCTAssertEqual(numbers(first.slots), [4, 6, 7])
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(numbers(second.slots), [8, 1, 2])
        XCTAssertTrue(second.hasMore)
        XCTAssertEqual(numbers(third.slots), [3])
        XCTAssertFalse(third.hasMore)
        XCTAssertEqual(third.total, 7)
    }

    func testDeepPagingCacheHitReturnsTheSamePageAsAFreshScan() throws {
        var cache: FullIndexRanker.SortedMatchesCache?
        _ = try complete(request("abc", sort: .relevance, limit: 2, offset: 0), cache: &cache)
        XCTAssertNotNil(cache)

        let cached = try complete(request("abc", sort: .relevance, limit: 2, offset: 2), cache: &cache)
        let fresh = try complete(request("abc", sort: .relevance, limit: 2, offset: 2))
        XCTAssertEqual(numbers(cached.slots), [7, 8])
        XCTAssertEqual(numbers(cached.slots), numbers(fresh.slots))
        XCTAssertEqual(cached.total, fresh.total)
        XCTAssertEqual(cached.hasMore, fresh.hasMore)
    }

    func testRecentScoresWholeSameTimeGroupsAndStopsAtTheNext() throws {
        let index = Self.makeIndex(Self.sameTimeRows)
        let expected = Self.sameTimeRecentOrder
        for limit in 1...3 {
            for offset in 0..<expected.count {
                var cache: FullIndexRanker.SortedMatchesCache?
                let page = try complete(request("abc", sort: .recent, limit: limit, offset: offset), in: index, cache: &cache)
                let window = "limit \(limit) offset \(offset)"
                XCTAssertEqual(numbers(page.slots, in: Self.sameTimeRows), Array(expected.dropFirst(offset).prefix(limit)), window)
                XCTAssertEqual(page.hasMore, offset + limit < expected.count, window)
                if page.hasMore {
                    XCTAssertTrue([-1, expected.count].contains(page.total), window)
                } else {
                    XCTAssertEqual(page.total, expected.count, window)
                }
            }
        }

        // The pinned row and the whole t = 300 group cover the page and one more hit.
        var cache: FullIndexRanker.SortedMatchesCache?
        let first = try complete(request("abc", sort: .recent, limit: 1, offset: 0), in: index, cache: &cache)
        XCTAssertEqual(numbers(first.slots, in: Self.sameTimeRows), [14])
        XCTAssertEqual(first.total, -1)
        XCTAssertEqual(cache?.recentScan?.scanned, 4)
    }

    func testRecentDeepPagesContinueTheScanFromTheCache() throws {
        let index = Self.makeIndex(Self.sameTimeRows)
        var cache: FullIndexRanker.SortedMatchesCache?
        var seen: [Int] = []
        for offset in stride(from: 0, through: Self.sameTimeRecentOrder.count, by: 2) {
            let page = try complete(request("abc", sort: .recent, limit: 2, offset: offset), in: index, cache: &cache)
            seen += numbers(page.slots, in: Self.sameTimeRows)
        }
        XCTAssertEqual(seen, Self.sameTimeRecentOrder)
        XCTAssertNil(cache?.recentScan)
        XCTAssertEqual(cache?.totalMatches, Self.sameTimeRecentOrder.count)
    }

    func testStagedRecentAndCompleteRecentAgreeOnDistinctTimestamps() throws {
        // Every match here has a distinct lastUsedAt, so lazy scoring after the recency pre-sort
        // must produce the page the full heap produces.
        for (limit, offset) in [(10, 0), (2, 1), (3, 0)] {
            let stagedPage = try staged(request("abc", sort: .recent, app: "com.a", limit: limit, offset: offset))
            let completePage = try complete(request("abc", sort: .recent, app: "com.a", limit: limit, offset: offset))
            XCTAssertEqual(numbers(stagedPage.slots), numbers(completePage.slots), "limit \(limit) offset \(offset)")
            XCTAssertEqual(stagedPage.hasMore, completePage.hasMore, "limit \(limit) offset \(offset)")
        }
        XCTAssertEqual(numbers(try staged(request("abc", sort: .recent, app: "com.a")).slots), [2, 8, 1])
    }

    func testStagedRelevanceKeepsTheHeapOrderAndUnknownTotal() throws {
        let page = try staged(request("abc", sort: .relevance, limit: 3, offset: 0))
        XCTAssertEqual(numbers(page.slots), [4, 6, 7])
        XCTAssertEqual(page.total, -1)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.coverage, .stagedRefine)
    }

    func testPrefilterMergeKeepsEveryPinnedCandidate() {
        let candidates = FullIndexRanker.candidateSlots(index: index, queryLower: "abc")
        let merged = FullIndexRanker.mergePrefilter(candidateSlots: candidates, ftsSlots: [0, 1], index: index)
        XCTAssertEqual(Set(numbers(merged)), [1, 2, 4])
    }

    // MARK: - Scoring

    func testFuzzyScoresRewardContiguousEarlyMatches() {
        let scorer = FuzzyMatcher.Scorer(queryLower: "abc", mode: .fuzzy)
        XCTAssertEqual(scorer.score(textLower: "abc first"), 28)
        XCTAssertEqual(scorer.score(textLower: "xabc"), 27)
        XCTAssertEqual(scorer.score(textLower: "a_b_c"), 24)
        XCTAssertNil(scorer.score(textLower: "acb"))
        XCTAssertEqual(FuzzyMatcher.Scorer(queryLower: "ab", mode: .fuzzy).score(textLower: "xxab"), 17)
    }

    func testFuzzyPlusASCIIWordsOfThreeOrMoreCharactersMatchAsSubstrings() {
        let scorer = FuzzyMatcher.Scorer(queryLower: "abc def", mode: .fuzzyPlus)
        XCTAssertEqual(scorer.score(textLower: "abc def"), 52)
        XCTAssertNil(scorer.score(textLower: "abdc def"), "a subsequence is not enough for a 3+ character ASCII word")
    }

    func testFuzzyPlusShortAndNonASCIIWordsUseTheFuzzyQueryScore() {
        let short = FuzzyMatcher.Scorer(queryLower: "ab cd", mode: .fuzzyPlus)
        XCTAssertEqual(short.score(textLower: "xab cd"), 33)
        XCTAssertNil(short.score(textLower: "a b c d"))

        let cjk = FuzzyMatcher.Scorer(queryLower: "数学题", mode: .fuzzyPlus)
        XCTAssertEqual(cjk.score(textLower: "数x学y题"), 24)
        XCTAssertEqual(cjk.score(textLower: "数学题"), 28)
    }

    func testTopKSelectorKeepsTheBestElements() {
        var selector = TopKSelector<Int>(capacity: 3) { $0 > $1 }
        for value in [5, 1, 9, 3, 7, 2, 8] {
            selector.offer(value)
        }
        XCTAssertEqual(selector.sortedElements(), [9, 8, 7])
        XCTAssertEqual(TopKSelector<Int>(capacity: 0) { $0 > $1 }.sortedElements(), [])
    }
}
