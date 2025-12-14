import SwiftUI
import ScopyKit
import AppKit

struct HistoryItemImagePreviewView: View {
    let previewImageData: Data?
    let thumbnailPath: String?

    @State private var loadedThumbnail: NSImage?
    @State private var lastLoadedPath: String?

    var body: some View {
        if let imageData = previewImageData,
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
        let originalWidth = nsImage.size.width
        let originalHeight = nsImage.size.height
        let safeHeight = max(originalHeight, 1)

        if originalWidth <= maxWidth {
            Image(nsImage: nsImage)
                .padding(ScopySpacing.md)
        } else {
            let aspectRatio = originalWidth / safeHeight
            let displayWidth = maxWidth
            let displayHeight = displayWidth / max(aspectRatio, 0.01)

            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: displayWidth, height: displayHeight)
                .padding(ScopySpacing.md)
        }
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

        let image = await ThumbnailCache.shared.loadImage(path: path)
        guard !Task.isCancelled else { return }
        guard let image else { return }
        loadedThumbnail = image
    }
}
