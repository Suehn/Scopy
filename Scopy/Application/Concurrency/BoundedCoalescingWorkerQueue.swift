import Foundation

/// Fixed-worker, finite-pending work ownership for background item enrichment.
/// Submitting work never creates a Task; only the configured workers own Tasks.
actor BoundedCoalescingWorkerQueue<Key: Hashable & Sendable, Work: Sendable, Output: Sendable> {
    enum Admission: Sendable {
        case accepted
        case coalescedPending(upgradedPriority: Bool)
        case coalescedActive
        case replacedOldestUtility(Key)
        case rejectedFull
        case rejectedStopped
    }

    struct Snapshot: Sendable {
        let isRunning: Bool
        let activeCount: Int
        let pendingCount: Int
        let workerCount: Int
        let waitingWorkerCount: Int
        let maxActiveCount: Int
        let maxPendingCount: Int
        let workerLimit: Int
        let pendingLimit: Int
        let activeKeys: [Key]
        let pendingKeys: [Key]
        let pendingPriorities: [BackgroundWorkPriority]
    }

    private struct Entry {
        let key: Key
        var work: Work
        var priority: BackgroundWorkPriority
        let sequence: UInt64
    }

    private struct WorkerWaiter {
        let id: UUID
        let generation: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    typealias Merge = @Sendable (_ existing: Work, _ incoming: Work) -> Work
    typealias Operation = @Sendable (_ work: Work, _ priority: BackgroundWorkPriority) async -> Output
    typealias Completion = @Sendable (_ mergedWork: Work, _ output: Output) async -> Void

    private let workerLimit: Int
    private let pendingLimit: Int
    private let merge: Merge
    private let operation: Operation
    private let completion: Completion

    private var isRunning = false
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var pendingOrder: [Key] = []
    private var pendingByKey: [Key: Entry] = [:]
    private var activeByKey: [Key: Entry] = [:]
    private var workerTasks: [UUID: Task<Void, Never>] = [:]
    private var workerWaiters: [WorkerWaiter] = []
    private var maxObservedActiveCount = 0
    private var maxObservedPendingCount = 0

    init(
        workerLimit: Int,
        pendingLimit: Int,
        merge: @escaping Merge,
        operation: @escaping Operation,
        completion: @escaping Completion
    ) {
        self.workerLimit = max(1, workerLimit)
        self.pendingLimit = max(1, pendingLimit)
        self.merge = merge
        self.operation = operation
        self.completion = completion
    }

    deinit {
        workerTasks.values.forEach { $0.cancel() }
        workerWaiters.forEach { $0.continuation.resume(returning: false) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1
        let workerGeneration = generation

        for _ in 0..<workerLimit {
            let workerID = UUID()
            workerTasks[workerID] = Task(priority: .utility) { [weak self] in
                await self?.workerLoop(id: workerID, generation: workerGeneration)
            }
        }
    }

    @discardableResult
    func submit(key: Key, work: Work, priority: BackgroundWorkPriority) -> Admission {
        guard isRunning else { return .rejectedStopped }

        if var active = activeByKey[key] {
            active.work = merge(active.work, work)
            active.priority = max(active.priority, priority)
            activeByKey[key] = active
            return .coalescedActive
        }

        if var pending = pendingByKey[key] {
            let upgraded = priority > pending.priority
            pending.work = merge(pending.work, work)
            pending.priority = max(pending.priority, priority)
            pendingByKey[key] = pending
            return .coalescedPending(upgradedPriority: upgraded)
        }

        var replacedKey: Key?
        if pendingByKey.count >= pendingLimit {
            guard priority == .userInitiated,
                  let utilityIndex = pendingOrder.firstIndex(where: { pendingByKey[$0]?.priority == .utility }) else {
                return .rejectedFull
            }
            let oldestUtilityKey = pendingOrder.remove(at: utilityIndex)
            pendingByKey.removeValue(forKey: oldestUtilityKey)
            replacedKey = oldestUtilityKey
        }

        sequence &+= 1
        let entry = Entry(key: key, work: work, priority: priority, sequence: sequence)
        pendingOrder.append(key)
        pendingByKey[key] = entry
        maxObservedPendingCount = max(maxObservedPendingCount, pendingByKey.count)
        wakeOneWorker()

        if let replacedKey {
            return .replacedOldestUtility(replacedKey)
        }
        return .accepted
    }

    @discardableResult
    func cancelPending(key: Key) -> Bool {
        guard pendingByKey.removeValue(forKey: key) != nil else { return false }
        pendingOrder.removeAll { $0 == key }
        return true
    }

    @discardableResult
    func cancelPending(where shouldCancel: @Sendable (Key) -> Bool) -> [Key] {
        let cancelledKeys = pendingOrder.filter(shouldCancel)
        guard !cancelledKeys.isEmpty else { return [] }
        let cancelledSet = Set(cancelledKeys)
        pendingOrder.removeAll { cancelledSet.contains($0) }
        for key in cancelledKeys {
            pendingByKey.removeValue(forKey: key)
        }
        return cancelledKeys
    }

    func discardPending() {
        pendingOrder.removeAll(keepingCapacity: true)
        pendingByKey.removeAll(keepingCapacity: true)
    }

    func stop() async {
        guard isRunning || !workerTasks.isEmpty else {
            pendingOrder.removeAll(keepingCapacity: true)
            pendingByKey.removeAll(keepingCapacity: true)
            activeByKey.removeAll(keepingCapacity: true)
            return
        }

        isRunning = false
        generation &+= 1
        pendingOrder.removeAll(keepingCapacity: true)
        pendingByKey.removeAll(keepingCapacity: true)
        activeByKey.removeAll(keepingCapacity: true)

        let waiters = workerWaiters
        workerWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.continuation.resume(returning: false) }

        let tasks = Array(workerTasks.values)
        workerTasks.removeAll(keepingCapacity: true)
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
    }

    func snapshot() -> Snapshot {
        let orderedEntries = pendingOrder.compactMap { pendingByKey[$0] }
        return Snapshot(
            isRunning: isRunning,
            activeCount: activeByKey.count,
            pendingCount: pendingByKey.count,
            workerCount: workerTasks.count,
            waitingWorkerCount: workerWaiters.count,
            maxActiveCount: maxObservedActiveCount,
            maxPendingCount: maxObservedPendingCount,
            workerLimit: workerLimit,
            pendingLimit: pendingLimit,
            activeKeys: Array(activeByKey.keys),
            pendingKeys: orderedEntries.map(\.key),
            pendingPriorities: orderedEntries.map(\.priority)
        )
    }

    private func workerLoop(id: UUID, generation workerGeneration: UInt64) async {
        while !Task.isCancelled,
              let entry = await nextEntry(workerID: id, generation: workerGeneration) {
            let output = await operation(entry.work, entry.priority)
            guard let mergedEntry = finishEntry(key: entry.key, generation: workerGeneration) else {
                continue
            }
            await completion(mergedEntry.work, output)
        }
        workerTasks.removeValue(forKey: id)
    }

    private func nextEntry(workerID: UUID, generation workerGeneration: UInt64) async -> Entry? {
        while isRunning, workerGeneration == generation, !Task.isCancelled {
            if let entry = popNextEntry() {
                activeByKey[entry.key] = entry
                maxObservedActiveCount = max(maxObservedActiveCount, activeByKey.count)
                return entry
            }

            let shouldContinue = await suspendWorker(id: workerID, generation: workerGeneration)
            guard shouldContinue else { return nil }
        }
        return nil
    }

    private func popNextEntry() -> Entry? {
        guard !pendingOrder.isEmpty else { return nil }
        let nextIndex = pendingOrder.firstIndex(where: { pendingByKey[$0]?.priority == .userInitiated }) ?? 0
        let key = pendingOrder.remove(at: nextIndex)
        return pendingByKey.removeValue(forKey: key)
    }

    private func finishEntry(key: Key, generation workerGeneration: UInt64) -> Entry? {
        guard isRunning, workerGeneration == generation else { return nil }
        return activeByKey.removeValue(forKey: key)
    }

    private func suspendWorker(id: UUID, generation workerGeneration: UInt64) async -> Bool {
        guard isRunning, workerGeneration == generation, !Task.isCancelled else { return false }
        let waiterID = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard isRunning, workerGeneration == generation, !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                workerWaiters.append(
                    WorkerWaiter(id: waiterID, generation: workerGeneration, continuation: continuation)
                )
            }
        }, onCancel: {
            Task { await self.cancelWorkerWaiter(id: waiterID) }
        })
    }

    private func wakeOneWorker() {
        while !workerWaiters.isEmpty {
            let waiter = workerWaiters.removeFirst()
            guard waiter.generation == generation else {
                waiter.continuation.resume(returning: false)
                continue
            }
            waiter.continuation.resume(returning: true)
            return
        }
    }

    private func cancelWorkerWaiter(id: UUID) {
        guard let index = workerWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = workerWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}
