import XCTest

@testable import Scopy

@MainActor
final class HistoryItemPreviewCoordinatorTests: XCTestCase {
    func testPresentPreviewRefreshesTokenAndClearsOwnedTasks() {
        let coordinator = HistoryItemPreviewCoordinator()
        let oldImageToken = coordinator.imagePopoverToken
        let oldTextToken = coordinator.textPopoverToken
        coordinator.hoverPreviewTask = makeSleepingTask()
        coordinator.hoverMarkdownTask = makeSleepingTask()
        coordinator.markdownFilePreviewCacheKey = "stale"

        coordinator.presentPreview(.image)

        XCTAssertNotEqual(coordinator.imagePopoverToken, oldImageToken)
        XCTAssertEqual(coordinator.textPopoverToken, oldTextToken)
        XCTAssertNil(coordinator.hoverPreviewTask)
        XCTAssertNil(coordinator.hoverMarkdownTask)
        XCTAssertNil(coordinator.markdownFilePreviewCacheKey)
    }

    func testInvalidatePreviewTokensClearsPreviewIdentity() {
        let coordinator = HistoryItemPreviewCoordinator()
        let imageToken = coordinator.imagePopoverToken
        let textToken = coordinator.textPopoverToken
        let fileToken = coordinator.filePopoverToken
        coordinator.markdownFilePreviewCacheKey = "cache-key"
        coordinator.isPopoverHovering = true

        coordinator.invalidatePreviewTokens()

        XCTAssertNotEqual(coordinator.imagePopoverToken, imageToken)
        XCTAssertNotEqual(coordinator.textPopoverToken, textToken)
        XCTAssertNotEqual(coordinator.filePopoverToken, fileToken)
        XCTAssertNil(coordinator.markdownFilePreviewCacheKey)
        XCTAssertFalse(coordinator.isPopoverHovering)
    }

    func testHandlePopoverHoverCoordinatesExitScheduling() {
        let coordinator = HistoryItemPreviewCoordinator()
        var cancelled = false
        var scheduled = false

        coordinator.handlePopoverHover(
            true,
            isRowHovering: false,
            cancelHoverExit: { cancelled = true },
            scheduleHoverExit: { scheduled = true }
        )
        XCTAssertTrue(coordinator.isPopoverHovering)
        XCTAssertTrue(cancelled)
        XCTAssertFalse(scheduled)

        cancelled = false
        scheduled = false
        coordinator.handlePopoverHover(
            false,
            isRowHovering: false,
            cancelHoverExit: { cancelled = true },
            scheduleHoverExit: { scheduled = true }
        )
        XCTAssertFalse(coordinator.isPopoverHovering)
        XCTAssertFalse(cancelled)
        XCTAssertTrue(scheduled)
    }

    func testCancelTaskHelpersClearAndCancelOwnedTasks() {
        let coordinator = HistoryItemPreviewCoordinator()
        let hoverDebounce = makeSleepingTask()
        let hoverExit = makeSleepingTask()
        let hoverPreview = makeSleepingTask()
        let hoverMarkdown = makeSleepingTask()

        coordinator.hoverDebounceTask = hoverDebounce
        coordinator.hoverExitTask = hoverExit
        coordinator.hoverPreviewTask = hoverPreview
        coordinator.hoverMarkdownTask = hoverMarkdown

        coordinator.cancelHoverTasks()
        coordinator.cancelPreviewTasks()

        XCTAssertNil(coordinator.hoverDebounceTask)
        XCTAssertNil(coordinator.hoverExitTask)
        XCTAssertNil(coordinator.hoverPreviewTask)
        XCTAssertNil(coordinator.hoverMarkdownTask)
        XCTAssertTrue(hoverDebounce.isCancelled)
        XCTAssertTrue(hoverExit.isCancelled)
        XCTAssertTrue(hoverPreview.isCancelled)
        XCTAssertTrue(hoverMarkdown.isCancelled)
    }

    private func makeSleepingTask() -> Task<Void, Never> {
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                return
            }
        }
    }
}
