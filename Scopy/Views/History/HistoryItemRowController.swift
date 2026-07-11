import Foundation
import Observation

@Observable
@MainActor
final class HistoryItemRowController {
    struct NoteSaveRequest: Equatable {
        let token: UUID
        let draftGeneration: UInt64
        let normalizedNote: String?
    }

    enum NoteSaveCompletion: Equatable {
        case stale
        case savedAndDismissed
        case savedWithNewerDraft
        case failed
    }

    var relativeTimeText: String
    var isOptimizingImage = false
    var optimizeMessage: String?
    var exportMessage: String?
    var isHoveringOptimizeButton = false
    var isNoteEditorPresented = false
    var noteDraft = "" {
        didSet {
            guard noteDraft != oldValue else { return }
            noteDraftGeneration &+= 1
            noteSaveError = nil
        }
    }
    private(set) var isSavingNote = false
    private(set) var noteSaveError: String?
    var isExportingPNG = false
    var isScrollInteractionActive = false

    @ObservationIgnored var optimizeImageTask: Task<Void, Never>?
    @ObservationIgnored var optimizeMessageTask: Task<Void, Never>?
    @ObservationIgnored var exportActionTask: Task<Void, Never>?
    @ObservationIgnored var exportMessageTask: Task<Void, Never>?
    @ObservationIgnored private(set) var noteSaveTask: Task<Void, Never>?
    @ObservationIgnored var interactionObservation: HistoryListInteractionObservation?
    @ObservationIgnored private(set) var exportAuthorizationToken: UUID?
    @ObservationIgnored private(set) var noteSaveToken: UUID?
    @ObservationIgnored private var noteDraftGeneration: UInt64 = 0

    init(relativeTimeText: String) {
        self.relativeTimeText = relativeTimeText
    }

    func cancelOptimizeMessageTask() {
        optimizeMessageTask?.cancel()
        optimizeMessageTask = nil
    }

    func cancelExportMessageTask() {
        exportMessageTask?.cancel()
        exportMessageTask = nil
    }

    func cancelOptimizeImageTask() {
        optimizeImageTask?.cancel()
        optimizeImageTask = nil
        isOptimizingImage = false
    }

    func cancelExportActionTask() {
        exportActionTask?.cancel()
        exportActionTask = nil
        exportAuthorizationToken = nil
        isExportingPNG = false
    }

    func beginExportingPNG() -> Bool {
        guard !isExportingPNG else { return false }
        exportMessage = nil
        isExportingPNG = true
        exportAuthorizationToken = UUID()
        return true
    }

    func authorizesExport(token: UUID) -> Bool {
        isExportingPNG && exportAuthorizationToken == token && exportActionTask != nil
    }

    @discardableResult
    func finishExportingPNG(message: String, token: UUID? = nil) -> Bool {
        if let token, exportAuthorizationToken != token {
            return false
        }
        isExportingPNG = false
        exportActionTask = nil
        exportAuthorizationToken = nil
        exportMessage = message
        return true
    }

    func clearExportFeedback() {
        exportMessage = nil
        cancelExportMessageTask()
    }

    func presentNoteEditor(note: String?) {
        cancelNoteSave()
        noteDraft = note ?? ""
        noteSaveError = nil
        isNoteEditorPresented = true
    }

    func dismissNoteEditor(discardDraft: Bool = false) {
        cancelNoteSave()
        isNoteEditorPresented = false
        noteSaveError = nil
        if discardDraft {
            noteDraft = ""
        }
    }

    func beginNoteSave() -> NoteSaveRequest? {
        guard isNoteEditorPresented, !isSavingNote else { return nil }
        let request = NoteSaveRequest(
            token: UUID(),
            draftGeneration: noteDraftGeneration,
            normalizedNote: normalizedNoteDraft()
        )
        noteSaveError = nil
        isSavingNote = true
        noteSaveToken = request.token
        return request
    }

    @discardableResult
    func installNoteSaveTask(
        _ task: Task<Void, Never>,
        token: UUID
    ) -> Bool {
        guard isSavingNote, noteSaveToken == token else {
            task.cancel()
            return false
        }
        noteSaveTask = task
        return true
    }

    func authorizesNoteSave(token: UUID) -> Bool {
        isSavingNote && noteSaveToken == token
    }

    @discardableResult
    func finishNoteSave(
        succeeded: Bool,
        request: NoteSaveRequest,
        failureMessage: String = "Couldn't save note. Try again."
    ) -> NoteSaveCompletion {
        guard authorizesNoteSave(token: request.token) else { return .stale }

        noteSaveTask = nil
        noteSaveToken = nil
        isSavingNote = false

        guard succeeded else {
            noteSaveError = failureMessage
            return .failed
        }

        noteSaveError = nil
        guard noteDraftGeneration == request.draftGeneration else {
            return .savedWithNewerDraft
        }

        isNoteEditorPresented = false
        noteDraft = ""
        return .savedAndDismissed
    }

    func cancelNoteSave() {
        noteSaveTask?.cancel()
        noteSaveTask = nil
        noteSaveToken = nil
        isSavingNote = false
    }

    func normalizedNoteDraft() -> String? {
        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
