import XCTest

final class MarkdownTableCodeSpanPipeNormalizerTests: XCTestCase {
    func testEscapesUnescapedPipesInsideTableCodeSpans() {
        let markdown = """
        | Example | Notes |
        | --- | --- |
        | `| A | B |` | ok |
        | `A | B` | ok |
        """

        let normalized = MarkdownTableCodeSpanPipeNormalizer.normalize(markdown)

        XCTAssertTrue(normalized.contains("| `\\| A \\| B \\|` | ok |"))
        XCTAssertTrue(normalized.contains("| `A \\| B` | ok |"))
    }

    func testLeavesEscapedCodeSpanPipesAndNonTableParagraphsAlone() {
        let markdown = """
        Paragraph `A | B` should stay literal.

        | Example | Notes |
        | --- | --- |
        | `A \\| B` | ok |
        """

        let normalized = MarkdownTableCodeSpanPipeNormalizer.normalize(markdown)

        XCTAssertTrue(normalized.contains("Paragraph `A | B` should stay literal."))
        XCTAssertTrue(normalized.contains("| `A \\| B` | ok |"))
    }

    func testSkipsFencedCodeBlocks() {
        let markdown = """
        ```md
        | Example | Notes |
        | --- | --- |
        | `| A | B |` | ok |
        ```
        """

        XCTAssertEqual(MarkdownTableCodeSpanPipeNormalizer.normalize(markdown), markdown)
    }

    func testLeavesLiteralFenceMarkersInTableCellsAsDelimitableText() {
        let markdown = """
        | 模块 | 示例 1 | 示例 2 | 推荐 |
        | --- | --- | --- | --- |
        | 代码块 | ```python | ```bash | 高 |
        """

        XCTAssertEqual(MarkdownTableCodeSpanPipeNormalizer.normalize(markdown), markdown)
    }
}
