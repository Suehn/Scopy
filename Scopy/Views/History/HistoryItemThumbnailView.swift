import SwiftUI
import ScopyKit
import ScopyUISupport
import AppKit

struct HistoryItemThumbnailView: View {
    let thumbnailPath: String?
    let height: CGFloat
    let isScrolling: Bool

    @State private var loadedThumbnail: NSImage?
    @State private var lastLoadedPath: String?

    private struct TaskKey: Hashable {
        let path: String
        let isScrolling: Bool
    }

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
                if isScrolling {
                    thumbnailPlaceholder
                } else {
                    thumbnailPlaceholder
                        .task(id: TaskKey(path: thumbnailPath, isScrolling: isScrolling)) {
                            await loadThumbnailIfNeeded(path: thumbnailPath)
                        }
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

        let image = await ThumbnailCache.shared.loadImage(path: path, priority: .userInitiated)
        guard !Task.isCancelled else { return }
        guard let image else { return }
        loadedThumbnail = image
    }
}
