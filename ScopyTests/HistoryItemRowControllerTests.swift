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

    func testExportAuthorizationRequiresExactLiveTokenAndIsInvalidatedByCancellation() throws {
        let controller = HistoryItemRowController(relativeTimeText: "1m")
        XCTAssertTrue(controller.beginExportingPNG())
        let firstToken = try XCTUnwrap(controller.exportAuthorizationToken)
        controller.exportActionTask = makeSleepingTask()
        XCTAssertTrue(controller.authorizesExport(token: firstToken))

        controller.cancelExportActionTask()
        XCTAssertFalse(controller.authorizesExport(token: firstToken))
        XCTAssertNil(controller.exportAuthorizationToken)

        XCTAssertTrue(controller.beginExportingPNG())
        let replacementToken = try XCTUnwrap(controller.exportAuthorizationToken)
        controller.exportActionTask = makeSleepingTask()
        XCTAssertNotEqual(replacementToken, firstToken)
        XCTAssertFalse(controller.finishExportingPNG(message: "stale", token: firstToken))
        XCTAssertTrue(controller.authorizesExport(token: replacementToken))
        XCTAssertTrue(controller.finishExportingPNG(message: "PNG copied", token: replacementToken))
        XCTAssertEqual(controller.exportMessage, "PNG copied")
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

    func testSuccessfulNoteSaveDismissesOnlyTheUnchangedDraft() throws {
        let controller = HistoryItemRowController(relativeTimeText: "1m")
        controller.presentNoteEditor(note: "draft")
        let request = try XCTUnwrap(controller.beginNoteSave())
        let task = makeSleepingTask()
        XCTAssertTrue(controller.installNoteSaveTask(task, token: request.token))

        XCTAssertEqual(
            controller.finishNoteSave(succeeded: true, request: request),
            .savedAndDismissed
        )
        XCTAssertFalse(controller.isNoteEditorPresented)
        XCTAssertFalse(controller.isSavingNote)
        XCTAssertTrue(controller.noteDraft.isEmpty)
        XCTAssertNil(controller.noteSaveError)
    }

    func testFailedNoteSaveKeepsEditorAndDraftForRetry() throws {
        let controller = HistoryItemRowController(relativeTimeText: "1m")
        controller.presentNoteEditor(note: "important draft")
        let request = try XCTUnwrap(controller.beginNoteSave())

        XCTAssertEqual(
            controller.finishNoteSave(succeeded: false, request: request),
            .failed
        )
        XCTAssertTrue(controller.isNoteEditorPresented)
        XCTAssertFalse(controller.isSavingNote)
        XCTAssertEqual(controller.noteDraft, "important draft")
        XCTAssertNotNil(controller.noteSaveError)
    }

    func testSuccessfulOldSaveCannotClearDraftEditedWhileRequestWasInFlight() throws {
        let controller = HistoryItemRowController(relativeTimeText: "1m")
        controller.presentNoteEditor(note: "first")
        let request = try XCTUnwrap(controller.beginNoteSave())

        controller.noteDraft = "newer unsaved draft"

        XCTAssertEqual(
            controller.finishNoteSave(succeeded: true, request: request),
            .savedWithNewerDraft
        )
        XCTAssertTrue(controller.isNoteEditorPresented)
        XCTAssertEqual(controller.noteDraft, "newer unsaved draft")
        XCTAssertFalse(controller.isSavingNote)
    }

    func testCancelledOldSaveCannotClearDraftFromReopenedEditor() throws {
        let controller = HistoryItemRowController(relativeTimeText: "1m")
        controller.presentNoteEditor(note: "first")
        let oldRequest = try XCTUnwrap(controller.beginNoteSave())

        controller.dismissNoteEditor(discardDraft: true)
        controller.presentNoteEditor(note: "replacement")
        let replacementRequest = try XCTUnwrap(controller.beginNoteSave())

        XCTAssertEqual(
            controller.finishNoteSave(succeeded: true, request: oldRequest),
            .stale
        )
        XCTAssertTrue(controller.isNoteEditorPresented)
        XCTAssertEqual(controller.noteDraft, "replacement")
        XCTAssertTrue(controller.authorizesNoteSave(token: replacementRequest.token))
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
