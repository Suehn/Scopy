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

    func testIsLikelyMarkdownDetectsLongReferenceStyleChineseNote() {
        let input = """
        # 笔记：为什么宽基指数长期往往优于大多数主动投资

        **先把结论说准确。**
        更严谨的说法不是“宽基指数在大多数年份都赢主动投资”，而是：**在足够长的持有期里，传统、低成本、宽分散的指数基金，通常会跑赢大多数主动基金。**([投资者.gov][1])

        ## 一、先把概念讲清楚

        这份笔记里，我把“宽基指数”限定为：**跟踪传统、覆盖面较广、分散程度较高的市场指数基金**。

        [1]: https://www.investor.gov/introduction-investing/investing-basics/glossary/index-fund "Index Fund | Investor.gov"
        """

        XCTAssertTrue(MarkdownDetector.isLikelyMarkdown(input))
    }
}
