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

    func testDetectsRichHTML() {
        let input = """
        <details open>
        <summary>More</summary>
        body
        </details>
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
