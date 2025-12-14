import SwiftUI
import ScopyKit
import AppKit

struct HistoryItemImagePreviewView: View {
    @ObservedObject var model: HoverPreviewModel
    let thumbnailPath: String?

    @State private var loadedThumbnail: NSImage?
    @State private var lastLoadedPath: String?

    var body: some View {
        let maxWidth: CGFloat = ScopySize.Width.previewMax
        let maxHeight: CGFloat = ScopySize.Window.mainHeight
        let size = displaySize(maxWidth: maxWidth, maxHeight: maxHeight)

        ZStack {
            if let cgImage = model.previewCGImage {
                previewImage(Image(decorative: cgImage, scale: 1.0))
            } else if let thumbnailPath {
                let loaded = lastLoadedPath == thumbnailPath ? loadedThumbnail : nil
                let cached = ThumbnailCache.shared.cachedImage(path: thumbnailPath) ?? loaded

                if let nsImage = cached {
                    previewImage(Image(nsImage: nsImage))
                } else {
                    ProgressView()
                        .task(id: thumbnailPath) {
                            await loadThumbnailIfNeeded(path: thumbnailPath)
                        }
                }
            } else {
                ProgressView()
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func previewImage(_ image: Image) -> some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fit)
    }

    private func displaySize(maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
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

        guard let size else {
            return CGSize(width: maxWidth, height: maxHeight)
        }

        let originalWidth = max(size.width, 1)
        let originalHeight = max(size.height, 1)

        let widthScale = maxWidth / originalWidth
        let heightScale = maxHeight / originalHeight
        let scale = min(widthScale, heightScale)

        return CGSize(width: originalWidth * scale, height: originalHeight * scale)
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
