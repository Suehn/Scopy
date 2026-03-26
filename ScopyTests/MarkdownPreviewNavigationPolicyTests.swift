import XCTest
import WebKit

@testable import Scopy

final class MarkdownPreviewNavigationPolicyTests: XCTestCase {
    func testCancelsTargetlessNavigation() {
        XCTAssertFalse(
            MarkdownPreviewNavigationPolicy.shouldAllow(
                navigationType: .other,
                targetFrameIsNil: true,
                url: URL(string: "file:///tmp/test.html")
            )
        )
    }

    func testCancelsLinkActivatedNavigation() {
        XCTAssertFalse(
            MarkdownPreviewNavigationPolicy.shouldAllow(
                navigationType: .linkActivated,
                targetFrameIsNil: false,
                url: URL(string: "file:///tmp/test.html")
            )
        )
    }

    func testCancelsHTTPAndHTTPSNavigation() {
        XCTAssertFalse(
            MarkdownPreviewNavigationPolicy.shouldAllow(
                navigationType: .other,
                targetFrameIsNil: false,
                url: URL(string: "https://example.com")
            )
        )
        XCTAssertFalse(
            MarkdownPreviewNavigationPolicy.shouldAllow(
                navigationType: .other,
                targetFrameIsNil: false,
                url: URL(string: "http://example.com")
            )
        )
    }

    func testAllowsFileAndAnchorNavigation() {
        XCTAssertTrue(
            MarkdownPreviewNavigationPolicy.shouldAllow(
                navigationType: .other,
                targetFrameIsNil: false,
                url: URL(string: "file:///tmp/test.html")
            )
        )
        XCTAssertTrue(
            MarkdownPreviewNavigationPolicy.shouldAllow(
                navigationType: .other,
                targetFrameIsNil: false,
                url: URL(string: "file:///tmp/test.html#fn1")
            )
        )
    }
}
