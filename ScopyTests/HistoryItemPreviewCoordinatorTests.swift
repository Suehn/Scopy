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

        coordinator.presentPreview(.image)

        XCTAssertNotEqual(coordinator.imagePopoverToken, oldImageToken)
        XCTAssertEqual(coordinator.textPopoverToken, oldTextToken)
        XCTAssertNil(coordinator.hoverPreviewTask)
        XCTAssertNil(coordinator.hoverMarkdownTask)
    }

    func testInvalidatePreviewTokensClearsPreviewIdentity() {
        let coordinator = HistoryItemPreviewCoordinator()
        let imageToken = coordinator.imagePopoverToken
        let textToken = coordinator.textPopoverToken
        let fileToken = coordinator.filePopoverToken
        coordinator.isPopoverHovering = true

        coordinator.invalidatePreviewTokens()

        XCTAssertNotEqual(coordinator.imagePopoverToken, imageToken)
        XCTAssertNotEqual(coordinator.textPopoverToken, textToken)
        XCTAssertNotEqual(coordinator.filePopoverToken, fileToken)
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

    func testDeinitFinishesActiveRowExitIntentExactlyOnce() async throws {
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

        let transferToken = try XCTUnwrap(interactionCoordinator.beginHoverPreviewTransferToken(for: itemID))
        coordinator?.startRowExitIntent(
            from: .zero,
            onDismiss: { },
            onFinish: {
                finishCount += 1
                interactionCoordinator.endHoverPreviewTransfer(token: transferToken)
                finished.fulfill()
            }
        )

        coordinator = nil

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

@MainActor
final class HoverPreviewModelTests: XCTestCase {
    func testCachedMarkdownGeometryDoesNotMakeReusableWebViewLive() async {
        let model = HoverPreviewModel()
        let source = "# Cached preview"
        let document = await PreparedMarkdownDocument.prepare(
            source: source,
            layoutScale: .percent100
        )
        let cachedSize = CGSize(width: 816, height: 420)

        model.primeTextPreview(
            content: .markdown(document),
            markdownContentSize: cachedSize,
            markdownHasHorizontalOverflow: true
        )

        XCTAssertEqual(model.markdownContentSize, cachedSize)
        XCTAssertTrue(model.markdownHasHorizontalOverflow)
        XCTAssertNil(model.markdownMetricsLayoutScalePercent)
        XCTAssertFalse(model.isMarkdownRenderLive(for: document.renderKey))
    }

    func testRenderKeyChangeRestoresShieldUntilCurrentWebViewSucceeds() async {
        let model = HoverPreviewModel()
        let sourceA = "# A"
        let sourceB = "# B"
        let documentA = await PreparedMarkdownDocument.prepare(
            source: sourceA,
            layoutScale: .percent100
        )
        let documentB = await PreparedMarkdownDocument.prepare(
            source: sourceB,
            layoutScale: .percent100
        )

        model.primeTextPreview(content: .markdown(documentA))
        model.markMarkdownRenderSucceeded(for: documentA.renderKey)
        XCTAssertTrue(model.isMarkdownRenderLive(for: documentA.renderKey))

        model.primeTextPreview(
            content: .markdown(documentB),
            markdownContentSize: CGSize(width: 816, height: 180),
            markdownHasHorizontalOverflow: false
        )

        XCTAssertFalse(model.isMarkdownRenderLive(for: documentA.renderKey))
        XCTAssertFalse(model.isMarkdownRenderLive(for: documentB.renderKey))

        model.markMarkdownRenderSucceeded(for: documentB.renderKey)

        XCTAssertTrue(model.isMarkdownRenderLive(for: documentB.renderKey))
        XCTAssertFalse(model.isMarkdownRenderLive(for: documentA.renderKey))
    }

    func testRenderFailureFeedbackIsScopedToCurrentRenderKey() async {
        let model = HoverPreviewModel()
        let documentA = await PreparedMarkdownDocument.prepare(
            source: "A",
            layoutScale: .percent100
        )
        let documentB = await PreparedMarkdownDocument.prepare(
            source: "B",
            layoutScale: .percent125
        )

        model.markMarkdownRenderFailed(for: documentA.renderKey, reason: "A failed")

        XCTAssertEqual(model.markdownRenderErrorReason(for: documentA.renderKey), "A failed")
        XCTAssertNil(model.markdownRenderErrorReason(for: documentB.renderKey))

        model.setMarkdownDocumentAwaitingLiveRender(documentB)

        XCTAssertNil(model.markdownRenderErrorReason(for: documentA.renderKey))
        XCTAssertNil(model.markdownRenderErrorReason(for: documentB.renderKey))
    }
}
