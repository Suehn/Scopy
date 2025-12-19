import XCTest
import ScopyKit

@testable import Scopy

final class ClipboardItemDisplayTextTests: XCTestCase {
    @MainActor
    func testTextMetadataMatchesLegacyImplementation() {
        let samples: [String] = [
            "",
            "hello world",
            "你好 世界",
            "a\nb",
            "a\r\nb",
            "\n\n",
            "line1\u{2028}line2",
            "123456789012345",
            "1234567890123456",
            "ends-with-cr\r",
            "ends-with-lf\n",
            "emoji🙂test\nnext"
        ]

        for text in samples {
            let expected = legacyTextMetadata(text)
            let actual = ClipboardItemDisplayText.shared.metadata(for: makeTextItem(plainText: text))
            XCTAssertEqual(actual, expected, "metadata mismatch for text: \(String(reflecting: text))")
        }
    }

    @MainActor
    func testPrewarmCachesTitleAndMetadata() async {
        let item = makeTextItem(plainText: "hello world")
        ClipboardItemDisplayText.shared.clearCaches()

        XCTAssertNil(ClipboardItemDisplayText.shared.cachedTitle(for: item))
        XCTAssertNil(ClipboardItemDisplayText.shared.cachedMetadata(for: item))

        let task = ClipboardItemDisplayText.shared.prewarm(items: [item])
        await task?.value

        let cachedTitle = ClipboardItemDisplayText.shared.cachedTitle(for: item)
        let cachedMetadata = ClipboardItemDisplayText.shared.cachedMetadata(for: item)

        XCTAssertEqual(cachedTitle, ClipboardItemDisplayText.shared.title(for: item))
        XCTAssertEqual(cachedMetadata, ClipboardItemDisplayText.shared.metadata(for: item))
    }

    private func makeTextItem(plainText: String) -> ClipboardItemDTO {
        ClipboardItemDTO(
            id: UUID(),
            type: .text,
            contentHash: UUID().uuidString,
            plainText: plainText,
            appBundleID: nil,
            createdAt: Date(),
            lastUsedAt: Date(),
            isPinned: false,
            sizeBytes: plainText.utf8.count,
            thumbnailPath: nil,
            storageRef: nil
        )
    }

    // Reference implementation (pre-optimization) to guard behavior stability.
    private func legacyTextMetadata(_ text: String) -> String {
        let charCount = TextMetrics.displayWordUnitCount(for: text)
        let lineCount = text.components(separatedBy: .newlines).count
        let cleanText = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let lastChars = cleanText.count <= 15 ? cleanText : "...\(String(cleanText.suffix(15)))"
        return "\(charCount)字 · \(lineCount)行 · \(lastChars)"
    }
}
