import AppKit
import ScopyKit
import ScopyUISupport
import SwiftUI

struct HistoryItemFileThumbnailView: View {
    let thumbnailPath: String?
    let height: CGFloat
    let kind: FilePreviewKind

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
                    .frame(width: height, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: ScopySize.Corner.sm))
                    .overlay(videoOverlay)
                    .padding(.leading, ScopySpacing.xs)
                    .padding(.vertical, ScopySpacing.xs)
                    .accessibilityIdentifier("History.Item.FileThumbnail")
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

    @ViewBuilder
    private var videoOverlay: some View {
        if kind == .video {
            Image(systemName: "play.circle.fill")
                .font(.system(size: max(12, height * 0.38)))
                .foregroundStyle(Color.white)
                .shadow(radius: 2)
                .padding(4)
        }
    }

    private var thumbnailPlaceholder: some View {
        ZStack {
            Color.clear

            Image(systemName: placeholderIconName)
                .foregroundStyle(Color.accentColor)
                .font(.system(size: max(12, height * 0.44)))
        }
        .frame(width: height, height: height)
        .padding(.leading, ScopySpacing.xs)
        .padding(.vertical, ScopySpacing.xs)
        .accessibilityIdentifier("History.Item.FileThumbnail")
    }

    private var placeholderIconName: String {
        switch kind {
        case .image:
            return ScopyIcons.image
        case .video:
            return "film"
        case .other:
            return ScopyIcons.file
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

        let image = await ThumbnailCache.shared.loadImage(path: path, priority: .userInitiated)
        guard !Task.isCancelled else { return }
        guard let image else { return }
        loadedThumbnail = image
    }
}
