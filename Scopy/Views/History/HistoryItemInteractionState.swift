import Foundation
import Observation
import ScopyKit

/// Lazily-created state for the interaction half of a history row.
///
/// Static row rendering deliberately owns none of these objects. A session is created only for
/// hover/preview, note editing, export, or image optimization, and is released once every owned
/// task and piece of transient UI state is idle.
@Observable
@MainActor
final class HistoryItemInteractionState {
    let itemID: UUID
    private(set) var revision: ClipboardItemContentRevision

    @ObservationIgnored let rowController: HistoryItemRowController
    @ObservationIgnored let previewCoordinator: HistoryItemPreviewCoordinator
    @ObservationIgnored let previewModel: HoverPreviewModel

    @ObservationIgnored private(set) var isTornDown = false
    @ObservationIgnored private var activeViewAttachmentToken:
        HistoryItemInteractionSessionStore.AttachmentToken?
    @ObservationIgnored private(set) var optimizationStartRevision: ClipboardItemContentRevision?
    @ObservationIgnored private var expectedOptimizationContentHash: String?
    @ObservationIgnored private var optimizationFeedbackRevision: ClipboardItemContentRevision?

    init(revision: ClipboardItemContentRevision, relativeTimeText: String) {
        itemID = revision.itemID
        self.revision = revision
        rowController = HistoryItemRowController(relativeTimeText: relativeTimeText)
        previewCoordinator = HistoryItemPreviewCoordinator()
        previewModel = HoverPreviewModel()
    }

    /// Reconciles a same-row session with the latest payload revision.
    ///
    /// Preview, Markdown, and PNG-export work is content-owned and is invalidated. A note draft or
    /// save belongs to the item and survives payload/file-size revisions. Image optimization is
    /// also item-owned while in flight; its completion still needs an exact resulting hash proof
    /// before feedback is accepted for the replacement revision.
    @discardableResult
    func reconcile(
        to newRevision: ClipboardItemContentRevision,
        relativeTimeText: String
    ) -> Bool {
        guard !isTornDown, itemID == newRevision.itemID else { return false }
        rowController.relativeTimeText = relativeTimeText
        guard revision != newRevision else { return false }

        revision = newRevision
        previewCoordinator.cancelHoverTasks()
        previewCoordinator.cancelPreviewTasks()
        previewCoordinator.invalidatePreviewTokens()
        previewCoordinator.isHovering = false
        previewModel.reset()

        rowController.cancelExportActionTask()
        rowController.cancelExportMessageTask()
        rowController.exportMessage = nil

        if let expectedOptimizationContentHash,
           newRevision.matchesContentHash(expectedOptimizationContentHash) {
            self.expectedOptimizationContentHash = nil
            optimizationFeedbackRevision = newRevision
        } else if optimizationStartRevision == nil,
                  optimizationFeedbackRevision != newRevision {
            clearOptimizationFeedback()
        }
        return true
    }

    func beginOptimization() -> ClipboardItemContentRevision? {
        guard !isTornDown, optimizationStartRevision == nil else { return nil }
        optimizationStartRevision = revision
        expectedOptimizationContentHash = nil
        optimizationFeedbackRevision = nil
        return revision
    }

    /// Returns true only when the outcome can be tied to this session's current or immediately
    /// pending revision. Successful mutation must carry the exact persisted/emitted content hash.
    func acceptsOptimizationOutcome(
        _ outcome: ImageOptimizationOutcomeDTO,
        startedAt startRevision: ClipboardItemContentRevision
    ) -> Bool {
        guard !isTornDown, optimizationStartRevision == startRevision else { return false }
        optimizationStartRevision = nil

        switch outcome.result {
        case .optimized:
            guard let resultingHash = outcome.resultingContentHash,
                  !resultingHash.isEmpty else { return false }
            if revision.matchesContentHash(resultingHash) {
                optimizationFeedbackRevision = revision
                expectedOptimizationContentHash = nil
                return true
            }
            guard revision == startRevision else { return false }
            expectedOptimizationContentHash = resultingHash
            return true
        case .noChange, .failed:
            guard revision == startRevision else { return false }
            optimizationFeedbackRevision = revision
            expectedOptimizationContentHash = nil
            return true
        }
    }

    func finishOptimizationWithoutFeedback(startedAt startRevision: ClipboardItemContentRevision) {
        guard optimizationStartRevision == startRevision else { return }
        optimizationStartRevision = nil
        expectedOptimizationContentHash = nil
    }

