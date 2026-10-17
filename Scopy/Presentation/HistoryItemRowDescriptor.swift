import CoreGraphics
import Foundation
import ScopyKit
import ScopyUISupport

@MainActor
internal struct HistoryItemRowDescriptor {
    let titleText: String
    let metadataText: String
    let searchMetadataPrefix: String?
    let thumbnailHeight: CGFloat
    let showThumbnails: Bool
    let filePreviewInfo: FilePreviewInfo?
    let filePreviewPath: String?
    let filePreviewKind: FilePreviewKind?
    let filePreviewIsMarkdown: Bool
    let canShowFileThumbnail: Bool
    let needsThumbnailHeight: Bool
    let appIconBundleID: String?

    init(
        item: ClipboardItemDTO,
        settings: SettingsDTO
    ) {
        let profileStart = ScrollPerformanceProfile.isEnabled ? CFAbsoluteTimeGetCurrent() : nil
        defer {
            if let profileStart {
                ScrollPerformanceProfile.recordTiming(
                    name: "row.display_model_ms",
                    elapsedMs: (CFAbsoluteTimeGetCurrent() - profileStart) * 1000
                )
            }
        }

        let thumbnailHeight = CGFloat(settings.thumbnailHeight)
        let showThumbnails = settings.showImageThumbnails
        let filePreview = HistoryItemPresentationCache.shared.filePreview(for: item)
        let canShowFileThumbnail = showThumbnails
            && item.type == .file
            && filePreview?.shouldGenerateThumbnail == true
        let displayTexts = ClipboardItemDisplayText.shared.displayTexts(for: item)

        self.titleText = displayTexts.title
        self.metadataText = displayTexts.metadata
        self.searchMetadataPrefix = displayTexts.searchMetadataPrefix
        self.thumbnailHeight = thumbnailHeight
        self.showThumbnails = showThumbnails
        self.filePreviewInfo = filePreview?.info
        self.filePreviewPath = filePreview?.path
        self.filePreviewKind = filePreview?.kind
        self.filePreviewIsMarkdown = filePreview?.isMarkdown ?? false
        self.canShowFileThumbnail = canShowFileThumbnail
        self.needsThumbnailHeight = (item.type == .image && showThumbnails) || canShowFileThumbnail
        self.appIconBundleID = item.appBundleID
    }
}
