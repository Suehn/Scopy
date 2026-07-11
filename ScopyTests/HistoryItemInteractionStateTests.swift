import Foundation
import ScopyKit
import XCTest

@testable import Scopy

@MainActor
final class HistoryItemInteractionStateTests: XCTestCase {
    func testRevisionChangeInvalidatesContentOwnedStateButPreservesItemOwnedNoteSave() throws {
        let id = UUID()
        let original = revision(id: id, hash: "old", text: "old text", sizeBytes: 8)
        let replacement = revision(id: id, hash: "new", text: "new text", sizeBytes: 8)
        let state = HistoryItemInteractionState(revision: original, relativeTimeText: "now")

        let previewTask = sleepingTask()
        let markdownTask = sleepingTask()
        let exportTask = sleepingTask()
        state.previewCoordinator.hoverPreviewTask = previewTask
        state.previewCoordinator.hoverMarkdownTask = markdownTask
        state.previewCoordinator.isHovering = true
        state.previewModel.text = "old text"
        state.previewModel.markdownHTML = "<p>old</p>"
        state.rowController.presentNoteEditor(note: "draft")
        let noteSaveRequest = try XCTUnwrap(state.rowController.beginNoteSave())
        let noteSaveTask = sleepingTask()
        XCTAssertTrue(
            state.rowController.installNoteSaveTask(
                noteSaveTask,
                token: noteSaveRequest.token
            )
        )
        state.rowController.exportActionTask = exportTask
        state.rowController.isExportingPNG = true

        XCTAssertTrue(state.reconcile(to: replacement, relativeTimeText: "1m"))

        XCTAssertEqual(state.revision, replacement)
        XCTAssertEqual(state.rowController.relativeTimeText, "1m")
        XCTAssertFalse(state.previewCoordinator.isHovering)
        XCTAssertNil(state.previewCoordinator.hoverPreviewTask)
        XCTAssertNil(state.previewCoordinator.hoverMarkdownTask)
        XCTAssertNil(state.previewModel.text)
        XCTAssertNil(state.previewModel.markdownHTML)
        XCTAssertTrue(state.rowController.isNoteEditorPresented)
        XCTAssertEqual(state.rowController.noteDraft, "draft")
        XCTAssertTrue(state.rowController.isSavingNote)
        XCTAssertFalse(noteSaveTask.isCancelled)
        XCTAssertNil(state.rowController.exportActionTask)
        XCTAssertFalse(state.rowController.isExportingPNG)
        XCTAssertTrue(previewTask.isCancelled)
        XCTAssertTrue(markdownTask.isCancelled)
        XCTAssertTrue(exportTask.isCancelled)
        state.tearDown()
        XCTAssertTrue(noteSaveTask.isCancelled)
    }

    func testOptimizationMutationAcceptsOnlyItsProvenResultHash() {
        let id = UUID()
        let original = revision(id: id, hash: "old", text: "Image", sizeBytes: 100)
        let optimized = revision(id: id, hash: "optimized", text: "Image", sizeBytes: 60)
        let state = HistoryItemInteractionState(revision: original, relativeTimeText: "now")

        let start = tryUnwrap(state.beginOptimization())
        let outcome = ImageOptimizationOutcomeDTO(
            result: .optimized,
            originalBytes: 100,
            optimizedBytes: 60,
            resultingContentHash: "optimized"
        )

        XCTAssertTrue(state.acceptsOptimizationOutcome(outcome, startedAt: start))
        XCTAssertTrue(state.reconcile(to: optimized, relativeTimeText: "now"))
        XCTAssertEqual(state.revision, optimized)
    }

    func testOptimizationRejectsUnrelatedSameIDReplacement() {
        let id = UUID()
        let original = revision(id: id, hash: "old", text: "Image", sizeBytes: 100)
        let unrelated = revision(id: id, hash: "external", text: "Image", sizeBytes: 75)
        let state = HistoryItemInteractionState(revision: original, relativeTimeText: "now")
        let start = tryUnwrap(state.beginOptimization())

        XCTAssertTrue(state.reconcile(to: unrelated, relativeTimeText: "now"))
        XCTAssertFalse(
            state.acceptsOptimizationOutcome(
                ImageOptimizationOutcomeDTO(
                    result: .optimized,
                    originalBytes: 100,
                    optimizedBytes: 60,
                    resultingContentHash: "optimized"
                ),
                startedAt: start
            )
        )
        XCTAssertEqual(state.revision, unrelated)
    }

