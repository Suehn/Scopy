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

    func testCancelTaskHelpersClearAndCancelOwnedTasks() {
        let controller = HistoryItemRowController(relativeTimeText: "1m")
        let optimizeTask = makeSleepingTask()
        let exportTask = makeSleepingTask()

        controller.optimizeImageTask = optimizeTask
        controller.exportActionTask = exportTask
        controller.isOptimizingImage = true
        controller.isExportingPNG = true

        controller.cancelOptimizeImageTask()
        controller.cancelExportActionTask()

        XCTAssertNil(controller.optimizeImageTask)
        XCTAssertNil(controller.exportActionTask)
        XCTAssertFalse(controller.isOptimizingImage)
        XCTAssertFalse(controller.isExportingPNG)
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
