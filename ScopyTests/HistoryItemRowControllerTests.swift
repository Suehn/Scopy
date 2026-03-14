import XCTest

@testable import Scopy

@MainActor
final class HistoryItemRowControllerTests: XCTestCase {
    func testBeginAndFinishExportingPNGUpdateState() {
        let controller = HistoryItemRowController(relativeTimeText: "1m")
        controller.exportMessage = "old"
        controller.exportActionTask = makeSleepingTask()

        XCTAssertTrue(controller.beginExportingPNG())
        XCTAssertTrue(controller.isExportingPNG)
        XCTAssertNil(controller.exportMessage)
        XCTAssertFalse(controller.beginExportingPNG())

        controller.finishExportingPNG(message: "PNG copied")

        XCTAssertFalse(controller.isExportingPNG)
        XCTAssertNil(controller.exportActionTask)
        XCTAssertEqual(controller.exportMessage, "PNG copied")
    }

    func testClearExportFeedbackClearsMessageAndCancelsResetTask() {
        let controller = HistoryItemRowController(relativeTimeText: "1m")
        controller.exportMessage = "PNG copied"
        let task = makeSleepingTask()
        controller.exportMessageTask = task

        controller.clearExportFeedback()

        XCTAssertNil(controller.exportMessage)
        XCTAssertNil(controller.exportMessageTask)
        XCTAssertTrue(task.isCancelled)
    }

    func testPresentDismissAndNormalizeNoteDraft() {
        let controller = HistoryItemRowController(relativeTimeText: "1m")

        controller.presentNoteEditor(note: "  hello world  ")
        XCTAssertTrue(controller.isNoteEditorPresented)
        XCTAssertEqual(controller.noteDraft, "  hello world  ")

        controller.noteDraft = "   "
        XCTAssertNil(controller.normalizedNoteDraft())

        controller.noteDraft = "  updated note  "
        XCTAssertEqual(controller.normalizedNoteDraft(), "updated note")

        controller.dismissNoteEditor()
        XCTAssertFalse(controller.isNoteEditorPresented)
    }

    func testInvalidatePreviewTokensClearsPreviewIdentity() {
        let controller = HistoryItemRowController(relativeTimeText: "1m")
        let imageToken = controller.imagePopoverToken
        let textToken = controller.textPopoverToken
        let fileToken = controller.filePopoverToken
        controller.markdownFilePreviewCacheKey = "cache-key"
        controller.isPopoverHovering = true

        controller.invalidatePreviewTokens()

        XCTAssertNotEqual(controller.imagePopoverToken, imageToken)
        XCTAssertNotEqual(controller.textPopoverToken, textToken)
        XCTAssertNotEqual(controller.filePopoverToken, fileToken)
        XCTAssertNil(controller.markdownFilePreviewCacheKey)
        XCTAssertFalse(controller.isPopoverHovering)
    }

    func testCancelTaskHelpersClearAndCancelOwnedTasks() {
        let controller = HistoryItemRowController(relativeTimeText: "1m")
        let hoverDebounce = makeSleepingTask()
        let hoverExit = makeSleepingTask()
        let hoverPreview = makeSleepingTask()
        let hoverMarkdown = makeSleepingTask()
        let optimizeTask = makeSleepingTask()
        let exportTask = makeSleepingTask()

        controller.hoverDebounceTask = hoverDebounce
        controller.hoverExitTask = hoverExit
        controller.hoverPreviewTask = hoverPreview
        controller.hoverMarkdownTask = hoverMarkdown
        controller.optimizeImageTask = optimizeTask
        controller.exportActionTask = exportTask
        controller.isOptimizingImage = true
        controller.isExportingPNG = true

        controller.cancelHoverTasks()
        controller.cancelPreviewTasks()
        controller.cancelOptimizeImageTask()
        controller.cancelExportActionTask()

        XCTAssertNil(controller.hoverDebounceTask)
        XCTAssertNil(controller.hoverExitTask)
        XCTAssertNil(controller.hoverPreviewTask)
        XCTAssertNil(controller.hoverMarkdownTask)
        XCTAssertNil(controller.optimizeImageTask)
        XCTAssertNil(controller.exportActionTask)
        XCTAssertFalse(controller.isOptimizingImage)
        XCTAssertFalse(controller.isExportingPNG)
        XCTAssertTrue(hoverDebounce.isCancelled)
        XCTAssertTrue(hoverExit.isCancelled)
        XCTAssertTrue(hoverPreview.isCancelled)
        XCTAssertTrue(hoverMarkdown.isCancelled)
        XCTAssertTrue(optimizeTask.isCancelled)
        XCTAssertTrue(exportTask.isCancelled)
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
