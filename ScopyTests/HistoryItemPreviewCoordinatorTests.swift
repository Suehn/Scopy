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
        XCTAssertNil(coordinator.currentPopoverScreenFrame)
    }

    func testPopoverFrameUpdateRequiresCurrentKindToken() {
        let coordinator = HistoryItemPreviewCoordinator()
        let currentToken = coordinator.imagePopoverToken
        let staleToken = UUID()
        let currentFrame = CGRect(x: 100, y: 200, width: 300, height: 240)

        coordinator.updatePopoverScreenFrame(currentFrame, for: .image, token: staleToken)
        XCTAssertNil(coordinator.currentPopoverScreenFrame)

        coordinator.updatePopoverScreenFrame(currentFrame, for: .image, token: currentToken)
        XCTAssertEqual(coordinator.currentPopoverScreenFrame, currentFrame)

        coordinator.updatePopoverScreenFrame(nil, for: .image, token: staleToken)
        XCTAssertEqual(coordinator.currentPopoverScreenFrame, currentFrame)
    }

    func testPresentingNewPreviewClearsPreviousPopoverGeometry() {
        let coordinator = HistoryItemPreviewCoordinator()
        coordinator.updatePopoverScreenFrame(
            CGRect(x: 10, y: 20, width: 30, height: 40),
            for: .text,
            token: coordinator.textPopoverToken
        )

        coordinator.presentPreview(.text)

        XCTAssertNil(coordinator.currentPopoverScreenFrame)
    }

    func testCancellingRowExitIntentRunsFinishExactlyOnce() {
        let coordinator = HistoryItemPreviewCoordinator()
        var finishCount = 0

        coordinator.startRowExitIntent(
            from: .zero,
            onDismiss: { },
            onFinish: { finishCount += 1 }
        )
        XCTAssertTrue(coordinator.isHoverIntentActive)

        coordinator.cancelHoverExitTask()
        coordinator.cancelHoverExitTask()

        XCTAssertFalse(coordinator.isHoverIntentActive)
        XCTAssertEqual(finishCount, 1)
    }

    func testDeinitFinishesActiveRowExitIntentExactlyOnce() async {
        let interactionCoordinator = HistoryListInteractionCoordinator()
        let itemID = UUID()
        let finished = expectation(description: "active row-exit intent finished during teardown")
        var finishCount = 0
        var coordinator: HistoryItemPreviewCoordinator? = HistoryItemPreviewCoordinator(
            hoverIntentController: HoverPreviewIntentController(
                dependencies: .init(
                    cursorLocation: { .zero },
                    uptime: { 0 },
                    sleep: { _ in
                        try await Task.sleep(nanoseconds: 10_000_000_000)
                    }
                )
            )
        )
        weak var weakCoordinator = coordinator

        XCTAssertTrue(interactionCoordinator.beginHoverPreviewTransfer(for: itemID))
        coordinator?.startRowExitIntent(
            from: .zero,
            onDismiss: { },
            onFinish: {
                finishCount += 1
                interactionCoordinator.endHoverPreviewTransfer(for: itemID)
                finished.fulfill()
            }
        )

        coordinator = nil

        XCTAssertNil(weakCoordinator)
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertNil(interactionCoordinator.hoverPreviewTransferOwnerID)
        XCTAssertEqual(finishCount, 1)
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
