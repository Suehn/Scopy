import Foundation
import Observation

/// Owns the work that may publish a history projection. Query identity belongs to the
/// projection: refreshing its rows supersedes requests without changing where Undo restores.
@Observable
@MainActor
final class HistoryRequestLifecycle {
    struct Version: Equatable {
        fileprivate let generation: UInt64
    }

    private enum Operation {
        case replacement
        case pagination
        case refresh
    }

    private var activity: Operation?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var primaryTask: Task<Void, Never>?
    @ObservationIgnored private var refinementTask: Task<Void, Never>?

    /// A cancelled replacement can leave rows from the previous query on screen. A history
    /// event must restart that replacement instead of treating the old rows as a loaded page.
    @ObservationIgnored private(set) var replacementIsPending = false

    var version: Version { Version(generation: generation) }

    var isLoading: Bool {
        activity == .replacement || activity == .pagination
    }

    var hasPendingPage: Bool {
        activity == .pagination || activity == .refresh
    }

    func isCurrent(_ version: Version) -> Bool {
        !Task.isCancelled && version.generation == generation
    }

    @discardableResult
    func replace(
        perform: @escaping @MainActor (Version) async -> Void
    ) -> Task<Void, Never> {
        start(.replacement, perform: perform)
    }

    func refresh(perform: @escaping @MainActor (Version) async -> Void) {
        start(.refresh, perform: perform)
    }

    /// All callers share a pending page or refresh. A first-page replacement owns loading and
    /// cannot page the previous query's rows, even before its debounce has elapsed.
    func paginate(
        when permitted: Bool,
        perform: @escaping @MainActor (Version) async -> Void
    ) async {
        if hasPendingPage {
            await primaryTask?.value
            return
        }
        guard permitted, !isLoading else { return }
        await start(.pagination, perform: perform).value
    }

    /// A replacement or refresh owns a new generation. Pagination continues the current
    /// generation after its first page, retiring any staged refinement before it starts.
    @discardableResult
    private func start(
        _ operation: Operation,
        perform: @escaping @MainActor (Version) async -> Void
    ) -> Task<Void, Never> {
        if operation == .pagination {
            cancelRefinement()
        } else {
            cancel()
        }
        let version = self.version
        activity = operation
        if operation == .replacement { replacementIsPending = true }
        let task = Task {
            defer { finish(operation, version: version) }
            guard isCurrent(version) else { return }
            await perform(version)
        }
        primaryTask = task
        return task
    }

    @discardableResult
    func refine(
        version: Version,
        perform: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        cancelRefinement()
        let task = Task {
            guard isCurrent(version) else { return }
            await perform()
        }
        refinementTask = task
        return task
    }

    func waitForPrimary() async {
        await primaryTask?.value
    }

    func cancel() {
        generation &+= 1
        primaryTask?.cancel()
        primaryTask = nil
        cancelRefinement()
        activity = nil
    }

    private func finish(_ operation: Operation, version: Version) {
        guard version.generation == generation else { return }
        primaryTask = nil
        activity = nil
        if operation == .replacement { replacementIsPending = false }
    }

    private func cancelRefinement() {
        refinementTask?.cancel()
        refinementTask = nil
    }
}
