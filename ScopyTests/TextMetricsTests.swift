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

    func testDisplayWordUnitCountAndLineCountMatchesComponentsNewlinesCount() {
        let samples: [String] = [
            "",
            "a",
            "a\nb",
            "a\r\nb",
            "\n\n",
            "a\u{2028}b\u{2029}c",
            "end-with-newline\n"
        ]

        for text in samples {
            let expected = text.components(separatedBy: .newlines).count
            let actual = TextMetrics.displayWordUnitCountAndLineCount(for: text).lineCount
            XCTAssertEqual(actual, expected, "lineCount mismatch for text: \(String(reflecting: text))")
        }
    }
}
