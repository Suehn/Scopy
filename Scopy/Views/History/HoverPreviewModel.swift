import CoreGraphics
import Foundation
import Observation

@Observable
@MainActor
final class HoverPreviewModel {
    var previewCGImage: CGImage?
    var text: String?
    var markdownHTML: String?
    var markdownContentSize: CGSize?
    var markdownHasHorizontalOverflow: Bool = false
    var markdownRenderSucceeded: Bool = false
    var markdownRenderErrorReason: String?
    var isMarkdown: Bool = false

    // Export state
    var isExporting: Bool = false
    var exportSuccess: Bool = false
    var exportSuccessMessage: String?
    var exportFailed: Bool = false
    var exportErrorMessage: String?

    @ObservationIgnored var exportActionTask: Task<Void, Never>?
    @ObservationIgnored var exportFeedbackTask: Task<Void, Never>?
    @ObservationIgnored private(set) var exportAuthorizationToken: UUID?

    var hasContentOrFeedback: Bool {
        previewCGImage != nil || text != nil || markdownHTML != nil ||
            markdownContentSize != nil || markdownHasHorizontalOverflow ||
            markdownRenderSucceeded || markdownRenderErrorReason != nil || isMarkdown ||
            isExporting || exportSuccess || exportSuccessMessage != nil ||
            exportFailed || exportErrorMessage != nil
    }

    func cancelExportTasks() {
        exportAuthorizationToken = nil
        exportActionTask?.cancel()
        exportActionTask = nil
        exportFeedbackTask?.cancel()
        exportFeedbackTask = nil
        isExporting = false
    }

    func beginExportAction() -> UUID? {
        guard !isExporting else { return nil }
        let token = UUID()
        exportAuthorizationToken = token
        isExporting = true
        exportSuccess = false
        exportSuccessMessage = nil
        exportFailed = false
        exportErrorMessage = nil
        return token
    }

    func authorizesExportAction(token: UUID) -> Bool {
        isExporting && exportAuthorizationToken == token && exportActionTask != nil
    }

    @discardableResult
    func finishExportAction(token: UUID) -> Bool {
        guard exportAuthorizationToken == token else { return false }
        exportAuthorizationToken = nil
        exportActionTask = nil
        isExporting = false
        return true
    }

    /// Clears view-owned preview payload while allowing a user-started export to finish after the
    /// popover or its virtualized row disappears.
    func resetPreviewContent() {
        previewCGImage = nil
        text = nil
        markdownHTML = nil
        markdownContentSize = nil
        markdownHasHorizontalOverflow = false
        markdownRenderSucceeded = false
        markdownRenderErrorReason = nil
        isMarkdown = false
    }

    func reset() {
        cancelExportTasks()
        resetPreviewContent()
        isExporting = false
        exportSuccess = false
        exportSuccessMessage = nil
        exportFailed = false
        exportErrorMessage = nil
    }
}
