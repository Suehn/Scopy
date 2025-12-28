import AppKit
import ScopyKit
import ScopyUISupport
import SwiftUI

struct HistoryItemFilePreviewView: View {
    @ObservedObject var model: HoverPreviewModel
    let thumbnailPath: String?
    let kind: FilePreviewKind
    let filePath: String?
    let markdownWebViewController: MarkdownPreviewWebViewController?

    @State private var loadedThumbnail: NSImage?
    @State private var lastLoadedPath: String?
    @State private var videoNaturalSize: CGSize?

    var body: some View {
        if isMarkdownPreview {
            HistoryItemTextPreviewView(
                model: model,
                markdownWebViewController: markdownWebViewController,
                showMarkdownPlaceholder: true
            )
                .accessibilityIdentifier("History.Preview.File")
                .accessibilityElement(children: .contain)
        } else {
            let maxWidth: CGFloat = max(1, HoverPreviewScreenMetrics.maxPopoverWidthPoints())
            let maxHeight: CGFloat = HoverPreviewScreenMetrics.maxPopoverHeightPoints()
            let width = previewWidth(maxWidth: maxWidth, maxHeight: maxHeight)

            let content = previewContent()
            let naturalHeight = previewHeight(width: width)
            let desiredHeight = min(maxHeight, max(1, naturalHeight))

            Group {
                if naturalHeight > maxHeight {
                    ScrollView(.vertical) {
                        content
                            .frame(width: width, height: naturalHeight)
                    }
                    .scrollIndicators(.visible)
                    .frame(width: width, height: desiredHeight)
                } else {
                    content
                        .frame(width: width, height: desiredHeight)
                }
            }
            .accessibilityIdentifier("History.Preview.File")
            .accessibilityElement(children: .contain)
            .task(id: filePath) {
                await loadVideoNaturalSizeIfNeeded(path: filePath)
            }
        }
    }

    @ViewBuilder
    private func previewContent() -> some View {
        if kind != .image, let filePath, FileManager.default.fileExists(atPath: filePath) {
            QuickLookPreviewView(url: URL(fileURLWithPath: filePath))
        } else if let cgImage = model.previewCGImage {
            Image(decorative: cgImage, scale: 1.0)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if let thumbnailPath {
            let loaded = lastLoadedPath == thumbnailPath ? loadedThumbnail : nil
            let cached = ThumbnailCache.shared.cachedImage(path: thumbnailPath) ?? loaded

            if let nsImage = cached {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task(id: thumbnailPath) {
                        await loadThumbnailIfNeeded(path: thumbnailPath)
                    }
            }
        } else if let filePath {
            let icon = NSWorkspace.shared.icon(forFile: filePath)
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var isMarkdownPreview: Bool {
        guard model.isMarkdown else { return false }
        guard let filePath else { return false }
        guard kind == .other else { return false }
        guard FileManager.default.fileExists(atPath: filePath) else { return false }
        return FilePreviewSupport.isMarkdownFile(URL(fileURLWithPath: filePath))
    }

    private func previewWidth(maxWidth: CGFloat, maxHeight: CGFloat) -> CGFloat {
        guard kind == .video, let size = videoNaturalSize else { return maxWidth }
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let scale = min(maxWidth / width, maxHeight / height)
        return ceil(width * scale)
    }

    private func previewHeight(width: CGFloat) -> CGFloat {
        if kind != .image, let filePath, FileManager.default.fileExists(atPath: filePath) {
            if kind == .video, let size = videoNaturalSize {
                let naturalWidth = max(size.width, 1)
                let naturalHeight = max(size.height, 1)
                return ceil(width * (naturalHeight / naturalWidth))
            }
            return HoverPreviewScreenMetrics.maxPopoverHeightPoints()
        }

        let size: CGSize?
        if let cgImage = model.previewCGImage {
            size = CGSize(width: cgImage.width, height: cgImage.height)
        } else if let thumbnailPath {
            let loaded = lastLoadedPath == thumbnailPath ? loadedThumbnail : nil
            let cached = ThumbnailCache.shared.cachedImage(path: thumbnailPath) ?? loaded
            size = cached?.size
        } else if let filePath {
            let icon = NSWorkspace.shared.icon(forFile: filePath)
            size = icon.size
        } else {
            size = nil
        }

        guard let size else { return min(HoverPreviewScreenMetrics.maxPopoverHeightPoints(), 120) }

        let originalWidth = max(size.width, 1)
        let originalHeight = max(size.height, 1)
        let scaledHeight = width * (originalHeight / originalWidth)
        return ceil(scaledHeight)
    }

    @MainActor
    private func loadVideoNaturalSizeIfNeeded(path: String?) async {
        guard kind == .video else {
            videoNaturalSize = nil
            return
        }
        guard let path else {
            videoNaturalSize = nil
            return
        }
        let url = URL(fileURLWithPath: path)
        let size = await FilePreviewSupport.loadVideoNaturalSize(from: url)
        guard !Task.isCancelled else { return }
        videoNaturalSize = size
    }

    @MainActor
    private func loadThumbnailIfNeeded(path: String) async {
        if lastLoadedPath != path {
            loadedThumbnail = nil
            lastLoadedPath = path
        }

        if let cached = ThumbnailCache.shared.cachedImage(path: path) {
            loadedThumbnail = cached
            return
        }

        let image = await ThumbnailCache.shared.loadImage(path: path, priority: .userInitiated)
        guard !Task.isCancelled else { return }
        guard let image else { return }
        loadedThumbnail = image
    }
}
