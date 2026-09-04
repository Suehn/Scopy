import CoreGraphics
import Foundation
import Observation
import ScopyKit

@Observable
@MainActor
final class HoverPreviewModel {
    var previewCGImage: CGImage?
    var text: String?
    var markdownHTML: String?
    var markdownContentSize: CGSize?
    var markdownMetricsLayoutScalePercent: Int?
    var markdownHasHorizontalOverflow: Bool = false
    private(set) var markdownLiveRenderKey: String?
    private var markdownRenderErrorKey: String?
    private var markdownRenderErrorReason: String?
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
            markdownLiveRenderKey != nil || markdownRenderErrorReason != nil || isMarkdown ||
            isExporting || exportSuccess || exportSuccessMessage != nil ||
            exportFailed || exportErrorMessage != nil
    }

    nonisolated static func markdownRenderKey(
        source: String,
        layoutScale: MarkdownChatGPTLayoutScalePercent
    ) -> String {
        let enrichment = LinkEnrichmentStore.shared.payload(
            forContentKey: LinkEnrichmentContentKey.make(for: source)
        )
        return [
            layoutScale.cacheKey,
            enrichment?.fingerprint ?? "plain",
            ClipboardItemContentRevision.deterministicTextCacheKey(source)
        ].joined(separator: "|")
    }

    /// The link-enrichment fingerprint `markdownHTML` was built with. When a frozen
    /// sidecar lands after the pipeline render, the live fingerprint moves ahead of this
    /// stamp and the preview rebuilds the document instead of showing stale default HTML.
    private(set) var markdownHTMLEnrichmentFingerprint: String?
    /// Layout scale `markdownHTML` was rendered at; nil until a document arrives.
    private(set) var markdownHTMLLayoutScale: MarkdownChatGPTLayoutScalePercent?

    nonisolated static func enrichmentFingerprint(for source: String) -> String {
        LinkEnrichmentStore.shared.payload(
            forContentKey: LinkEnrichmentContentKey.make(for: source)
        )?.fingerprint ?? "plain"
    }

    /// Cached HTML and metrics may seed the popover geometry, but they do not describe the
    /// readiness of the reusable WebView currently owned by this preview.
    func primeTextPreview(
        text: String?,
        isMarkdown: Bool,
        markdownHTML: String?,
        markdownContentSize: CGSize?,
        markdownHasHorizontalOverflow: Bool,
        layoutScale: MarkdownChatGPTLayoutScalePercent? = nil
    ) {
        markdownMetricsLayoutScalePercent = nil
        self.text = text
        self.isMarkdown = isMarkdown
        self.markdownHTML = markdownHTML
        markdownHTMLLayoutScale = markdownHTML == nil ? nil : layoutScale
        self.markdownContentSize = markdownContentSize
        self.markdownHasHorizontalOverflow = markdownHasHorizontalOverflow
        markdownHTMLEnrichmentFingerprint = text.flatMap { source in
            markdownHTML == nil ? nil : Self.enrichmentFingerprint(for: source)
        }
        invalidateMarkdownLiveRender()
    }

    func setMarkdownHTMLAwaitingLiveRender(_ html: String, layoutScale: MarkdownChatGPTLayoutScalePercent? = nil) {
        markdownMetricsLayoutScalePercent = nil
        markdownHTML = html
        markdownHTMLLayoutScale = layoutScale
        markdownHTMLEnrichmentFingerprint = text.map { Self.enrichmentFingerprint(for: $0) }
        invalidateMarkdownLiveRender()
    }

    func prepareMarkdownRender(for renderKey: String) {
        guard markdownLiveRenderKey != renderKey else { return }
        markdownLiveRenderKey = nil
        if markdownRenderErrorKey != renderKey {
            markdownRenderErrorKey = nil
            markdownRenderErrorReason = nil
        }
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
        previewCGImage = nil
        text = nil
        markdownHTML = nil
        markdownHTMLEnrichmentFingerprint = nil
        markdownContentSize = nil
        markdownMetricsLayoutScalePercent = nil
        markdownHasHorizontalOverflow = false
        invalidateMarkdownLiveRender()
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

    /// Hands already-rendered content to another model.
    ///
    /// Pinning must show the document that is already on screen: the payload, the measured
    /// geometry and the live-render stamp all move across, so the pinned host reuses the shared
    /// WebView's current navigation instead of re-running the preview pipeline. Export state is
    /// feedback for the surface that started it and stays behind.
    func adoptRenderedContent(from source: HoverPreviewModel) {
        previewCGImage = source.previewCGImage
        text = source.text
        isMarkdown = source.isMarkdown
        markdownHTML = source.markdownHTML
        markdownHTMLLayoutScale = source.markdownHTMLLayoutScale
        markdownHTMLEnrichmentFingerprint = source.markdownHTMLEnrichmentFingerprint
        markdownContentSize = source.markdownContentSize
        markdownMetricsLayoutScalePercent = source.markdownMetricsLayoutScalePercent
        markdownHasHorizontalOverflow = source.markdownHasHorizontalOverflow
        markdownLiveRenderKey = source.markdownLiveRenderKey
        markdownRenderErrorKey = source.markdownRenderErrorKey
        markdownRenderErrorReason = source.markdownRenderErrorReason
    }

    /// Whether anything is available to show without re-running the pipeline.
    var hasRenderedContent: Bool {
        previewCGImage != nil || text != nil || markdownHTML != nil
    }
}
