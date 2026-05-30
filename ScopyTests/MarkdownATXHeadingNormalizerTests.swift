import XCTest

final class MarkdownATXHeadingNormalizerTests: XCTestCase {
    func testNormalizesHeadingMarkersWithoutTouchingCode() {
        let markdown = """
        #一级标题 `# H1`
        ##二级标题
        #! /usr/bin/env bash

            #indented code

        ```markdown
        ###fenced code
        ```
        """

        let normalized = MarkdownATXHeadingNormalizer.normalize(markdown)

        XCTAssertTrue(normalized.contains("# 一级标题 `# H1`"))
        XCTAssertTrue(normalized.contains("## 二级标题"))
        XCTAssertTrue(normalized.contains("#! /usr/bin/env bash"))
        XCTAssertTrue(normalized.contains("    #indented code"))
        XCTAssertTrue(normalized.contains("###fenced code"))
        XCTAssertFalse(normalized.contains("#一级标题"))
        XCTAssertFalse(normalized.contains("##二级标题"))
    }

    func testLeavesAlreadyConformingHeadingsUnchanged() {
        let markdown = """
        # 一级标题
        ## 二级标题
        ### 三级标题
        """

        XCTAssertEqual(MarkdownATXHeadingNormalizer.normalize(markdown), markdown)
    }
}
