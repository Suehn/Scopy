import ScopyKit
import AppKit
import SwiftUI

struct HistoryItemThumbnailView: View {
    let thumbnailPath: String?
    let height: CGFloat
    let interactionCoordinator: HistoryListInteractionCoordinator

    @State private var loadedThumbnail: NSImage?
    @State private var lastLoadedPath: String?

    var body: some View {
        if let thumbnailPath {
            let loaded = lastLoadedPath == thumbnailPath ? loadedThumbnail : nil
            let cachedImage = HistoryRowThumbnailLifecycleScheduler
                .productionCachedImage(for: thumbnailPath) ?? loaded

            if let nsImage = cachedImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: ScopySize.Corner.sm))
                    .padding(.leading, ScopySpacing.xs)
                    .padding(.vertical, ScopySpacing.xs)
                    .accessibilityIdentifier("History.Item.Thumbnail")
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
        Color.clear
            .frame(width: height, height: height)
            .padding(.leading, ScopySpacing.xs)
            .padding(.vertical, ScopySpacing.xs)
            .accessibilityIdentifier("History.Item.Thumbnail")
    }

    @MainActor
    private func loadThumbnailIfNeeded(path: String) async {
        if lastLoadedPath != path {
            loadedThumbnail = nil
            lastLoadedPath = path
        }

        let scheduler = HistoryRowThumbnailLifecycleScheduler(
            interactionCoordinator: interactionCoordinator
        )
        guard let result = await scheduler.loadCommitResult(for: path) else { return }
        guard lastLoadedPath == result.path, !Task.isCancelled else {
            return
        }
        loadedThumbnail = result.image
    }
}
