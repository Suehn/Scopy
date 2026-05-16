import XCTest

final class MarkdownSourceProfileDetectorTests: XCTestCase {
    func testDetectsLatexDocumentLikeSource() {
        let input = """
        \\documentclass{article}
        \\begin{document}
        \\section{Intro}
        \\end{document}
        """

        XCTAssertEqual(MarkdownSourceProfileDetector.detect(input), .latexDocumentLike)
    }

    func testDetectsChatGPTMarkdownWithLocalFileLinks() {
        let input = """
        这个 repo 的说明在 [docs/ref.md](/Users/alice/code/project/docs/ref.md:25)。
        ```swift
        print("ok")
        ```
        """

        XCTAssertEqual(MarkdownSourceProfileDetector.detect(input), .chatGPTMarkdown)
    }

    func testDetectsAuthoredMarkdown() {
        let input = """
        # Title

        - item
        - [link](https://example.com)
        """

        XCTAssertEqual(MarkdownSourceProfileDetector.detect(input), .authoredMarkdown)
    }

    func testDetectsAuthoredMarkdownWithSafeHTMLIslandsBeforeRichHTML() {
        let input = """
        # Title

        行内 HTML：<kbd>Cmd</kbd> + <mark>K</mark>

        <details>
        <summary>More</summary>

        - item
        - **bold**

        </details>
        """

        XCTAssertEqual(MarkdownSourceProfileDetector.detect(input), .authoredMarkdown)
    }

    func testDetectsLongReferenceStyleChineseNoteAsAuthoredMarkdown() {
        let input = """
        # 笔记：为什么宽基指数长期往往优于大多数主动投资

        **先把结论说准确。**
        更严谨的说法不是“宽基指数在大多数年份都赢主动投资”，而是：**在足够长的持有期里，传统、低成本、宽分散的指数基金，通常会跑赢大多数主动基金。**([投资者.gov][1])

        ## 一、先把概念讲清楚

        [1]: https://www.investor.gov/introduction-investing/investing-basics/glossary/index-fund "Index Fund | Investor.gov"
        """

        XCTAssertEqual(MarkdownSourceProfileDetector.detect(input), .authoredMarkdown)
    }

    func testDetectsRichHTML() {
        let input = """
        <details open>
        <summary>More</summary>
        body
        </details>
        """

        XCTAssertEqual(MarkdownSourceProfileDetector.detect(input), .richHTML)
    }

    func testKeepsHTMLContainerWithOnlyNestedMarkdownOnRichHTMLPath() {
        let input = """
        <details>
        <summary>More</summary>

        - item
        - **bold**

        </details>
        """

        XCTAssertEqual(MarkdownSourceProfileDetector.detect(input), .richHTML)
    }

    func testKeepsNonSafeRawHTMLWithMarkdownOnRichHTMLPath() {
        let input = """
        # Title

        <div>
        - item
        </div>

        ```swift
        print("ok")
        ```
        """

        XCTAssertEqual(MarkdownSourceProfileDetector.detect(input), .richHTML)
    }

    func testDetectsPDFOCRScientificSource() {
        let input = """
        J\\left(x\\right)=\\frac{1}{2}
        alpha_{1}=0.3
        beta_{2}=0.7
        gamma_{3}=1.0
        """

        XCTAssertEqual(MarkdownSourceProfileDetector.detect(input), .pdfOCRScientific)
    }
}
