import XCTest

@testable import Scopy

final class HoverPreviewLivenessPolicyTests: XCTestCase {
    func testMarkdownRenderStaysCurrentWhenRowHoverTransfersToPresentedPopover() {
        XCTAssertTrue(
            HoverPreviewLivenessPolicy.isMarkdownRenderCurrent(
                isTaskCancelled: false,
                isPreviewInteractionSuppressed: false,
                isRowHovering: false,
                isPopoverHovering: false,
                isTextPreviewPresented: false,
                isFilePreviewPresented: true,
                sourceMatchesPreviewText: true
            )
        )
    }

    func testNonMarkdownPreviewDoesNotStayCurrentAfterRowHoverEnds() {
        XCTAssertFalse(
            HoverPreviewLivenessPolicy.isRequestCurrent(
                isTaskCancelled: false,
                isPreviewInteractionSuppressed: false,
                isRowHovering: false,
                isPopoverHovering: false,
                isTextPreviewPresented: false,
                isFilePreviewPresented: true,
                allowPresentedPopover: false
            )
        )
    }

    func testMarkdownRenderRequiresMatchingPreviewText() {
        XCTAssertFalse(
            HoverPreviewLivenessPolicy.isMarkdownRenderCurrent(
                isTaskCancelled: false,
                isPreviewInteractionSuppressed: false,
                isRowHovering: false,
                isPopoverHovering: true,
                isTextPreviewPresented: true,
                isFilePreviewPresented: false,
                sourceMatchesPreviewText: false
            )
        )
    }
}
