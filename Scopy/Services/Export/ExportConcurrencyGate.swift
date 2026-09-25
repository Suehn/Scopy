import Foundation

@MainActor
final class MarkdownExportConcurrencyGate {
    enum Submission: Equatable {
        case started
        case queued
        case rejected
    }

    private struct PendingWork {
        let id: UUID
        let start: @MainActor () -> Void
    }

    let limit: Int
    let maximumPendingCount: Int
    private(set) var activeIDs: Set<UUID> = []
    private var pending: [PendingWork] = []

    init(limit: Int, maximumPendingCount: Int) {
        self.limit = max(1, limit)
        self.maximumPendingCount = max(0, maximumPendingCount)
    }

    var activeCount: Int { activeIDs.count }
    var pendingCount: Int { pending.count }

    func submit(id: UUID, start: @escaping @MainActor () -> Void) -> Submission {
        guard !activeIDs.contains(id), !pending.contains(where: { $0.id == id }) else {
            return .rejected
        }
        if activeIDs.count < limit {
            activeIDs.insert(id)
            start()
            return .started
        }
        guard pending.count < maximumPendingCount else { return .rejected }
        pending.append(PendingWork(id: id, start: start))
        return .queued
    }

    func finish(id: UUID) {
        if activeIDs.remove(id) != nil {
            promotePendingWorkIfPossible()
            return
        }
        pending.removeAll(where: { $0.id == id })
    }

    private func promotePendingWorkIfPossible() {
        while activeIDs.count < limit, !pending.isEmpty {
            let next = pending.removeFirst()
            activeIDs.insert(next.id)
            next.start()
        }
    }
}
