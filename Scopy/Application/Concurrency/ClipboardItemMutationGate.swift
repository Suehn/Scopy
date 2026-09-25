import Foundation

/// Serializes the small set of same-item mutations whose semantic events are derived from final
/// state (currently pin/unpin). The lease is cancellation-safe and leaves no per-item entry once
/// the owner and its waiters are gone.
actor ClipboardItemMutationGate {
    struct Lease: Sendable {
        let id: UUID
        let itemID: UUID
    }

    private struct Waiter {
        let id: UUID
        let itemID: UUID
        let continuation: CheckedContinuation<Lease?, Never>
    }

    private var owners: [UUID: UUID] = [:]
    private var waitersByItemID: [UUID: [Waiter]] = [:]
    private let maxPendingCount = 64
    private var pendingCount = 0

    func acquire(itemID: UUID) async -> Lease? {
        guard !Task.isCancelled else { return nil }
        let requestID = UUID()
        let lease: Lease? = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                if owners[itemID] == nil {
                    owners[itemID] = requestID
                    continuation.resume(returning: Lease(id: requestID, itemID: itemID))
                } else {
                    guard pendingCount < maxPendingCount else {
                        continuation.resume(returning: nil)
                        return
                    }
                    waitersByItemID[itemID, default: []].append(
                        Waiter(id: requestID, itemID: itemID, continuation: continuation)
                    )
                    pendingCount += 1
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id: requestID, itemID: itemID) }
        })

        guard let lease else { return nil }
        guard !Task.isCancelled else {
            release(lease)
            return nil
        }
        return lease
    }

    func release(_ lease: Lease) {
        guard owners[lease.itemID] == lease.id else { return }
        if var waiters = waitersByItemID[lease.itemID], !waiters.isEmpty {
            let next = waiters.removeFirst()
            pendingCount = max(0, pendingCount - 1)
            if waiters.isEmpty {
                waitersByItemID.removeValue(forKey: lease.itemID)
            } else {
                waitersByItemID[lease.itemID] = waiters
            }
            owners[lease.itemID] = next.id
            next.continuation.resume(returning: Lease(id: next.id, itemID: next.itemID))
        } else {
            owners.removeValue(forKey: lease.itemID)
            waitersByItemID.removeValue(forKey: lease.itemID)
        }
    }

    private func cancelWaiter(id: UUID, itemID: UUID) {
        guard var waiters = waitersByItemID[itemID],
              let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        pendingCount = max(0, pendingCount - 1)
        if waiters.isEmpty {
            waitersByItemID.removeValue(forKey: itemID)
        } else {
            waitersByItemID[itemID] = waiters
        }
        waiter.continuation.resume(returning: nil)
    }
}
