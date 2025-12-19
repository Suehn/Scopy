import SwiftUI
import ScopyKit
import ScopyUISupport
import AppKit

struct HistoryItemImagePreviewView: View {
    @ObservedObject var model: HoverPreviewModel
    let thumbnailPath: String?

    @State private var loadedThumbnail: NSImage?
    @State private var lastLoadedPath: String?

    var body: some View {
        let width: CGFloat = max(1, HoverPreviewScreenMetrics.maxPopoverWidthPoints())
        let maxHeight: CGFloat = HoverPreviewScreenMetrics.maxPopoverHeightPoints()

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
        .accessibilityIdentifier("History.Preview.Image")
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func previewContent() -> some View {
        if let cgImage = model.previewCGImage {
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
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func previewHeight(width: CGFloat) -> CGFloat {
        let size: CGSize?
        if let cgImage = model.previewCGImage {
            size = CGSize(width: cgImage.width, height: cgImage.height)
        } else if let thumbnailPath {
            let loaded = lastLoadedPath == thumbnailPath ? loadedThumbnail : nil
            let cached = ThumbnailCache.shared.cachedImage(path: thumbnailPath) ?? loaded
            size = cached?.size
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
