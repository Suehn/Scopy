import SwiftUI
import ScopyKit
import AppKit

struct HistoryItemImagePreviewView: View {
    @ObservedObject var model: HoverPreviewModel
    let thumbnailPath: String?

    @State private var loadedThumbnail: NSImage?
    @State private var lastLoadedPath: String?

    var body: some View {
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
        .frame(width: 400, height: 400)
        .padding(ScopySpacing.md)
    }

    private func previewImage(_ image: Image) -> some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fit)
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
