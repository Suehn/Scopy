import CoreGraphics
import Foundation
import ScopyKit
import ScopyUISupport

@MainActor
internal struct HistoryItemRowDescriptor {
    struct Dependencies {
        var displayTexts: @MainActor (ClipboardItemDTO) -> (title: String, metadata: String)
        var filePreview: @MainActor (ClipboardItemDTO) -> FilePreviewSummary?
        var canExportPNG: @MainActor (ClipboardItemDTO, FilePreviewSummary?) -> Bool

        static let live = Dependencies(
            displayTexts: { ClipboardItemDisplayText.shared.displayTexts(for: $0) },
            filePreview: { HistoryItemPresentationCache.shared.filePreview(for: $0) },
            canExportPNG: { item, filePreview in
                HistoryItemPresentationCache.shared.canExportPNG(for: item, filePreview: filePreview)
            }
        )
    }

    let titleText: String
    let metadataText: String
    let thumbnailHeight: CGFloat
    let showThumbnails: Bool
    let filePreviewInfo: FilePreviewInfo?
    let filePreviewPath: String?
    let filePreviewKind: FilePreviewKind?
    let filePreviewIsMarkdown: Bool
    let canExportPNG: Bool
    let canShowFileThumbnail: Bool
    let needsThumbnailHeight: Bool
    let appIconBundleID: String?

    init(
        item: ClipboardItemDTO,
        settings: SettingsDTO,
        dependencies: Dependencies = .live
    ) {
        let profileStart = ScrollPerformanceProfile.isEnabled ? CFAbsoluteTimeGetCurrent() : nil
        defer {
            if let profileStart {
                ScrollPerformanceProfile.recordMetric(
                    name: "row.display_model_ms",
                    elapsedMs: (CFAbsoluteTimeGetCurrent() - profileStart) * 1000
                )
            }
        }

        let thumbnailHeight = CGFloat(settings.thumbnailHeight)
        let showThumbnails = settings.showImageThumbnails
        let filePreview = dependencies.filePreview(item)
        let canShowFileThumbnail = showThumbnails
            && item.type == .file
            && filePreview?.shouldGenerateThumbnail == true
        let canExportPNG = dependencies.canExportPNG(item, filePreview)
        let displayTexts = dependencies.displayTexts(item)

        self.titleText = displayTexts.title
        self.metadataText = displayTexts.metadata
        self.thumbnailHeight = thumbnailHeight
        self.showThumbnails = showThumbnails
        self.filePreviewInfo = filePreview?.info
        self.filePreviewPath = filePreview?.path
        self.filePreviewKind = filePreview?.kind
        self.filePreviewIsMarkdown = filePreview?.isMarkdown ?? false
        self.canExportPNG = canExportPNG
        self.canShowFileThumbnail = canShowFileThumbnail
        self.needsThumbnailHeight = (item.type == .image && showThumbnails) || canShowFileThumbnail
        self.appIconBundleID = item.appBundleID
    }
}
