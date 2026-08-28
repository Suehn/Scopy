import XCTest
import WebKit

@testable import Scopy

final class MarkdownPreviewNavigationPolicyTests: XCTestCase {
    func testCancelsTargetlessNavigation() {
        XCTAssertEqual(
            MarkdownPreviewNavigationPolicy.decision(
                navigationType: .other,
                targetFrameIsNil: true,
                url: URL(string: "file:///tmp/test.html")
            ),
            .cancel
        )
    }

    func testCancelsLinkActivatedNavigation() {
        XCTAssertEqual(
            MarkdownPreviewNavigationPolicy.decision(
                navigationType: .linkActivated,
                targetFrameIsNil: false,
                url: URL(string: "file:///tmp/test.html")
            ),
            .cancel
        )
    }

    func testAllowsSameDocumentFragmentLinkActivation() {
        XCTAssertEqual(
            MarkdownPreviewNavigationPolicy.decision(
                navigationType: .linkActivated,
                targetFrameIsNil: false,
                url: URL(string: "file:///tmp/test.html#fn1"),
                currentURL: URL(string: "file:///tmp/test.html")
            ),
            .allowInWebView
        )
        XCTAssertEqual(
            MarkdownPreviewNavigationPolicy.decision(
                navigationType: .linkActivated,
                targetFrameIsNil: true,
                url: URL(string: "#fn1"),
                currentURL: URL(string: "file:///tmp/test.html")
            ),
            .allowInWebView
        )
    }

    func testCancelsCrossDocumentFragmentLinkActivation() {
        XCTAssertEqual(
            MarkdownPreviewNavigationPolicy.decision(
                navigationType: .linkActivated,
                targetFrameIsNil: false,
                url: URL(string: "file:///tmp/other.html#fn1"),
                currentURL: URL(string: "file:///tmp/test.html")
            ),
            .cancel
        )
    }

    func testOpensUserActivatedHTTPAndHTTPSLinksExternally() {
        let httpsURL = URL(string: "https://example.com/path?q=value#fragment")!
        let httpURL = URL(string: "http://example.com")!

        XCTAssertEqual(
            MarkdownPreviewNavigationPolicy.decision(
                navigationType: .linkActivated,
                targetFrameIsNil: false,
                url: httpsURL
            ),
            .openExternally(httpsURL)
        )
        XCTAssertEqual(
            MarkdownPreviewNavigationPolicy.decision(
                navigationType: .linkActivated,
                targetFrameIsNil: true,
                url: httpURL
            ),
            .openExternally(httpURL)
        )
    }

    func testOpensUserActivatedScopyFileLinksAsFileURLs() {
        let path = "/Users/hh/Documents/code/Scopy/README.md"
        let expectedURL = URL(fileURLWithPath: path).standardizedFileURL

        XCTAssertEqual(
            MarkdownPreviewNavigationPolicy.decision(
                navigationType: .linkActivated,
                targetFrameIsNil: false,
                url: URL(string: "scopy-file:\(path)")
            ),
            .openExternally(expectedURL)
        )
        XCTAssertEqual(
            MarkdownPreviewNavigationPolicy.decision(
                navigationType: .linkActivated,
                targetFrameIsNil: true,
                url: URL(string: "scopy-file:/Users/hh/My%20File.md")
            ),
            .openExternally(URL(fileURLWithPath: "/Users/hh/My File.md").standardizedFileURL)
        )
    }

    func testExpandsCurrentUserHomeInScopyFileLinks() {
        let expectedURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/note.md")
            .standardizedFileURL

        XCTAssertEqual(
            MarkdownPreviewNavigationPolicy.decision(
                navigationType: .linkActivated,
                targetFrameIsNil: false,
                url: URL(string: "scopy-file:/~/Documents/note.md")
            ),
            .openExternally(expectedURL)
        )
    }

    func testStripsTextPositionFromScopyFileLinks() {
        let expectedURL = URL(fileURLWithPath: "/tmp/example.swift").standardizedFileURL

        for rawURL in [
            "scopy-file:/tmp/example.swift:42",
            "scopy-file:/tmp/example.swift:42:7"
        ] {
            XCTAssertEqual(
                MarkdownPreviewNavigationPolicy.decision(
                    navigationType: .linkActivated,
                    targetFrameIsNil: false,
                    url: URL(string: rawURL)
                ),
                .openExternally(expectedURL),
                rawURL
            )
        }
    }

    func testCancelsProgrammaticScopyFileNavigation() {
        XCTAssertEqual(
            MarkdownPreviewNavigationPolicy.decision(
                navigationType: .other,
                targetFrameIsNil: false,
                url: URL(string: "scopy-file:/tmp/example.swift:42:7")
            ),
            .cancel
        )
    }

    func testRejectsUnsafeScopyFileLinks() {
        for rawURL in [
            "scopy-file:relative/path.md",
            "scopy-file://server.example/path.md",
            "scopy-file:///tmp/path.md",
            "scopy-file:////server/share/path.md",
            "scopy-file:/tmp/line%0Abreak.md",
            "scopy-file:/tmp/tab%09separated.md",
            "scopy-file:/tmp/null%00byte.md",
            "scopy-file:/tmp/path.md?query",
            "scopy-file:/tmp/path.md#fragment"
        ] {
            XCTAssertEqual(
                MarkdownPreviewNavigationPolicy.decision(
                    navigationType: .linkActivated,
                    targetFrameIsNil: false,
                    url: URL(string: rawURL)
                ),
                .cancel,
                rawURL
            )
        }
    }

