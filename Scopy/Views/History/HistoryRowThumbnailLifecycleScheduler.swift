import AppKit
import ScopyUISupport

@MainActor
struct HistoryRowThumbnailLifecycleScheduler {
    enum CommitSource: Equatable {
        case cacheHit
        case loaded
    }

    struct CommitResult {
        let path: String
        let image: NSImage
        let source: CommitSource
    }

    struct Dependencies {
        var cachedImage: (String) -> NSImage?
        var loadImage: (String, TaskPriority) async -> NSImage?
        var isScrolling: () -> Bool
        var sleep: (UInt64) async -> Void
        var isCancelled: () -> Bool
    }

    private static let scrollSettleSleepNanoseconds: UInt64 = 80_000_000
    private static let maxScrollSettleAttempts = 20

    private let dependencies: Dependencies

    init(interactionCoordinator: HistoryListInteractionCoordinator) {
        self.init(
            dependencies: Dependencies(
                cachedImage: { ThumbnailCache.shared.cachedImage(path: $0) },
                loadImage: { path, priority in
                    await ThumbnailCache.shared.loadImage(path: path, priority: priority)
                },
                isScrolling: { interactionCoordinator.isScrolling },
                sleep: { nanoseconds in try? await Task.sleep(nanoseconds: nanoseconds) },
                isCancelled: { Task.isCancelled }
            )
        )
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    static func productionCachedImage(for path: String) -> NSImage? {
        ThumbnailCache.shared.cachedImage(path: path)
    }

    func cachedImage(for path: String) -> NSImage? {
        dependencies.cachedImage(path)
    }

    func loadCommitResult(for path: String) async -> CommitResult? {
        if let cached = dependencies.cachedImage(path) {
            return CommitResult(path: path, image: cached, source: .cacheHit)
        }

        guard !dependencies.isCancelled() else { return nil }

        let priority: TaskPriority = dependencies.isScrolling() ? .utility : .userInitiated
        guard let image = await dependencies.loadImage(path, priority) else { return nil }
        guard !dependencies.isCancelled() else { return nil }

        await waitForScrollingToSettleIfNeeded()
        guard !dependencies.isCancelled() else { return nil }

        return CommitResult(path: path, image: image, source: .loaded)
    }

    private func waitForScrollingToSettleIfNeeded() async {
        for _ in 0..<Self.maxScrollSettleAttempts where dependencies.isScrolling() {
            await dependencies.sleep(Self.scrollSettleSleepNanoseconds)
            if dependencies.isCancelled() { return }
        }
    }
}