    var hasOwnedWork: Bool {
        let row = rowController
        let preview = previewCoordinator
        let model = previewModel
        return row.isOptimizingImage || row.optimizeImageTask != nil ||
            row.optimizeMessage != nil || row.optimizeMessageTask != nil ||
            row.isHoveringOptimizeButton || row.isNoteEditorPresented || !row.noteDraft.isEmpty ||
            row.isSavingNote || row.noteSaveTask != nil || row.noteSaveError != nil ||
            row.isExportingPNG || row.exportActionTask != nil ||
            row.exportMessage != nil || row.exportMessageTask != nil ||
            preview.isHovering || preview.isPopoverHovering || preview.hasActiveHoverWork ||
            model.hasContentOrFeedback || model.exportActionTask != nil || model.exportFeedbackTask != nil
    }

    /// Work created by a direct user command may outlive SwiftUI row virtualization. Hover and
    /// preview work remain view-owned and are intentionally excluded.
    var hasExplicitUserOwnedWork: Bool {
        let row = rowController
        let model = previewModel
        return row.isOptimizingImage || row.optimizeImageTask != nil ||
            row.optimizeMessage != nil || row.optimizeMessageTask != nil ||
            optimizationStartRevision != nil || expectedOptimizationContentHash != nil ||
            row.isExportingPNG || row.exportActionTask != nil ||
            row.exportMessage != nil || row.exportMessageTask != nil ||
            row.isNoteEditorPresented || !row.noteDraft.isEmpty ||
            row.isSavingNote || row.noteSaveTask != nil || row.noteSaveError != nil ||
            model.isExporting || model.exportActionTask != nil ||
            model.exportSuccess || model.exportSuccessMessage != nil ||
            model.exportFailed || model.exportErrorMessage != nil ||
            model.exportFeedbackTask != nil
    }

    /// Releases only view-owned hover/preview resources. Explicit note/export/optimization state
    /// stays alive so a recycled List row cannot cancel a user command.
    func suspendForRowDisappearance() {
        guard !isTornDown else { return }
        rowController.interactionObservation?.cancel()
        rowController.interactionObservation = nil
        rowController.isHoveringOptimizeButton = false
        rowController.isScrollInteractionActive = false

        previewCoordinator.cancelHoverTasks()
        previewCoordinator.cancelPreviewTasks()
        previewCoordinator.invalidatePreviewTokens()
        previewCoordinator.isHovering = false
        previewModel.resetPreviewContent()
    }

    /// Transfers the view-owned half of a retained session to one concrete SwiftUI row
    /// generation. Explicit note/export/optimization work remains session-owned, while hover and
    /// popover work from the superseded row is cancelled before the new generation can attach.
    func activateViewAttachment(
        _ token: HistoryItemInteractionSessionStore.AttachmentToken
    ) {
        guard !isTornDown else { return }
        if let activeViewAttachmentToken, activeViewAttachmentToken != token {
            suspendForRowDisappearance()
        }
        activeViewAttachmentToken = token
    }

    func ownsViewAttachment(
        _ token: HistoryItemInteractionSessionStore.AttachmentToken?
    ) -> Bool {
        !isTornDown && token != nil && activeViewAttachmentToken == token
    }

    @discardableResult
    func deactivateViewAttachment(
        _ token: HistoryItemInteractionSessionStore.AttachmentToken?
    ) -> Bool {
        guard ownsViewAttachment(token) else { return false }
        activeViewAttachmentToken = nil
        return true
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true

        rowController.interactionObservation?.cancel()
        rowController.interactionObservation = nil
        rowController.cancelOptimizeImageTask()
        rowController.cancelOptimizeMessageTask()
        rowController.cancelExportActionTask()
        rowController.cancelExportMessageTask()
        rowController.optimizeMessage = nil
        rowController.exportMessage = nil
        rowController.dismissNoteEditor(discardDraft: true)
        rowController.isHoveringOptimizeButton = false
        rowController.isScrollInteractionActive = false

        previewCoordinator.cancelHoverTasks()
        previewCoordinator.cancelPreviewTasks()
        previewCoordinator.invalidatePreviewTokens()
        previewCoordinator.isHovering = false
        previewModel.reset()

        optimizationStartRevision = nil
        expectedOptimizationContentHash = nil
        optimizationFeedbackRevision = nil
        activeViewAttachmentToken = nil
    }

    private func clearOptimizationFeedback() {
        expectedOptimizationContentHash = nil
        optimizationFeedbackRevision = nil
        rowController.cancelOptimizeMessageTask()
        rowController.optimizeMessage = nil
    }
}

/// List-owned retention for the small set of explicit row sessions that outlive virtualization.
/// Idle and hover-only rows are never inserted, so this does not recreate visible-row fan-out.
@MainActor
final class HistoryItemInteractionSessionStore {
    struct AttachmentToken: Hashable {
        fileprivate let rawValue = UUID()
    }