    func testCancelsProgrammaticHTTPAndHTTPSNavigation() {
        XCTAssertEqual(
            MarkdownPreviewNavigationPolicy.decision(
                navigationType: .other,
                targetFrameIsNil: false,
                url: URL(string: "https://example.com")
            ),
            .cancel
        )
        XCTAssertEqual(
            MarkdownPreviewNavigationPolicy.decision(
                navigationType: .other,
                targetFrameIsNil: true,
                url: URL(string: "http://example.com")
            ),
            .cancel
        )
    }

    func testAllowsFileAndAnchorProgrammaticNavigation() {
        XCTAssertEqual(
            MarkdownPreviewNavigationPolicy.decision(
                navigationType: .other,
                targetFrameIsNil: false,
                url: URL(string: "file:///tmp/test.html")
            ),
            .allowInWebView
        )
        XCTAssertEqual(
            MarkdownPreviewNavigationPolicy.decision(
                navigationType: .other,
                targetFrameIsNil: false,
                url: URL(string: "file:///tmp/test.html#fn1")
            ),
            .allowInWebView
        )
        XCTAssertEqual(
            MarkdownPreviewNavigationPolicy.decision(
                navigationType: .other,
                targetFrameIsNil: false,
                url: URL(string: "about:blank")
            ),
            .allowInWebView
        )
    }

    func testCancelsUnknownOrExecutableProgrammaticNavigation() {
        for rawURL in [
            "plugin:example",
            "data:text/plain,hello",
            "javascript:alert(1)",
            "ftp://example.com/file"
        ] {
            XCTAssertEqual(
                MarkdownPreviewNavigationPolicy.decision(
                    navigationType: .other,
                    targetFrameIsNil: false,
                    url: URL(string: rawURL)
                ),
                .cancel,
                rawURL
            )
        }
        XCTAssertEqual(
            MarkdownPreviewNavigationPolicy.decision(
                navigationType: .other,
                targetFrameIsNil: false,
                url: nil
            ),
            .cancel
        )
    }

    func testCancelsUnsupportedLinkSchemes() {
        for rawURL in [
            "plugin:example",
            "file:///tmp/test.html",
            "data:text/plain,hello",
            "javascript:alert(1)"
        ] {
            XCTAssertEqual(
                MarkdownPreviewNavigationPolicy.decision(
                    navigationType: .linkActivated,
                    targetFrameIsNil: true,
                    url: URL(string: rawURL)
                ),
                .cancel,
                rawURL
            )
        }
    }

    func testRejectsExternalURLsWithoutHostOrWithCredentials() {
        for rawURL in [
            "https:///missing-host",
            "https://user@example.com",
            "https://user:password@example.com",
            "https://@example.com"
        ] {
            XCTAssertEqual(
                MarkdownPreviewNavigationPolicy.decision(
                    navigationType: .linkActivated,
                    targetFrameIsNil: false,
                    url: URL(string: rawURL)
                ),
                .cancel,
                rawURL
            )
        }
    }

    func testRejectsPlaceholderURLThatSwallowsFollowingCJKProse() {
        let rawURL = "https://...%EF%BC%8C%E8%80%8C%E6%98%AF%E8%BF%99%E6%AC%A1%E4%BC%9A%E8%AF%9D%E6%B2%99%E7%AE%B1%E9%87%8C%E7%94%9F%E6%88%90%E7%9A%84%E9%99%84%E4%BB%B6%E3%80%82"

        XCTAssertEqual(
            MarkdownPreviewNavigationPolicy.decision(
                navigationType: .linkActivated,
                targetFrameIsNil: false,
                url: URL(string: rawURL)
            ),
            .cancel
        )
    }

    func testRejectsExternalURLsWithPercentEncodedControlCharacters() {
        for rawURL in [
            "https://example.com/line%0Abreak",
            "https://example.com/tab%09separated",
            "https://example.com/null%00byte"
        ] {
            XCTAssertEqual(
                MarkdownPreviewNavigationPolicy.decision(
                    navigationType: .linkActivated,
                    targetFrameIsNil: false,
                    url: URL(string: rawURL)
                ),
                .cancel,
                rawURL
            )
        }
    }

    func testExternalURLLengthLimitIsInclusive() {
        let prefix = "https://example.com/"
        let maximumURL = URL(
            string: prefix + String(repeating: "a", count: 8_192 - prefix.utf8.count)
        )!
        let oversizedURL = URL(
            string: prefix + String(repeating: "a", count: 8_193 - prefix.utf8.count)
        )!

        XCTAssertEqual(
            MarkdownPreviewNavigationPolicy.decision(
                navigationType: .linkActivated,
                targetFrameIsNil: false,
                url: maximumURL
            ),
            .openExternally(maximumURL)
        )
        XCTAssertEqual(
            MarkdownPreviewNavigationPolicy.decision(
                navigationType: .linkActivated,
                targetFrameIsNil: false,
                url: oversizedURL
            ),
            .cancel
        )
    }
}
