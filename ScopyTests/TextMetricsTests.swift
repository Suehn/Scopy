import XCTest
import ScopyKit

final class TextMetricsTests: XCTestCase {
    func testDisplayWordUnitCountEnglishCountsWordsNotLetters() {
        XCTAssertEqual(TextMetrics.displayWordUnitCount(for: "hello"), 1)
        XCTAssertEqual(TextMetrics.displayWordUnitCount(for: "hello world"), 2)
        XCTAssertEqual(TextMetrics.displayWordUnitCount(for: "serstein 的大 gap"), 4)
    }

    func testDisplayWordUnitCountChineseCountsCharacters() {
        XCTAssertEqual(TextMetrics.displayWordUnitCount(for: "你好世界"), 4)
        XCTAssertEqual(TextMetrics.displayWordUnitCount(for: "你好 世界"), 4)
    }

    func testDisplayWordUnitCountMixedCountsExpectedUnits() {
        XCTAssertEqual(TextMetrics.displayWordUnitCount(for: "你好 hello world，123"), 5)
        XCTAssertEqual(TextMetrics.displayWordUnitCount(for: "v0.43.13"), 3)
        XCTAssertEqual(TextMetrics.displayWordUnitCount(for: "don\u{2019}t stop"), 2)
    }
}

