import XCTest

final class MarkdownSyntaxProtectorTests: XCTestCase {
    func testProtectsAndRestoresMarkdownSyntaxIslands() {
        let input = """
        [T_{io}](/Users/alice/docs/file_v2.md:25) and ![plot](/Users/alice/img(1)_v2.png)
        [paper]: /Users/alice/paper_v2.md:25 "Paper"
        [see paper][paper] <https://example.com/a_(b)?q=x_y> `code_{x}`
        ```md
        [not_a_link](/Users/alice/file_v2.md:25)
        ```
        Bare: https://example.com/a_(b)?q=x_y and /Users/alice/docs/file_v2.md:25
        """

        let protected = MarkdownSyntaxProtector.protectForLooseMathRepair(input)
        let restored = MarkdownSyntaxProtector.restore(protected.markdown, placeholders: protected.placeholders)

        XCTAssertEqual(restored, input)
        XCTAssertFalse(protected.markdown.contains("[T_{io}](/Users/alice/docs/file_v2.md:25)"))
        XCTAssertFalse(protected.markdown.contains("![plot](/Users/alice/img(1)_v2.png)"))
        XCTAssertFalse(protected.markdown.contains("[paper]: /Users/alice/paper_v2.md:25"))
        XCTAssertFalse(protected.markdown.contains("`code_{x}`"))
        XCTAssertFalse(protected.markdown.contains("```md"))
        XCTAssertFalse(protected.markdown.contains("https://example.com/a_(b)?q=x_y"))
        XCTAssertFalse(protected.markdown.contains("/Users/alice/docs/file_v2.md:25"))

        let kinds = protected.placeholders.map { $0.kind }
        XCTAssertTrue(kinds.contains(.inlineLink))
        XCTAssertTrue(kinds.contains(.image))
        XCTAssertTrue(kinds.contains(.referenceDefinition))
        XCTAssertTrue(kinds.contains(.referenceLink))
        XCTAssertTrue(kinds.contains(.autolink))
        XCTAssertTrue(kinds.contains(.inlineCode))
        XCTAssertTrue(kinds.contains(.fencedCode))
        XCTAssertTrue(kinds.contains(.url))
        XCTAssertTrue(kinds.contains(.filePath))
    }

    func testDoesNotProtectStandaloneMathLikeSquareBrackets() {
        let input = "value [T_{io}=12.4] remains available for loose math repair."

        let protected = MarkdownSyntaxProtector.protectForLooseMathRepair(input)

        XCTAssertEqual(protected.markdown, input)
        XCTAssertTrue(protected.placeholders.isEmpty)
    }
}
