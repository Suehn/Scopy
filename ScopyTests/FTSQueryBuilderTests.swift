import XCTest
@testable import ScopyKit

@MainActor
final class FTSQueryBuilderTests: XCTestCase {
    func testBuildSingleTokenQuotesAsPhrase() {
        XCTAssertEqual(FTSQueryBuilder.build(userQuery: "hello"), "\"hello\"")
    }

    func testBuildSplitsWhitespaceIntoAndTerms() {
        XCTAssertEqual(FTSQueryBuilder.build(userQuery: "hello world"), "\"hello\" AND \"world\"")
        XCTAssertEqual(FTSQueryBuilder.build(userQuery: "  hello   world  "), "\"hello\" AND \"world\"")
        XCTAssertEqual(FTSQueryBuilder.build(userQuery: "hello\nworld"), "\"hello\" AND \"world\"")
    }

    func testBuildNormalizesHyphenIntoSpace() {
        XCTAssertEqual(FTSQueryBuilder.build(userQuery: "hello-world"), "\"hello\" AND \"world\"")
    }

    func testBuildStripsWildcardForSafety() {
        XCTAssertEqual(FTSQueryBuilder.build(userQuery: "hel*lo"), "\"hello\"")
    }
}

