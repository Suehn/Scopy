import XCTest
@testable import ScopyKit

final class SearchPlannerTests: XCTestCase {
    func testEmptyQueryUsesAllWithFilters() {
        let plan = SearchPlanner.plan(request: SearchRequest(query: "", mode: .exact))

        XCTAssertEqual(plan.path, .allWithFilters)
        XCTAssertEqual(plan.coverage, .complete)
        XCTAssertEqual(plan.reason, .emptyQuery)
        XCTAssertEqual(plan.requiredCapabilities, [.allItemsSQL])
    }

    func testExactShortQueryUsesRecentOnlyCache() {
        let plan = SearchPlanner.plan(request: SearchRequest(query: "ab", mode: .exact))

        XCTAssertEqual(plan.path, .exactRecentCache)
        XCTAssertEqual(plan.coverage, .recentOnly(limit: 2_000))
        XCTAssertEqual(plan.reason, .exactShortQueryRecentOnly)
        XCTAssertEqual(plan.requiredCapabilities, [.recentCache])
    }

    func testExactLongQueryUsesFTS() {
        let plan = SearchPlanner.plan(request: SearchRequest(query: "alpha", mode: .exact))

        XCTAssertEqual(plan.path, .exactFTS)
        XCTAssertEqual(plan.coverage, .complete)
        XCTAssertEqual(plan.reason, .exactLongQueryFTS)
        XCTAssertEqual(plan.requiredCapabilities, [.fts])
    }

    func testRegexUsesRecentOnlyCache() {
        let plan = SearchPlanner.plan(request: SearchRequest(query: "Item \\d+", mode: .regex))

        XCTAssertEqual(plan.path, .regexRecentCache)
        XCTAssertEqual(plan.coverage, .recentOnly(limit: 2_000))
        XCTAssertEqual(plan.reason, .regexModeRecentOnly)
        XCTAssertEqual(plan.requiredCapabilities, [.regexEngine, .recentCache])
    }

    func testFuzzyLongQueryWithoutStagedShortcutUsesFullIndex() {
        let plan = SearchPlanner.plan(
            request: SearchRequest(query: "alpha", mode: .fuzzy),
            state: SearchPlanner.State(prefersFTSForFuzzy: false)
        )

        XCTAssertEqual(plan.path, .fullIndexFuzzy)
        XCTAssertEqual(plan.coverage, .complete)
        XCTAssertEqual(plan.reason, .fuzzyLongQueryFullIndex)
        XCTAssertEqual(plan.requiredCapabilities, [.fullFuzzyIndex, .fuzzyScoring])
    }

    func testFuzzyLongQueryWithStagedShortcutUsesInteractivePrefilter() {
        let plan = SearchPlanner.plan(
            request: SearchRequest(query: "alpha", mode: .fuzzy),
            state: SearchPlanner.State(prefersFTSForFuzzy: true)
        )

        XCTAssertEqual(plan.path, .interactiveFuzzyPrefilter)
        XCTAssertEqual(plan.coverage, .stagedRefine)
        XCTAssertEqual(plan.reason, .fuzzyInteractivePrefilter)
        XCTAssertEqual(plan.requiredCapabilities, [.fts, .interactiveRefine])
    }

    func testForcedFuzzyPlusLongASCIITokensUseSubstringOnlyFallback() {
        let plan = SearchPlanner.plan(
            request: SearchRequest(query: "alpha beta", mode: .fuzzyPlus, forceFullFuzzy: true)
        )

        XCTAssertEqual(plan.path, .fuzzyPlusSubstringOnlyFallback)
        XCTAssertEqual(plan.coverage, .complete)
        XCTAssertEqual(plan.reason, .fuzzyPlusForcedSubstringOnly)
        XCTAssertEqual(plan.requiredCapabilities, [.sqlSubstring])
    }

    func testShortFuzzyQueryUsesFullIndexWhenReady() {
        let plan = SearchPlanner.plan(
            request: SearchRequest(query: "ab", mode: .fuzzyPlus),
            state: SearchPlanner.State(fullIndexReady: true, shortQueryIndexReady: true)
        )

        XCTAssertEqual(plan.path, .shortQueryFullIndex)
        XCTAssertEqual(plan.coverage, .complete)
        XCTAssertEqual(plan.reason, .fuzzyShortQueryFullIndexReady)
        XCTAssertEqual(plan.requiredCapabilities, [.fullFuzzyIndex, .fuzzyScoring])
    }

    func testShortFuzzyQueryWithoutReadyIndexesUsesIndexOrSQLFallback() {
        let plan = SearchPlanner.plan(
            request: SearchRequest(query: "ab", mode: .fuzzy)
        )

        XCTAssertEqual(plan.path, .shortQueryIndexOrSQLFallback)
        XCTAssertEqual(plan.coverage, .complete)
        XCTAssertEqual(plan.reason, .fuzzyShortQueryIndexFallback)
        XCTAssertEqual(plan.requiredCapabilities, [.shortQueryIndex, .sqlSubstring])
    }

    func testStableExplanationIsSeparateFromDiagnostics() {
        let plan = SearchPlanner.plan(
            request: SearchRequest(query: "ab", mode: .fuzzy),
            state: SearchPlanner.State(fullIndexReady: false, shortQueryIndexReady: true)
        )

        XCTAssertEqual(plan.path, .shortQueryIndex)
        XCTAssertEqual(plan.reason, .fuzzyShortQueryShortIndexReady)
        XCTAssertEqual(plan.requiredCapabilities, [.shortQueryIndex, .sqlSubstring])
        XCTAssertTrue(plan.diagnostics.contains(SearchPlanDiagnostic(key: "short_query_index_ready", value: "true")))
    }
}