    enum DetachResult: Equatable {
        case unretained
        case retained
        case staleAttachment
    }

    private struct Entry {
        let state: HistoryItemInteractionState
        var attachmentToken: AttachmentToken?
    }

    private let capacity: Int
    private var retainedByItemID: [UUID: Entry] = [:]
    private var lastAppliedClearGeneration: UInt64 = 0
    private var lastAppliedDeletionEvictionGeneration: UInt64 = 0

    init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    var retainedCount: Int {
        retainedByItemID.count
    }

    func makeAttachmentToken() -> AttachmentToken {
        AttachmentToken()
    }

    /// Registers explicit work at action start, before virtualization can remove its row.
    @discardableResult
    func registerExplicitWork(
        _ state: HistoryItemInteractionState,
        attachmentToken: AttachmentToken?
    ) -> Bool {
        guard !state.isTornDown,
              state.hasExplicitUserOwnedWork,
              state.ownsViewAttachment(attachmentToken) else { return false }
        if let previous = retainedByItemID[state.itemID] {
            guard previous.state === state,
                  previous.attachmentToken == attachmentToken else { return false }
            return true
        }
        guard retainedByItemID.count < capacity else { return false }
        retainedByItemID[state.itemID] = Entry(
            state: state,
            attachmentToken: attachmentToken
        )
        return true
    }

    /// Reattaches the exact retained session without removing the list-owned source of truth.
    func attach(
        itemID: UUID,
        attachmentToken: AttachmentToken
    ) -> HistoryItemInteractionState? {
        guard var entry = retainedByItemID[itemID] else { return nil }
        entry.state.activateViewAttachment(attachmentToken)
        entry.attachmentToken = attachmentToken
        retainedByItemID[itemID] = entry
        return entry.state
    }

    func detach(
        _ state: HistoryItemInteractionState,
        attachmentToken: AttachmentToken?
    ) -> DetachResult {
        guard var entry = retainedByItemID[state.itemID], entry.state === state else {
            return .unretained
        }
        guard entry.attachmentToken == attachmentToken else {
            return .staleAttachment
        }
        entry.attachmentToken = nil
        retainedByItemID[state.itemID] = entry
        return .retained
    }

    func contains(_ state: HistoryItemInteractionState) -> Bool {
        retainedByItemID[state.itemID]?.state === state
    }

    /// Unretained hover-only state is local to one row and may activate freely. Once explicit work
    /// is retained, only the store's latest attachment generation may drive view-owned callbacks.
    func authorizesViewAttachment(
        _ state: HistoryItemInteractionState,
        attachmentToken: AttachmentToken?
    ) -> Bool {
        guard let entry = retainedByItemID[state.itemID] else { return true }
        return entry.state === state &&
            attachmentToken != nil && entry.attachmentToken == attachmentToken
    }

    func release(_ state: HistoryItemInteractionState) {
        guard retainedByItemID[state.itemID]?.state === state else { return }
        retainedByItemID.removeValue(forKey: state.itemID)
    }

    /// Reconciles off-screen work against the view model's bounded authoritative registry. Missing
    /// entries are unknown (for example capacity eviction), never an implicit delete.
    func reconcile(snapshot: HistoryContentRevisionReconciliationSnapshot) {
        let clearGenerationChanged = lastAppliedClearGeneration != snapshot.clearGeneration
        let deletionEvictionGenerationChanged =
            lastAppliedDeletionEvictionGeneration != snapshot.deletionEvictionGeneration
        lastAppliedClearGeneration = snapshot.clearGeneration
        lastAppliedDeletionEvictionGeneration = snapshot.deletionEvictionGeneration
        guard !retainedByItemID.isEmpty else { return }
        var itemIDsToRelease: [UUID] = []

        for (itemID, entry) in retainedByItemID {
            let state = entry.state
            let invalidatedByClear = clearGenerationChanged &&
                snapshot.clearSurvivorSetIsAuthoritative &&
                !snapshot.clearSurvivingItemIDs.contains(itemID)
            let invalidatedByDeletionOverflow = !clearGenerationChanged &&
                deletionEvictionGenerationChanged
            if invalidatedByClear || invalidatedByDeletionOverflow || snapshot.wasDeleted(itemID) {
                state.tearDown()
                itemIDsToRelease.append(itemID)
                continue
            }

            if let revision = snapshot.revision(for: itemID) {
                _ = state.reconcile(
                    to: revision,
                    relativeTimeText: state.rowController.relativeTimeText
                )
            }
            if !state.hasExplicitUserOwnedWork {
                state.tearDown()
                itemIDsToRelease.append(itemID)
            }
        }
        for itemID in itemIDsToRelease {
            retainedByItemID.removeValue(forKey: itemID)
        }
    }
}
