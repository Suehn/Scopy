import XCTest
@testable import ScopyKit

final class SearchQueryNormalizationTests: XCTestCase {
    func testFuzzyPlusTokenizationUsesEveryWhitespaceSeparator() {
        XCTAssertEqual(
            SearchQueryNormalization.fuzzyPlusTokens("alpha\tbeta\ngamma  delta"),
            ["alpha", "beta", "gamma", "delta"]
        )
    }
}
