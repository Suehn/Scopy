import XCTest

final class MarkdownDetectorTests: XCTestCase {
    func testContainsMathDoesNotTreatMultipleCurrencyDollarsAsMath() {
        XCTAssertFalse(MarkdownDetector.containsMath("Price is $5 and $6."))
        XCTAssertFalse(MarkdownDetector.containsMath("$5 $6 $7"))
        XCTAssertFalse(MarkdownDetector.containsMath("Total: $5\nNext: $6"))
    }

    func testContainsMathDoesNotTreatShellVarsAsMathWhenNoPairs() {
        XCTAssertFalse(MarkdownDetector.containsMath("Use $HOME and $PATH."))
        XCTAssertFalse(MarkdownDetector.containsMath("export FOO=$BAR"))
    }

    func testContainsMathDetectsPairedInlineDollarMath() {
        XCTAssertTrue(MarkdownDetector.containsMath("Inline: $d$-dimensional space."))
        XCTAssertTrue(MarkdownDetector.containsMath("Set: $\\\\mathcal{U}$ and $\\\\mathcal{I}$."))
        XCTAssertTrue(MarkdownDetector.containsMath("Display: $$x^2$$."))
    }

    func testContainsMathIgnoresUnclosedDollar() {
        XCTAssertFalse(MarkdownDetector.containsMath("This is $ not math."))
        XCTAssertFalse(MarkdownDetector.containsMath("Price is $5."))
    }

    func testIsLikelyMarkdownNotTriggeredByCurrencyOnly() {
        XCTAssertFalse(MarkdownDetector.isLikelyMarkdown("Price is $5 and $6."))
    }
}

