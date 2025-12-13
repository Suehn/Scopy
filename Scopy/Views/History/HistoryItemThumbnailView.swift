import SwiftUI
import AppKit

struct HistoryItemThumbnailView: View {
    let thumbnailPath: String?
    let height: CGFloat

    @State private var loadedThumbnail: NSImage?
    @State private var lastLoadedPath: String?

    var body: some View {
        if let thumbnailPath {
            let loaded = lastLoadedPath == thumbnailPath ? loadedThumbnail : nil
            let cachedImage = ThumbnailCache.shared.cachedImage(path: thumbnailPath) ?? loaded

            if let nsImage = cachedImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: ScopySize.Corner.sm))
                    .padding(.leading, ScopySpacing.xs)
                    .padding(.vertical, ScopySpacing.xs)
            } else {
                thumbnailPlaceholder
                    .task(id: thumbnailPath) {
                        await loadThumbnailIfNeeded(path: thumbnailPath)
                    }
            }
        } else {
            thumbnailPlaceholder
        }
    }

    private var thumbnailPlaceholder: some View {
        Image(systemName: "photo")
            .frame(width: height, height: height)
            .padding(.leading, ScopySpacing.xs)
            .padding(.vertical, ScopySpacing.xs)
            .foregroundStyle(.green)
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
