import Foundation

public actor AsyncPermitPool {
    struct Snapshot: Sendable, Equatable {
        let activeCount: Int
        let queuedCount: Int
        let limit: Int
        let maxPending: Int?
    }

    private let limit: Int
    private let maxPending: Int?
    private let afterQueuedGrant: (@Sendable () async -> Void)?
    private var inUse = 0
    private var waitOrder: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    public init(
        limit: Int,
        maxPending: Int? = nil,
        afterQueuedGrant: (@Sendable () async -> Void)? = nil
    ) {
        self.limit = max(1, limit)
        if let maxPending {
            self.maxPending = max(0, maxPending)
        } else {
            self.maxPending = nil
        }
        self.afterQueuedGrant = afterQueuedGrant
    }

    public func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }

        if inUse < limit {
            inUse += 1
            return true
        }

        if let maxPending, waiters.count >= maxPending {
            return false
        }

        let waiterID = UUID()
        let granted = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }

                if inUse < limit {
                    inUse += 1
                    continuation.resume(returning: true)
                    return
                }

                if let maxPending, waiters.count >= maxPending {
                    continuation.resume(returning: false)
                    return
                }

                waitOrder.append(waiterID)
                waiters[waiterID] = continuation
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        })
        guard granted else { return false }

        if let afterQueuedGrant {
            await afterQueuedGrant()
        }
        guard !Task.isCancelled else {
            release()
            return false
        }
        return true
    }

    func queuedWaiterCount() -> Int {
        waiters.count
    }

    func snapshot() -> Snapshot {
        Snapshot(
            activeCount: inUse,
            queuedCount: waiters.count,
            limit: limit,
            maxPending: maxPending
        )
    }

    public func release() {
        while let waiterID = waitOrder.first {
            waitOrder.removeFirst()
            guard let continuation = waiters.removeValue(forKey: waiterID) else {
                continue
            }
            continuation.resume(returning: true)
            return
        }

        inUse = max(0, inUse - 1)
    }

    private func cancelWaiter(id: UUID) {
        if let index = waitOrder.firstIndex(of: id) {
            waitOrder.remove(at: index)
        }

        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(returning: false)
    }
}
