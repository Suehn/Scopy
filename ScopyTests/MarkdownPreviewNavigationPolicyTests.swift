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

    func testAllowsSameDocumentFragmentLinkActivation() {
        XCTAssertTrue(
            MarkdownPreviewNavigationPolicy.shouldAllow(
                navigationType: .linkActivated,
                targetFrameIsNil: false,
                url: URL(string: "file:///tmp/test.html#fn1"),
                currentURL: URL(string: "file:///tmp/test.html")
            )
        )
        XCTAssertTrue(
            MarkdownPreviewNavigationPolicy.shouldAllow(
                navigationType: .linkActivated,
                targetFrameIsNil: false,
                url: URL(string: "#fn1"),
                currentURL: URL(string: "file:///tmp/test.html")
            )
        )
    }

    func testCancelsCrossDocumentFragmentLinkActivation() {
        XCTAssertFalse(
            MarkdownPreviewNavigationPolicy.shouldAllow(
                navigationType: .linkActivated,
                targetFrameIsNil: false,
                url: URL(string: "file:///tmp/other.html#fn1"),
                currentURL: URL(string: "file:///tmp/test.html")
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

    func testAllowsFileAndAnchorProgrammaticNavigation() {
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
