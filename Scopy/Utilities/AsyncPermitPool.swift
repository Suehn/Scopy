import Foundation

actor AsyncPermitPool {
    private let limit: Int
    private var inUse = 0
    private var waitOrder: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async -> Bool {
        if inUse < limit {
            inUse += 1
            return true
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if inUse < limit {
                    inUse += 1
                    continuation.resume(returning: true)
                    return
                }

                waitOrder.append(waiterID)
                waiters[waiterID] = continuation
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        })
    }

    func release() {
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
