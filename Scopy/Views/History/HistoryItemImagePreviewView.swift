import SwiftUI
import ScopyKit
import AppKit

struct HistoryItemImagePreviewView: View {
    @ObservedObject var model: HoverPreviewModel
    let thumbnailPath: String?

    @State private var loadedThumbnail: NSImage?
    @State private var lastLoadedPath: String?

    var body: some View {
        if let imageData = model.imageData,
           let nsImage = NSImage(data: imageData) {
            previewImage(nsImage)
        } else if let thumbnailPath {
            let loaded = lastLoadedPath == thumbnailPath ? loadedThumbnail : nil
            let cached = ThumbnailCache.shared.cachedImage(path: thumbnailPath) ?? loaded

            if let nsImage = cached {
                previewImage(nsImage)
            } else {
                ProgressView()
                    .padding()
                    .task(id: thumbnailPath) {
                        await loadThumbnailIfNeeded(path: thumbnailPath)
                    }
            }
        } else {
            ProgressView()
                .padding()
        }
    }

    @ViewBuilder
    private func previewImage(_ nsImage: NSImage) -> some View {
        let maxWidth: CGFloat = ScopySize.Width.previewMax
        let maxHeight: CGFloat = 400

        let originalWidth = max(nsImage.size.width, 1)
        let originalHeight = max(nsImage.size.height, 1)

        let widthScale = maxWidth / originalWidth
        let heightScale = maxHeight / originalHeight
        let scale = min(widthScale, heightScale)

        let displayWidth = originalWidth * scale
        let displayHeight = originalHeight * scale

        Image(nsImage: nsImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: displayWidth, height: displayHeight)
            .padding(ScopySpacing.md)
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
