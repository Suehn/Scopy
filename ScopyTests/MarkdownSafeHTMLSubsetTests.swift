import XCTest

@testable import Scopy

final class MarkdownSafeHTMLSubsetTests: XCTestCase {
    func testExtractRemovesCommentsAndRestoresInlineSafeTags() {
        let input = "Text <u>under</u> and <kbd>Cmd</kbd>. <!-- hidden -->"

        let result = MarkdownSafeHTMLSubset.extract(from: input)

        XCTAssertFalse(result.markdown.contains("<!--"))
        XCTAssertTrue(result.markdown.contains("SCOPYSAFEHTMLPLACEHOLDER"))
        XCTAssertEqual(result.fallbackMarkdown, "Text under and Cmd. ")
        XCTAssertEqual(result.replacements.count, 2)
    }

    func testExtractHandlesDetailsAndDefinitionBodyMarkdown() throws {
        let input = """
<details open>
<summary>点击展开</summary>

- 列表
- **强调**

</details>
"""

        let result = MarkdownSafeHTMLSubset.extract(from: input)
        let token = try XCTUnwrap(result.replacements.keys.first)
        let replacement = try XCTUnwrap(result.replacements[token])

        XCTAssertEqual(replacement.kind, "details")
        XCTAssertEqual(replacement.isOpen, true)
        XCTAssertEqual(replacement.summary, "点击展开")
        XCTAssertTrue(replacement.body?.contains("- **强调**") == true)
        XCTAssertTrue(result.markdown.contains(token))
        XCTAssertTrue(result.fallbackMarkdown.contains("点击展开"))
        XCTAssertTrue(result.fallbackMarkdown.contains("**强调**"))
    }

    func testExtractDoesNotRewriteHTMLInsideFencedCodeBlocks() {
        let input = """
<u>outside</u>

```
<u>inside fence</u>
```
"""

        let result = MarkdownSafeHTMLSubset.extract(from: input)

        XCTAssertTrue(result.markdown.contains("<u>inside fence</u>"))
        XCTAssertTrue(result.fallbackMarkdown.contains("<u>inside fence</u>"))
        XCTAssertEqual(result.replacements.count, 1)
    }
}
