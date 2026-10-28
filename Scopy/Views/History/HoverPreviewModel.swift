import CoreGraphics
import Foundation
import Observation
import ScopyKit

@Observable
@MainActor
final class HoverPreviewModel {
    var previewCGImage: CGImage?
    /// Header pixel size of the previewed image; sizes the popover before the decode lands.
    var previewPixelSize: CGSize?
    /// Whether the previewed file exists; nil until the pipeline has checked.
    var fileIsAvailable: Bool?
    private(set) var textContent: HoverPreviewTextContent?
    var text: String? { textContent?.text }
    var markdownDocument: PreparedMarkdownDocument? { textContent?.document }
    var markdownContentSize: CGSize?
    var markdownMetricsLayoutScalePercent: Int?
    var markdownHasHorizontalOverflow: Bool = false
    private(set) var markdownLiveRenderKey: String?
    private var markdownRenderErrorKey: String?
    private var markdownRenderErrorReason: String?
    var isMarkdown: Bool { textContent?.isMarkdown ?? false }
    var presentationSize: CGSize?
    var previewLayoutScalePercent: Int?

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
        previewCGImage != nil || text != nil || markdownDocument != nil ||
            markdownContentSize != nil || markdownHasHorizontalOverflow ||
            markdownLiveRenderKey != nil || markdownRenderErrorReason != nil || isMarkdown ||
            isExporting || exportSuccess || exportSuccessMessage != nil ||
            exportFailed || exportErrorMessage != nil
    }

    /// Cached geometry does not make the reusable WebView live. The document carries the
    /// identity of the exact input that produced its HTML, including its frozen enrichment.
    func primeTextPreview(
        content: HoverPreviewTextContent?,
        markdownContentSize: CGSize? = nil,
        markdownHasHorizontalOverflow: Bool = false
    ) {
        textContent = content
        markdownMetricsLayoutScalePercent = nil
        self.markdownContentSize = markdownContentSize
        self.markdownHasHorizontalOverflow = markdownHasHorizontalOverflow
        invalidateMarkdownLiveRender()
    }

    func setMarkdownDocumentAwaitingLiveRender(_ document: PreparedMarkdownDocument) {
        textContent = .markdown(document)
        markdownMetricsLayoutScalePercent = nil
        markdownHasHorizontalOverflow = false
        invalidateMarkdownLiveRender()
    }

    func invalidateMarkdownLiveRender() {
        markdownLiveRenderKey = nil
        markdownRenderErrorKey = nil
        markdownRenderErrorReason = nil
    }

    func markMarkdownRenderSucceeded(for renderKey: String) {
        markdownLiveRenderKey = renderKey
        markdownRenderErrorKey = nil
        markdownRenderErrorReason = nil
    }

    func markMarkdownRenderFailed(for renderKey: String, reason: String) {
        markdownLiveRenderKey = nil
        markdownRenderErrorKey = renderKey
        markdownRenderErrorReason = reason
    }

    func isMarkdownRenderLive(for renderKey: String) -> Bool {
        markdownLiveRenderKey == renderKey
    }

    func markdownRenderErrorReason(for renderKey: String) -> String? {
        guard markdownRenderErrorKey == renderKey else { return nil }
        return markdownRenderErrorReason
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
        presentationSize = nil
        previewLayoutScalePercent = nil
        previewCGImage = nil
        previewPixelSize = nil
        fileIsAvailable = nil
        textContent = nil
        markdownContentSize = nil
        markdownMetricsLayoutScalePercent = nil
        markdownHasHorizontalOverflow = false
        invalidateMarkdownLiveRender()
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

    /// Hands already-rendered content to another model.
    ///
    /// Pinning must show the document that is already on screen: the payload, the measured
    /// geometry and the live-render stamp all move across, so the pinned host reuses the shared
    /// WebView's current navigation instead of re-running the preview pipeline. Export state is
    /// feedback for the surface that started it and stays behind.
    func adoptRenderedContent(from source: HoverPreviewModel) {
        presentationSize = source.presentationSize
        previewLayoutScalePercent = source.previewLayoutScalePercent
        previewCGImage = source.previewCGImage
        previewPixelSize = source.previewPixelSize
        fileIsAvailable = source.fileIsAvailable
        textContent = source.textContent
        markdownContentSize = source.markdownContentSize
        markdownMetricsLayoutScalePercent = source.markdownMetricsLayoutScalePercent
        markdownHasHorizontalOverflow = source.markdownHasHorizontalOverflow
        markdownLiveRenderKey = source.markdownLiveRenderKey
        markdownRenderErrorKey = source.markdownRenderErrorKey
        markdownRenderErrorReason = source.markdownRenderErrorReason
    }

    /// Whether anything is available to show without re-running the pipeline.
    var hasRenderedContent: Bool {
        previewCGImage != nil || text != nil || markdownDocument != nil
    }
}