    func testNoChangeAndFailureFeedbackRequireOriginalRevision() {
        let id = UUID()
        let original = revision(id: id, hash: "old", text: "Image", sizeBytes: 100)
        let unrelated = revision(id: id, hash: "external", text: "Image", sizeBytes: 100)

        let unchangedState = HistoryItemInteractionState(revision: original, relativeTimeText: "now")
        let unchangedStart = tryUnwrap(unchangedState.beginOptimization())
        XCTAssertTrue(
            unchangedState.acceptsOptimizationOutcome(
                ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: 100, optimizedBytes: 100),
                startedAt: unchangedStart
            )
        )

        let replacedState = HistoryItemInteractionState(revision: original, relativeTimeText: "now")
        let replacedStart = tryUnwrap(replacedState.beginOptimization())
        _ = replacedState.reconcile(to: unrelated, relativeTimeText: "now")
        XCTAssertFalse(
            replacedState.acceptsOptimizationOutcome(
                ImageOptimizationOutcomeDTO(
                    result: .failed(message: "failure"),
                    originalBytes: 100,
                    optimizedBytes: 100
                ),
                startedAt: replacedStart
            )
        )
    }

    func testTearDownIsIdempotentAndCancelsEveryOwnedTask() {
        let state = HistoryItemInteractionState(
            revision: revision(id: UUID(), hash: "hash", text: "text", sizeBytes: 4),
            relativeTimeText: "now"
        )
        let optimizeTask = sleepingTask()
        let feedbackTask = sleepingTask()
        let previewTask = sleepingTask()
        state.rowController.optimizeImageTask = optimizeTask
        state.rowController.optimizeMessageTask = feedbackTask
        state.previewCoordinator.hoverPreviewTask = previewTask
        state.previewModel.text = "content"
        state.rowController.presentNoteEditor(note: "draft")

        state.tearDown()
        state.tearDown()

        XCTAssertTrue(state.isTornDown)
        XCTAssertTrue(optimizeTask.isCancelled)
        XCTAssertTrue(feedbackTask.isCancelled)
        XCTAssertTrue(previewTask.isCancelled)
        XCTAssertNil(state.rowController.optimizeImageTask)
        XCTAssertNil(state.rowController.optimizeMessageTask)
        XCTAssertNil(state.previewCoordinator.hoverPreviewTask)
        XCTAssertNil(state.previewModel.text)
        XCTAssertFalse(state.rowController.isNoteEditorPresented)
        XCTAssertTrue(state.rowController.noteDraft.isEmpty)
        XCTAssertFalse(state.hasOwnedWork)
    }

    func testRowDisappearanceSuspendsPreviewButPreservesEveryExplicitUserAction() throws {
        let state = HistoryItemInteractionState(
            revision: revision(id: UUID(), hash: "hash", text: "text", sizeBytes: 4),
            relativeTimeText: "now"
        )
        let previewTask = sleepingTask()
        let rowExportTask = sleepingTask()
        let previewExportTask = sleepingTask()
        let optimizeTask = sleepingTask()

        state.previewCoordinator.hoverPreviewTask = previewTask
        state.previewCoordinator.isHovering = true
        state.previewModel.text = "rendered preview"
        state.rowController.presentNoteEditor(note: "keep my draft")
        _ = tryUnwrap(state.beginOptimization())
        state.rowController.isOptimizingImage = true
        state.rowController.optimizeImageTask = optimizeTask
        XCTAssertTrue(state.rowController.beginExportingPNG())
        let rowExportToken = try XCTUnwrap(state.rowController.exportAuthorizationToken)
        state.rowController.exportActionTask = rowExportTask
        let previewExportToken = try XCTUnwrap(state.previewModel.beginExportAction())
        state.previewModel.exportActionTask = previewExportTask

        XCTAssertTrue(state.hasExplicitUserOwnedWork)
        state.suspendForRowDisappearance()

        XCTAssertTrue(previewTask.isCancelled)
        XCTAssertNil(state.previewCoordinator.hoverPreviewTask)
        XCTAssertNil(state.previewModel.text)
        XCTAssertTrue(state.rowController.isNoteEditorPresented)
        XCTAssertEqual(state.rowController.noteDraft, "keep my draft")
        XCTAssertFalse(optimizeTask.isCancelled)
        XCTAssertFalse(rowExportTask.isCancelled)
        XCTAssertFalse(previewExportTask.isCancelled)
        XCTAssertTrue(state.rowController.authorizesExport(token: rowExportToken))
        XCTAssertTrue(state.previewModel.authorizesExportAction(token: previewExportToken))
        XCTAssertTrue(state.hasExplicitUserOwnedWork)

        state.tearDown()
        XCTAssertTrue(optimizeTask.isCancelled)
        XCTAssertTrue(rowExportTask.isCancelled)
        XCTAssertTrue(previewExportTask.isCancelled)
    }

    func testRetainedSessionStoreUsesStableAttachmentsAndEnforcesHardCapacity() {
        let store = HistoryItemInteractionSessionStore(capacity: 1)
        let first = HistoryItemInteractionState(
            revision: revision(id: UUID(), hash: "first", text: "first", sizeBytes: 5),
            relativeTimeText: "now"
        )
        first.rowController.presentNoteEditor(note: "draft")
        let originalAttachment = store.makeAttachmentToken()
        first.activateViewAttachment(originalAttachment)
        XCTAssertTrue(store.registerExplicitWork(first, attachmentToken: originalAttachment))
        XCTAssertEqual(store.retainedCount, 1)

        let replacementAttachment = store.makeAttachmentToken()
        XCTAssertTrue(
            store.attach(itemID: first.itemID, attachmentToken: replacementAttachment) === first
        )
        XCTAssertEqual(
            store.detach(first, attachmentToken: originalAttachment),
            .staleAttachment
        )
        XCTAssertTrue(store.contains(first))

        let second = HistoryItemInteractionState(
            revision: revision(id: UUID(), hash: "second", text: "second", sizeBytes: 6),
            relativeTimeText: "now"
        )
        second.rowController.presentNoteEditor(note: "another draft")
        let secondAttachment = store.makeAttachmentToken()
        second.activateViewAttachment(secondAttachment)
        XCTAssertFalse(
            store.registerExplicitWork(second, attachmentToken: secondAttachment)
        )
        XCTAssertEqual(store.retainedCount, 1)
        XCTAssertEqual(
            store.detach(first, attachmentToken: replacementAttachment),
            .retained
        )

        first.rowController.dismissNoteEditor(discardDraft: true)
        store.release(first)
        XCTAssertEqual(store.retainedCount, 0)
    }

    func testReplacementAttachmentRejectsStaleViewCallbackAndPreservesExplicitExport() throws {
        let store = HistoryItemInteractionSessionStore(capacity: 2)
        let state = HistoryItemInteractionState(
            revision: revision(id: UUID(), hash: "hash", text: "text", sizeBytes: 4),
            relativeTimeText: "now"
        )
        let oldAttachment = store.makeAttachmentToken()
        state.activateViewAttachment(oldAttachment)
        XCTAssertTrue(state.rowController.beginExportingPNG())
        let exportToken = try XCTUnwrap(state.rowController.exportAuthorizationToken)
        let exportTask = sleepingTask()
        state.rowController.exportActionTask = exportTask
        XCTAssertTrue(store.registerExplicitWork(state, attachmentToken: oldAttachment))

        var staleMutationCount = 0
        let staleCallback = {
            guard state.ownsViewAttachment(oldAttachment),
                  store.authorizesViewAttachment(
                      state,
                      attachmentToken: oldAttachment
                  ) else { return }
            staleMutationCount += 1
        }

        let replacementAttachment = store.makeAttachmentToken()
        XCTAssertTrue(
            store.attach(
                itemID: state.itemID,
                attachmentToken: replacementAttachment
            ) === state
        )
        staleCallback()

        XCTAssertEqual(staleMutationCount, 0)
        XCTAssertFalse(state.ownsViewAttachment(oldAttachment))
        XCTAssertTrue(state.ownsViewAttachment(replacementAttachment))
        XCTAssertFalse(exportTask.isCancelled)
        XCTAssertTrue(state.rowController.authorizesExport(token: exportToken))
        XCTAssertTrue(store.contains(state))
    }

    func testProjectedAbsenceIsUnknownAndOffscreenRevisionReconcilesWithoutLosingDraft() {
        let id = UUID()
        let original = revision(id: id, hash: "old", text: "old", sizeBytes: 10)
        let updated = revision(id: id, hash: "new", text: "new", sizeBytes: 12)
        let state = HistoryItemInteractionState(revision: original, relativeTimeText: "now")
        state.rowController.presentNoteEditor(note: "keep this draft")
        let store = HistoryItemInteractionSessionStore()
        let attachment = store.makeAttachmentToken()
        state.activateViewAttachment(attachment)
        XCTAssertTrue(store.registerExplicitWork(state, attachmentToken: attachment))

        store.reconcile(
            snapshot: HistoryContentRevisionReconciliationSnapshot(
                knownRevisionsByItemID: [:],
                deletedItemIDs: [],
                clearGeneration: 0,
                clearSurvivingItemIDs: [],
                clearSurvivorSetIsAuthoritative: true,
                deletionEvictionGeneration: 0
            )
        )

        XCTAssertTrue(store.contains(state), "A filtered/page projection miss is not a deletion")
        XCTAssertFalse(state.isTornDown)

        store.reconcile(
            snapshot: HistoryContentRevisionReconciliationSnapshot(
                knownRevisionsByItemID: [id: updated],
                deletedItemIDs: [],
                clearGeneration: 0,
                clearSurvivingItemIDs: [],
                clearSurvivorSetIsAuthoritative: true,
                deletionEvictionGeneration: 0
            )
        )

        XCTAssertEqual(state.revision, updated)
        XCTAssertTrue(state.rowController.isNoteEditorPresented)
        XCTAssertEqual(state.rowController.noteDraft, "keep this draft")
    }

    func testExplicitDeleteAndClearGenerationTearDownRetainedSessions() {
        let deletedID = UUID()
        let deletedState = HistoryItemInteractionState(
            revision: revision(id: deletedID, hash: "deleted", text: "deleted", sizeBytes: 7),
            relativeTimeText: "now"
        )
        deletedState.rowController.presentNoteEditor(note: "deleted draft")
        let store = HistoryItemInteractionSessionStore()
        let deletedAttachment = store.makeAttachmentToken()
        deletedState.activateViewAttachment(deletedAttachment)
        XCTAssertTrue(store.registerExplicitWork(deletedState, attachmentToken: deletedAttachment))
        store.reconcile(
            snapshot: HistoryContentRevisionReconciliationSnapshot(
                knownRevisionsByItemID: [deletedID: deletedState.revision],
                deletedItemIDs: [],
                clearGeneration: 0,
                clearSurvivingItemIDs: [],
                clearSurvivorSetIsAuthoritative: true,
                deletionEvictionGeneration: 0
            )
        )

        store.reconcile(
            snapshot: HistoryContentRevisionReconciliationSnapshot(
                knownRevisionsByItemID: [:],
                deletedItemIDs: [deletedID],
                clearGeneration: 0,
                clearSurvivingItemIDs: [],
                clearSurvivorSetIsAuthoritative: true,
                deletionEvictionGeneration: 0
            )
        )

        XCTAssertTrue(deletedState.isTornDown)
        XCTAssertFalse(store.contains(deletedState))

        let clearID = UUID()
        let clearState = HistoryItemInteractionState(
            revision: revision(id: clearID, hash: "clear", text: "clear", sizeBytes: 5),
            relativeTimeText: "now"
        )
        clearState.rowController.presentNoteEditor(note: "clear draft")
        let clearAttachment = store.makeAttachmentToken()
        clearState.activateViewAttachment(clearAttachment)
        XCTAssertTrue(store.registerExplicitWork(clearState, attachmentToken: clearAttachment))

        store.reconcile(
            snapshot: HistoryContentRevisionReconciliationSnapshot(
                knownRevisionsByItemID: [clearID: clearState.revision],
                deletedItemIDs: [],
                clearGeneration: 1,
                clearSurvivingItemIDs: [],
                clearSurvivorSetIsAuthoritative: true,
                deletionEvictionGeneration: 0
            )
        )

        XCTAssertTrue(clearState.isTornDown)
        XCTAssertFalse(store.contains(clearState))
    }

    private func revision(
        id: UUID,
        hash: String,
        text: String,
        sizeBytes: Int
    ) -> ClipboardItemContentRevision {
        ClipboardItemContentRevision(
            item: ClipboardItemDTO(
                id: id,
                type: .image,
                contentHash: hash,
                plainText: text,
                note: nil,
                appBundleID: "com.scopy.tests",
                createdAt: Date(timeIntervalSince1970: 0),
                lastUsedAt: Date(timeIntervalSince1970: 1),
                isPinned: false,
                sizeBytes: sizeBytes,
                fileSizeBytes: nil,
                thumbnailPath: nil,
                storageRef: "/tmp/image.png"
            )
        )
    }

    private func sleepingTask() -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }

    private func tryUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) -> T {
        guard let value else {
            XCTFail("Expected non-nil value", file: file, line: line)
            fatalError("Expected non-nil value")
        }
        return value
    }
}
