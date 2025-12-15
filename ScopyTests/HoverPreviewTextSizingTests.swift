import AppKit
import XCTest

final class HoverPreviewTextSizingTests: XCTestCase {
    func testPreferredWidthShrinksForShortSingleLineText() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let padding: CGFloat = 16
        let maxWidth: CGFloat = 500

        let w = HoverPreviewTextSizing.preferredWidth(
            for: "file_search",
            font: font,
            padding: padding,
            maxWidth: maxWidth
        )
        XCTAssertGreaterThan(w, 0)
        XCTAssertLessThan(w, maxWidth)
    }

    func testPreferredWidthStaysMaxForMultiLineText() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let padding: CGFloat = 16
        let maxWidth: CGFloat = 500

        let w = HoverPreviewTextSizing.preferredWidth(
            for: "a\nb\nc",
            font: font,
            padding: padding,
            maxWidth: maxWidth
        )
        XCTAssertEqual(w, maxWidth)
    }

    func testPreferredTextHeightIncreasesWithNewlines() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let h1 = HoverPreviewTextSizing.preferredTextHeight(
            for: "a",
            font: font,
            contentWidth: 200,
            maxHeight: 1_000
        )
        let h2 = HoverPreviewTextSizing.preferredTextHeight(
            for: "a\nb\nc",
            font: font,
            contentWidth: 200,
            maxHeight: 1_000
        )
        XCTAssertGreaterThan(h2, h1)
    }
}
