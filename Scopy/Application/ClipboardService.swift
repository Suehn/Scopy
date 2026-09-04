import AppKit
import Foundation

enum BackgroundWorkPriority: Int, Sendable, Comparable {
    case utility
    case userInitiated

    static func < (lhs: BackgroundWorkPriority, rhs: BackgroundWorkPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var taskPriority: TaskPriority {
        switch self {
        case .utility:
            return .utility
        case .userInitiated:
            return .userInitiated
        }
    }
}

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

struct BoundedRetryTimestamps<Key: Hashable & Sendable>: Sendable {
    private let capacity: Int
    private var timestamps: [Key: Date] = [:]
    private var order: [Key] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { timestamps.count }

    mutating func containsRecent(_ key: Key, now: Date, interval: TimeInterval) -> Bool {
        prune(olderThan: now.addingTimeInterval(-max(0, interval)))
        guard let timestamp = timestamps[key] else { return false }
        return now.timeIntervalSince(timestamp) < interval
    }

    mutating func record(_ key: Key, at timestamp: Date) {
        if timestamps[key] != nil {
            order.removeAll { $0 == key }
        }
        timestamps[key] = timestamp
        order.append(key)

        while timestamps.count > capacity, !order.isEmpty {
            let evicted = order.removeFirst()
            timestamps.removeValue(forKey: evicted)
        }
    }

    mutating func remove(_ key: Key) {
        timestamps.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    mutating func remove(where shouldRemove: (Key) -> Bool) {
        let removedKeys = order.filter(shouldRemove)
        guard !removedKeys.isEmpty else { return }
        let removedSet = Set(removedKeys)
        order.removeAll { removedSet.contains($0) }
        for key in removedKeys {
            timestamps.removeValue(forKey: key)
        }
    }

    mutating func prune(olderThan cutoff: Date) {
        while let oldest = order.first,
              let timestamp = timestamps[oldest],
              timestamp < cutoff {
            order.removeFirst()
            timestamps.removeValue(forKey: oldest)
        }
    }

    mutating func removeAll() {
        timestamps.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }
}

actor ClipboardEventQueue {
    struct PublicationToken: Sendable, Equatable {
        let itemID: UUID
        let sequence: UInt64
        let clearGeneration: UInt64
    }

    private struct PublicationState {
        var highestSequence: UInt64
        var outstanding: Set<UInt64>
    }

    private struct ReceiverWaiter {
        let id: UUID
        let continuation: CheckedContinuation<ClipboardEvent?, Never>
    }

    private struct SenderWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private let capacity: Int
    private var buffer: [ClipboardEvent?]
    private var headIndex = 0
    private var tailIndex = 0
    private var bufferedCount = 0
    private var isFinished = false
    private var nextSequence: UInt64 = 0
    private var clearGeneration: UInt64 = 0
    private var publications: [UUID: PublicationState] = [:]
    private var waitingReceivers: [ReceiverWaiter] = []
    private var waitingSenders: [SenderWaiter] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.buffer = Array(repeating: nil, count: max(1, capacity))
    }

    func reservePublication(itemID: UUID) -> PublicationToken {
        nextSequence &+= 1
        let token = PublicationToken(
            itemID: itemID,
            sequence: nextSequence,
            clearGeneration: clearGeneration
        )
        var state = publications[itemID] ?? PublicationState(
            highestSequence: token.sequence,
            outstanding: []
        )
        state.highestSequence = max(state.highestSequence, token.sequence)
        state.outstanding.insert(token.sequence)
        publications[itemID] = state
        return token
    }

    func advanceClearGeneration() {
        clearGeneration &+= 1
        publications.removeAll(keepingCapacity: true)
    }

    /// Invalidates only publications for rows a bulk cleanup actually deleted. Older suspended
    /// per-item senders then fail `isLatest`, while unrelated item publications remain intact.
    func invalidatePublications(itemIDs: [UUID]) {
        guard !itemIDs.isEmpty else { return }
        for itemID in Set(itemIDs) {
            publications.removeValue(forKey: itemID)
        }
    }

    func discardPublication(_ token: PublicationToken) {
        abandonPublication(token)
    }

    @discardableResult
    func enqueue(_ event: ClipboardEvent, publication token: PublicationToken? = nil) async -> Bool {
        guard !isFinished, !Task.isCancelled else {
            if let token { abandonPublication(token) }
            return false
        }

        while bufferedCount >= capacity, !isFinished {
            guard !Task.isCancelled else {
                if let token { abandonPublication(token) }
                return false
            }
            let waiterID = UUID()
            await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
                    waitingSenders.append(SenderWaiter(id: waiterID, continuation: continuation))
                }
            }, onCancel: {
                Task { await self.cancelSender(id: waiterID) }
            })
        }

        guard !isFinished, !Task.isCancelled else {
            if let token { abandonPublication(token) }
            return false
        }
        if let token, !isLatest(token) {
            completePublication(token)
            wakeOneSenderIfCapacityAvailable()
            return false
        }

        if !waitingReceivers.isEmpty {
            let receiver = waitingReceivers.removeFirst()
            receiver.continuation.resume(returning: event)
        } else {
            buffer[tailIndex] = event
            tailIndex = (tailIndex + 1) % capacity
            bufferedCount += 1
        }
        if let token { completePublication(token) }
        return true
    }

    func dequeue() async -> ClipboardEvent? {
        if bufferedCount > 0 {
            let event = buffer[headIndex]
            buffer[headIndex] = nil
            headIndex = (headIndex + 1) % capacity
            bufferedCount -= 1
            wakeOneSenderIfCapacityAvailable()
            return event
        }
        guard !isFinished, !Task.isCancelled else { return nil }

        let waiterID = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                waitingReceivers.append(ReceiverWaiter(id: waiterID, continuation: continuation))
            }
        }, onCancel: {
            Task { await self.cancelReceiver(id: waiterID) }
        })
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        publications.removeAll(keepingCapacity: false)
        let receivers = waitingReceivers
        waitingReceivers.removeAll()
        receivers.forEach { $0.continuation.resume(returning: nil) }
        let senders = waitingSenders
        waitingSenders.removeAll()
        senders.forEach { $0.continuation.resume() }
    }

    private func isLatest(_ token: PublicationToken) -> Bool {
        guard token.clearGeneration == clearGeneration,
              let state = publications[token.itemID] else { return false }
        return token.sequence == state.highestSequence && state.outstanding.contains(token.sequence)
    }

    /// Retires a publication that did deliver an event. The watermark stays where it is so the
    /// publications this one superseded remain stale.
    private func completePublication(_ token: PublicationToken) {
        guard var state = publications[token.itemID] else { return }
        state.outstanding.remove(token.sequence)
        if state.outstanding.isEmpty {
            publications.removeValue(forKey: token.itemID)
        } else {
            publications[token.itemID] = state
        }
    }

    /// Retires a publication that delivered nothing (authoritative state could not be built, or
    /// the queue was cancelled). Unlike a completed publication it must give the watermark back:
    /// otherwise the publications it superseded also fail `isLatest`, and an item whose row did
    /// change reaches the UI through no event at all until the next full reload.
    private func abandonPublication(_ token: PublicationToken) {
        guard var state = publications[token.itemID] else { return }
        state.outstanding.remove(token.sequence)
        guard !state.outstanding.isEmpty else {
            publications.removeValue(forKey: token.itemID)
            return
        }
        if state.highestSequence == token.sequence,
           let highestRemaining = state.outstanding.max() {
            state.highestSequence = highestRemaining
        }
        publications[token.itemID] = state
    }

    private func wakeOneSenderIfCapacityAvailable() {
        guard bufferedCount < capacity, !waitingSenders.isEmpty else { return }
        let sender = waitingSenders.removeFirst()
        sender.continuation.resume()
    }

    private func cancelReceiver(id: UUID) {
        guard let index = waitingReceivers.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waitingReceivers.remove(at: index)
        waiter.continuation.resume(returning: nil)
    }

    private func cancelSender(id: UUID) {
        guard let index = waitingSenders.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waitingSenders.remove(at: index)
        waiter.continuation.resume()
    }
}

/// Serializes the small set of same-item mutations whose semantic events are derived from final
/// state (currently pin/unpin). The lease is cancellation-safe and leaves no per-item entry once
/// the owner and its waiters are gone.
private actor ClipboardItemMutationGate {
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

/// Application 层门面（vNext）：统一组合 monitor/storage/search/settings，并由 actor 持有事件 continuation。
///
/// 说明（Phase 4 约束）：
/// - `ClipboardMonitor` / `StorageService` 为 `@MainActor`，因此该 actor 在内部通过 `MainActor.run {}` 或跨 MainActor 调用处理边界。
/// - UI 仍通过 `@MainActor ClipboardServiceProtocol` 调用 `RealClipboardService`（adapter），由 adapter 转发到该 actor。
actor ClipboardService {
    // MARK: - Types

    enum ClipboardServiceError: Error, LocalizedError {
        case notStarted
        case itemNotFoundOrSuperseded

        var errorDescription: String? {
            switch self {
            case .notStarted:
                return "ClipboardService is not started"
            case .itemNotFoundOrSuperseded:
                return "Clipboard item no longer exists or was superseded"
            }
        }
    }

    enum ImageOptimizationInterlockPoint: Sendable {
        case afterExternalSourceLeaseBeforeValidation
        case afterExternalPayloadCommit
        case afterExternalSourceAdoptionBeforeVerification(attempt: Int)
        case beforeSearchPublication
    }

    enum MetadataPublicationInterlockPoint: Sendable {
        case afterNoteCommit
        case afterNoteDTOConstructionBeforeEvent
        case afterFileSizeCommit
        case afterFileSizeDTOConstructionBeforeEvent
    }

    private enum ExternalSourceReconciliationResult: Sendable {
        case adopted
        case sourceUnavailable
        case failedOrUnstable
    }

    private enum AuthoritativePublicationKind: Sendable {
        case newItem
        case itemUpdated
        case contentUpdated
        case pinState
    }

    struct ImageOptimizationAdmissionSnapshot: Sendable, Equatable {
        let admittedRequestCount: Int
        let activeProcessCount: Int
        let queuedRequestCount: Int
        let requestCapacity: Int
    }

    struct BackgroundMediaSchedulingSnapshot: Sendable, Equatable {
        let thumbnailActiveCount: Int
        let thumbnailPendingCount: Int
        let thumbnailWorkerCount: Int
        let thumbnailMaxActiveCount: Int
        let thumbnailMaxPendingCount: Int
        let fileSizeActiveCount: Int
        let fileSizePendingCount: Int
        let fileSizeWorkerCount: Int
        let fileSizeMaxActiveCount: Int
        let fileSizeMaxPendingCount: Int
        let fileSizeRetryTimestampCount: Int
    }

    private struct ThumbnailGenerationKey: Hashable, Sendable {
        let typeNamespace: String
        let contentHash: String
    }

    private struct ThumbnailGenerationWork: Sendable {
        let item: StorageService.StoredItem
        let itemIDs: Set<UUID>
        let maxHeight: Int
        let externalStorageRoot: String
        let thumbnailCacheRoot: String
    }

    private typealias ThumbnailWorkQueue = BoundedCoalescingWorkerQueue<
        ThumbnailGenerationKey,
        ThumbnailGenerationWork,
        String?
    >

    private struct FileSizeComputationWork: Sendable {
        let expected: StorageService.StoredItem
    }

    private struct FileSizeComputationKey: Hashable, Sendable {
        let itemID: UUID
        let typeNamespace: String
        let contentHash: String
        let plainText: String
        let sizeBytes: Int
        let storageRef: String?
        let rawData: Data?

        init(expected: StorageService.StoredItem) {
            self.itemID = expected.id
            self.typeNamespace = expected.type.rawValue
            self.contentHash = expected.contentHash
            self.plainText = expected.plainText
            self.sizeBytes = expected.sizeBytes
            self.storageRef = expected.storageRef
            self.rawData = expected.rawData
        }
    }

    private struct FileSizeComputationResult: Sendable {
        let expected: StorageService.StoredItem
        let fileSizeBytes: Int
    }

    private typealias FileSizeWorkQueue = BoundedCoalescingWorkerQueue<
        FileSizeComputationKey,
        FileSizeComputationWork,
        FileSizeComputationResult?
    >

    // MARK: - Properties

    nonisolated let eventStream: AsyncStream<ClipboardEvent>

    private let databasePath: String?
    private let settingsStore: SettingsStore
    private let monitorPasteboardName: String?
    private let monitorPollingInterval: TimeInterval?
    private let imageOptimizationInterlock: (@Sendable (ImageOptimizationInterlockPoint, UUID) async -> Void)?
    private let metadataPublicationInterlock: (@Sendable (MetadataPublicationInterlockPoint, UUID) async -> Void)?

    private var monitor: ClipboardMonitor?
    private var storage: StorageService?
    private var search: SearchEngineImpl?

    private var settings: SettingsDTO = .default

    struct ThumbnailCacheIndex: Sendable {
        let root: String
        private(set) var filenames: Set<String>

        mutating func pathIfExists(filename: String) -> String? {
            pathIfExists(filename: filename, fileExists: FileManager.default.fileExists(atPath:))
        }

        mutating func pathIfExists(filename: String, fileExists: (String) -> Bool) -> String? {
            guard filenames.contains(filename) else { return nil }

            let path = (root as NSString).appendingPathComponent(filename)
            guard fileExists(path) else {
                filenames.remove(filename)
                return nil
            }
            return path
        }

        mutating func remember(filename: String) {
            filenames.insert(filename)
        }
    }

    private var thumbnailCacheIndex: ThumbnailCacheIndex?
    private var thumbnailCacheIndexTask: Task<Void, Never>?
    private var thumbnailCacheIndexGeneration: UInt64 = 0

    private let eventQueue: ClipboardEventQueue
    private let itemMutationGate = ClipboardItemMutationGate()
    private var monitorTask: Task<Void, Never>?
    private var isStarted = false

    // MARK: - Cleanup Scheduling (v0.26)

    private var cleanupTask: Task<Void, Never>?
    private var isCleanupRunning = false
    private var lastLightCleanupAt: Date = .distantPast
    private var lastFullCleanupAt: Date = .distantPast
    private let lightCleanupInterval: TimeInterval = 60
    private let fullCleanupInterval: TimeInterval = 3600
    private let cleanupDebounceDelay: TimeInterval = 2.0

    // MARK: - File Size Computation

    private let fileSizeComputationRetryInterval: TimeInterval = 3 * 3600
    private let maxConcurrentFileSizeComputations = 2
    private let maxPendingFileSizeComputations = 256
    private var fileSizeComputationQueue: FileSizeWorkQueue?
    private var fileSizeComputationLastAttemptAt = BoundedRetryTimestamps<FileSizeComputationKey>(capacity: 512)

    // MARK: - Thumbnail Generation

    private let maxConcurrentThumbnailGenerations = 2
    private let maxPendingThumbnailGenerations = 128
    private var thumbnailGenerationQueue: ThumbnailWorkQueue?

    // MARK: - Image Optimization

    private let maxActiveImageOptimizationRequests = 6
    private let imageOptimizationPermitPool = AsyncPermitPool(limit: 2, maxPending: 4)
    private var imageOptimizationInProgress = Set<UUID>()

    // MARK: - Initialization

    init(
        databasePath: String? = nil,
        settingsStore: SettingsStore = .shared,
        monitorPasteboardName: String? = nil,
        monitorPollingInterval: TimeInterval? = nil,
        imageOptimizationInterlock: (@Sendable (ImageOptimizationInterlockPoint, UUID) async -> Void)? = nil,
        metadataPublicationInterlock: (@Sendable (MetadataPublicationInterlockPoint, UUID) async -> Void)? = nil
    ) {
        self.databasePath = databasePath
        self.settingsStore = settingsStore
        self.monitorPasteboardName = monitorPasteboardName
        self.monitorPollingInterval = monitorPollingInterval
        self.imageOptimizationInterlock = imageOptimizationInterlock
        self.metadataPublicationInterlock = metadataPublicationInterlock

        let queue = ClipboardEventQueue(capacity: ScopyThresholds.clipboardEventStreamMaxBufferedItems)
        self.eventQueue = queue
        self.eventStream = AsyncStream(unfolding: { await queue.dequeue() })
    }

    deinit {
        monitorTask?.cancel()
        cleanupTask?.cancel()
        if let thumbnailGenerationQueue {
            Task.detached {
                await thumbnailGenerationQueue.stop()
            }
        }
        if let fileSizeComputationQueue {
            Task.detached {
                await fileSizeComputationQueue.stop()
            }
        }
        Task { [eventQueue] in
            await eventQueue.finish()
        }
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard !isStarted else { return }

        let loadedSettings = await settingsStore.load()

        let pasteboardName = monitorPasteboardName
        let pollingInterval = monitorPollingInterval ?? (TimeInterval(loadedSettings.clipboardPollingIntervalMs) / 1000.0)
        let storage = await MainActor.run { StorageService(databasePath: databasePath) }
        let ingestSpoolDirectory = URL(
            fileURLWithPath: storage.ingestSpoolDirectoryPath,
            isDirectory: true
        )
        let legacyIngestSpoolDirectory = databasePath == nil
            ? ClipboardMonitor.defaultLegacyIngestSpoolDirectory()
            : nil

        await Task.detached(priority: .utility) {
            ClipboardMonitor.prepareIngestSpoolDirectory(
                ingestSpoolDirectory,
                legacyDirectory: legacyIngestSpoolDirectory
            )
            Self.sweepStaleShareableImages()
        }.value

        let monitor = await MainActor.run {
            let pasteboard: NSPasteboard
            if let pasteboardName, !pasteboardName.isEmpty {
                pasteboard = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
            } else {
                pasteboard = .general
            }
            return ClipboardMonitor(
                pasteboard: pasteboard,
                pollingInterval: pollingInterval,
                ingestSpoolDirectory: ingestSpoolDirectory,
                legacyIngestSpoolDirectory: legacyIngestSpoolDirectory,
                spoolAlreadyPrepared: true
            )
        }

        let dbPath = await storage.databaseFilePath
        let search = SearchEngineImpl(dbPath: dbPath)

        do {
            try await storage.open()
            try await search.open()

            var deferredTerminalIngestIDs = Set<UUID>()
            while true {
                let excludedIDs = deferredTerminalIngestIDs
                let terminalAcknowledgements = await MainActor.run {
                    monitor.pendingTerminalIngestAcknowledgements(
                        limit: 256,
                        excluding: excludedIDs
                    )
                }
                guard !terminalAcknowledgements.isEmpty else { break }
                for acknowledgement in terminalAcknowledgements {
                    do {
                        try await storage.removeIngestReceipt(acknowledgement.ingestID)
                        let completed = await MainActor.run {
                            monitor.completeTerminalIngestAcknowledgement(acknowledgement)
                        }
                        if !completed {
                            deferredTerminalIngestIDs.insert(acknowledgement.ingestID)
                        }
                    } catch {
                        deferredTerminalIngestIDs.insert(acknowledgement.ingestID)
                        ScopyLog.app.warning(
                            "Failed to finish terminal ingest recovery: \(error.localizedDescription, privacy: .private)"
                        )
                    }
                }
                await Task.yield()
            }

            await MainActor.run {
                storage.cleanupSettings.maxItems = loadedSettings.maxItems
                storage.cleanupSettings.maxSmallStorageMB = loadedSettings.maxStorageMB
                storage.cleanupSettings.cleanupImagesOnly = loadedSettings.cleanupImagesOnly
                monitor.startMonitoring()
            }

            let monitorTask = Task { [weak self] in
                guard let self else { return }
                guard let stream = await self.getMonitorStream() else { return }
                for await content in stream {
                    guard !Task.isCancelled else { break }
                    await self.handleNewContent(content)
                }
            }

            self.settings = loadedSettings
            self.monitor = monitor
            self.storage = storage
            self.search = search
            self.monitorTask = monitorTask
            self.isStarted = true

            await startBackgroundMediaQueuesIfNeeded()

            scheduleThumbnailCacheIndexBuildIfNeeded(thumbnailCacheRoot: storage.thumbnailCacheDirectoryPath)

            Task { [storage] in
                try? await storage.cleanupOrphanedFiles()
            }
        } catch {
            await MainActor.run {
                monitor.stopMonitoring()
            }
            await storage.close()
            await search.close()
            throw error
        }
    }

    func stop() async {
        guard isStarted else { return }
        isStarted = false

        let monitor = monitor
        let storage = storage
        let search = search

        await stopBackgroundMediaQueues()

        self.monitor = nil
        self.storage = nil
        self.search = nil
        thumbnailCacheIndex = nil

        thumbnailCacheIndexTask?.cancel()
        thumbnailCacheIndexTask = nil

        monitorTask?.cancel()
        monitorTask = nil

        cleanupTask?.cancel()
        cleanupTask = nil

        if let monitor {
            await MainActor.run {
                monitor.stopMonitoring()
            }
        }

        if let storage {
            await storage.close()
        }

        if let search {
            await search.close()
        }
    }

    // MARK: - Data Access

    func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
        let storage = try requireStorage()
        let items = try await storage.fetchRecent(limit: limit, offset: offset)
        var dtos: [ClipboardItemDTO] = []
        dtos.reserveCapacity(items.count)
        for item in items {
            dtos.append(await toDTO(item, storage: storage))
        }
        return dtos
    }

    func fetchPinned() async throws -> [ClipboardItemDTO] {
        let storage = try requireStorage()
        let items = try await storage.fetchPinned()
        var dtos: [ClipboardItemDTO] = []
        dtos.reserveCapacity(items.count)
        for item in items {
            dtos.append(await toDTO(item, storage: storage))
        }
        return dtos
    }

    func fetchRecentUnpinned(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
        let storage = try requireStorage()
        let items = try await storage.fetchRecentUnpinned(limit: limit, offset: offset)
        var dtos: [ClipboardItemDTO] = []
        dtos.reserveCapacity(items.count)
        for item in items {
            dtos.append(await toDTO(item, storage: storage))
        }
        return dtos
    }

    func search(query: SearchRequest) async throws -> SearchResultPage {
        let storage = try requireStorage()
        let search = try requireSearch()

        let result = try await search.search(request: query)

        var hits: [SearchResultHit] = []
        hits.reserveCapacity(result.items.count)
        for item in result.items {
            try Task.checkCancellation()
            let matchContext = result.matchContexts[item.id]
            let dto = await toDTO(item, storage: storage)
            hits.append(SearchResultHit(item: dto, matchContext: matchContext))
        }

        return SearchResultPage(
            hits: hits,
            total: result.total,
            hasMore: result.hasMore,
            coverage: result.coverage
        )
    }

    func pin(itemID: UUID) async throws {
        try await setPinned(itemID: itemID, pinned: true)
    }

    func unpin(itemID: UUID) async throws {
        try await setPinned(itemID: itemID, pinned: false)
    }

    private func setPinned(itemID: UUID, pinned: Bool) async throws {
        let storage = try requireStorage()
        let search = try requireSearch()
        guard let lease = await itemMutationGate.acquire(itemID: itemID) else {
            throw CancellationError()
        }

        do {
            guard !Task.isCancelled else { throw CancellationError() }
            try await storage.setPin(itemID, pinned: pinned)
            await search.handlePinnedChange(id: itemID, pinned: pinned)
            _ = await publishAuthoritativeItemState(
                id: itemID,
                storage: storage,
                priority: .userInitiated,
                kind: .pinState
            )
            await itemMutationGate.release(lease)
        } catch {
            await itemMutationGate.release(lease)
            throw error
        }
    }

    func updateNote(itemID: UUID, note: String?) async throws {
        let storage = try requireStorage()
        _ = try requireSearch()

        guard let existing = try await storage.findByID(itemID) else {
            throw ClipboardServiceError.itemNotFoundOrSuperseded
        }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard existing.note != normalized else { return }

        guard try await storage.updateNote(id: itemID, note: normalized) != nil else {
            throw ClipboardServiceError.itemNotFoundOrSuperseded
        }
        await metadataPublicationInterlock?(.afterNoteCommit, itemID)
        _ = await publishAuthoritativeItemState(
            id: itemID,
            storage: storage,
            priority: .userInitiated,
            metadataInterlockPoint: .afterNoteDTOConstructionBeforeEvent
        )
    }

    func delete(itemID: UUID) async throws {
        let storage = try requireStorage()
        let search = try requireSearch()

        try await storage.deleteItem(itemID)
        await search.handleDeletion(id: itemID)
        fileSizeComputationLastAttemptAt.remove { $0.itemID == itemID }
        await fileSizeComputationQueue?.cancelPending { $0.itemID == itemID }
        let publication = await reservePublication(for: itemID)
        await yieldEvent(.itemDeleted(itemID), publication: publication)
    }

    func clearAll() async throws {
        let storage = try requireStorage()
        let search = try requireSearch()

        try await storage.deleteAllExceptPinned()
        await search.handleClearAll()
        fileSizeComputationLastAttemptAt.removeAll()
        await fileSizeComputationQueue?.discardPending()
        await thumbnailGenerationQueue?.discardPending()
        await eventQueue.advanceClearGeneration()
        await yieldEvent(.itemsCleared(keepPinned: true))
    }

    func copyToClipboard(itemID: UUID) async throws {
        try await copyToClipboard(itemID: itemID, imageWriteMode: .standard)
    }

    func copyToClipboardOptimizedForCodex(itemID: UUID) async throws {
        try await copyToClipboard(itemID: itemID, imageWriteMode: .codexOptimized)
    }

    func fileURLs(itemID: UUID) async throws -> [URL] {
        let storage = try requireStorage()
        guard let item = try await storage.findByID(itemID) else { return [] }
        let originalURLs = await resolvedFileURLs(for: item, storage: storage)
        if !originalURLs.isEmpty {
            return originalURLs
        }

        if item.type == .image,
           let shareableURL = await shareableImageFileURL(for: item, storage: storage) {
            return [shareableURL]
        }

        return []
    }

    private func copyToClipboard(
        itemID: UUID,
        imageWriteMode: ClipboardMonitor.ImagePasteboardWriteMode
    ) async throws {
        let monitor = try requireMonitor()
        let storage = try requireStorage()
        _ = try requireSearch()

        guard let item = try await storage.findByID(itemID) else {
            throw ClipboardCopyError.itemNotFound(itemID)
        }

        // Usage stats and the item event describe a copy that happened. Nothing below this line
        // runs unless the pasteboard actually took the content.
        try await performClipboardCopy(
            item: item,
            monitor: monitor,
            storage: storage,
            imageWriteMode: imageWriteMode
        )

        do {
            _ = try await storage.incrementUsage(id: item.id, at: Date())
        } catch {
            ScopyLog.app.warning("Failed to update item usage stats: \(error.localizedDescription, privacy: .private)")
        }

        _ = await publishAuthoritativeItemState(
            id: item.id,
            storage: storage,
            priority: .userInitiated,
            kind: .itemUpdated
        )
    }

    private func performClipboardCopy(
        item: StorageService.StoredItem,
        monitor: ClipboardMonitor,
        storage: StorageService,
        imageWriteMode: ClipboardMonitor.ImagePasteboardWriteMode
    ) async throws {
        switch item.type {
        case .text, .other:
            try await copyPlainText(item.plainText, itemID: item.id, monitor: monitor)
        case .rtf, .html, .image:
            try await copyRichPayload(item: item, monitor: monitor, storage: storage, imageWriteMode: imageWriteMode)
        case .file:
            try await copyFilePayload(item: item, monitor: monitor, storage: storage, imageWriteMode: imageWriteMode)
        }
    }

    private func copyPlainText(
        _ text: String,
        itemID: UUID,
        monitor: ClipboardMonitor
    ) async throws {
        try await MainActor.run {
            do {
                try monitor.copyToClipboard(text: text)
            } catch {
                throw ClipboardCopyError.pasteboardRejectedContent(itemID)
            }
        }
    }

    private func copyRichPayload(
        item: StorageService.StoredItem,
        monitor: ClipboardMonitor,
        storage: StorageService,
        imageWriteMode: ClipboardMonitor.ImagePasteboardWriteMode
    ) async throws {
        let data = await storage.loadPayloadData(for: item)
        guard let data else {
            throw ClipboardCopyError.payloadUnavailable(item.id)
        }

        let itemType = item.type
        let pasteboardType: NSPasteboard.PasteboardType
        switch itemType {
        case .rtf: pasteboardType = .rtf
        case .html: pasteboardType = .html
        case .image: pasteboardType = .png
        default: pasteboardType = .string
        }

        let itemID = item.id
        try await MainActor.run {
            do {
                if itemType == .rtf || itemType == .html {
                    let plainText = Self.resolvePlainText(for: item, data: data)
                    try monitor.copyToClipboard(text: plainText, data: data, type: pasteboardType)
                } else if itemType == .image,
                          imageWriteMode == .standard,
                          let fileURL = Self.managedImageFileURL(for: item, storage: storage) {
                    try monitor.copyToClipboard(imageData: data, fileURL: fileURL, imageWriteMode: imageWriteMode)
                } else {
                    try monitor.copyToClipboard(data: data, type: pasteboardType, imageWriteMode: imageWriteMode)
                }
            } catch ClipboardMonitor.PasteboardWriteFailure.imageNotRenderable {
                throw ClipboardCopyError.imageNotRenderable(itemID)
            } catch {
                throw ClipboardCopyError.pasteboardRejectedContent(itemID)
            }
        }
    }

    private func copyFilePayload(
        item: StorageService.StoredItem,
        monitor: ClipboardMonitor,
        storage: StorageService,
        imageWriteMode: ClipboardMonitor.ImagePasteboardWriteMode
    ) async throws {
        let fileURLs = await resolvedFileURLs(for: item, storage: storage)
        // Every recorded node is gone; the path text is all that is left to hand back.
        guard !fileURLs.isEmpty else {
            try await copyPlainText(item.plainText, itemID: item.id, monitor: monitor)
            return
        }

        let itemID = item.id
        try await MainActor.run {
            do {
                if let pngData = Self.resolvePNGDataForTemporaryImageFileURLs(fileURLs) {
                    try monitor.copyToClipboard(data: pngData, type: .png, imageWriteMode: imageWriteMode)
                } else {
                    try monitor.copyToClipboard(fileURLs: fileURLs)
                }
            } catch ClipboardMonitor.PasteboardWriteFailure.imageNotRenderable {
                throw ClipboardCopyError.imageNotRenderable(itemID)
            } catch {
                throw ClipboardCopyError.pasteboardRejectedContent(itemID)
            }
        }
    }

    nonisolated private static func managedImageFileURL(
        for item: StorageService.StoredItem,
        storage: StorageService
    ) -> URL? {
        guard item.type == .image,
              let storageRef = item.storageRef,
              !storageRef.isEmpty,
              StorageService.validateStorageRef(storageRef, externalStoragePath: storage.externalStorageDirectoryPath) else {
            return nil
        }

        let url = URL(fileURLWithPath: storageRef)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return url
    }

    private func resolvedFileURLs(for item: StorageService.StoredItem, storage: StorageService) async -> [URL] {
        if item.type == .file || item.type == .image {
            let urlData = await storage.loadPayloadData(for: item)
            if let data = urlData,
               let fileURLs = Self.deserializeExistingFileURLs(data),
               !fileURLs.isEmpty {
                return fileURLs
            }
        }

        // A managed external payload is always a regular file Scopy wrote itself.
        if let storageRef = item.storageRef,
           !storageRef.isEmpty,
           FilePreviewSupport.accepts(URL(fileURLWithPath: storageRef), policy: .regularFilesOnly) {
            return [URL(fileURLWithPath: storageRef)]
        }

        return FilePreviewSupport.fileURLs(from: item.plainText)
    }

    /// Restores the exact node list a file capture recorded, in copy order. Directories and
    /// packages are part of that list: Finder copies them as plain file URLs, and dropping them
    /// here is what makes a copied folder replay as its path text instead of the folder itself.
    private static func deserializeExistingFileURLs(_ data: Data) -> [URL]? {
        guard let paths = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        let urls = paths.compactMap { path -> URL? in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let url = URL(fileURLWithPath: trimmed)
            guard FilePreviewSupport.accepts(url, policy: .anyExistingNode) else { return nil }
            return url
        }
        return urls.isEmpty ? nil : urls
    }

    private func shareableImageFileURL(for item: StorageService.StoredItem, storage: StorageService) async -> URL? {
        if let payloadData = await storage.loadPayloadData(for: item),
           let imagePayload = ClipboardMonitor.makeImagePasteboardPayloadForWrite(payloadData, imageWriteMode: .standard) {
            return await writeShareableImagePNG(imagePayload.primaryPNGData, for: item)
        }

        let thumbnailPath = (storage.thumbnailCacheDirectoryPath as NSString)
            .appendingPathComponent("\(item.contentHash).png")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: thumbnailPath, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            return URL(fileURLWithPath: thumbnailPath)
        }

        return nil
    }

    /// Temporary PNGs handed to `NSSharingService`. One file per item id, so repeated shares of
    /// the same item reuse a slot instead of accumulating.
    nonisolated static var shareableImageDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Scopy", isDirectory: true)
            .appendingPathComponent("AirDrop", isDirectory: true)
    }

    private func writeShareableImagePNG(_ data: Data, for item: StorageService.StoredItem) async -> URL? {
        await Task.detached(priority: .utility) {
            let directory = Self.shareableImageDirectory
            let url = directory.appendingPathComponent("scopy-image-\(item.id.uuidString).png")

            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try StorageService.writeAtomically(data, to: url.path)
                return url
            } catch {
                ScopyLog.app.warning("Failed to prepare image for AirDrop: \(error.localizedDescription, privacy: .private)")
                return nil
            }
        }.value
    }

    /// Shares outlive the sharing sheet by an unbounded amount, so the files cannot be deleted on
    /// completion. Sweeping them at startup bounds the directory without racing an active share.
    nonisolated private static func sweepStaleShareableImages() {
        let directory = shareableImageDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    nonisolated private static func resolvePlainText(for item: StorageService.StoredItem, data: Data) -> String {
        if !item.plainText.isEmpty { return item.plainText }

        switch item.type {
        case .rtf:
            return NSAttributedString(rtf: data, documentAttributes: nil)?.string ?? ""
        case .html:
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html
            ]
            return (try? NSAttributedString(data: data, options: options, documentAttributes: nil))?.string ?? ""
        default:
            return item.plainText
        }
    }

    nonisolated private static func resolvePNGDataForTemporaryImageFileURLs(_ fileURLs: [URL]) -> Data? {
        guard fileURLs.count == 1 else { return nil }
        return ClipboardMonitor.loadImageFileDataAsPNG(fileURLs[0])
    }

    func updateSettings(_ newSettings: SettingsDTO) async throws {
        let oldSettings = settings
        let patch = SettingsPatch.from(baseline: oldSettings, draft: newSettings)
        let oldPollingMs = settings.clipboardPollingIntervalMs

        await settingsStore.save(newSettings)
        settings = newSettings

        if monitorPollingInterval == nil,
           oldPollingMs != newSettings.clipboardPollingIntervalMs,
           let monitor {
            await MainActor.run {
                monitor.setPollingInterval(TimeInterval(newSettings.clipboardPollingIntervalMs) / 1000.0)
            }
        }

        if let storage = storage {
            await MainActor.run {
                storage.cleanupSettings.maxItems = newSettings.maxItems
                storage.cleanupSettings.maxSmallStorageMB = newSettings.maxStorageMB
                storage.cleanupSettings.cleanupImagesOnly = newSettings.cleanupImagesOnly
            }

            if patch.affectsThumbnailCache {
                await stopThumbnailGenerationQueue()
                invalidateThumbnailCacheIndex()
                await storage.clearThumbnailCache()
                invalidateThumbnailCacheIndex()
                await startThumbnailGenerationQueueIfNeeded()
            }

            if patch.requiresStorageCleanup {
                do {
                    _ = try await storage.performCleanup(
                        mode: .full,
                        onCommitted: cleanupCommitHandler()
                    )
                } catch {
                    ScopyLog.app.warning(
                        "Cleanup failed after settings update: \(error.localizedDescription, privacy: .private)"
                    )
                }
            }
        }

        await yieldEvent(.settingsChanged)
    }

    func getSettings() async -> SettingsDTO {
        await settingsStore.load()
    }

    func setCleanupInterlockForTesting(
        _ interlock: (@Sendable (StorageService.CleanupInterlockPoint) async -> Void)?
    ) async {
        let storage = self.storage
        await MainActor.run {
            storage?.setCleanupInterlockForTesting(interlock)
        }
    }

    func getStorageStats() async throws -> (itemCount: Int, sizeBytes: Int) {
        let storage = try requireStorage()
        let count = try await storage.getItemCount()
        let contentSize = try await storage.getTotalSize()
        return (count, contentSize)
    }

    func getDetailedStorageStats() async throws -> StorageStatsDTO {
        let storage = try requireStorage()
        let count = try await storage.getItemCount()
        let dbSize = await storage.getDatabaseFileSize()
        let externalSize = try await storage.getExternalStorageSizeForStats()
        let thumbnailSize = await storage.getThumbnailCacheSize()
        let dbPath = await storage.databaseFilePath

        return StorageStatsDTO(
            itemCount: count,
            databaseSizeBytes: dbSize,
            externalStorageSizeBytes: externalSize,
            thumbnailSizeBytes: thumbnailSize,
            totalSizeBytes: dbSize + externalSize + thumbnailSize,
            databasePath: dbPath
        )
    }

    func syncExternalImageSizeBytesFromDisk() async throws -> Int {
        let storage = try requireStorage()
        let updated = try await storage.syncExternalImageSizeBytesFromDisk()
        if updated > 0 {
            ScopyLog.storage.info("Synced external image size_bytes from disk: updated=\(updated, privacy: .public)")
        }
        return updated
    }

    func getImageData(itemID: UUID) async throws -> Data? {
        let storage = try requireStorage()
        guard let item = try await storage.findByID(itemID) else { return nil }
        return await storage.loadPayloadData(for: item)
    }

    func optimizeImage(itemID: UUID) async throws -> ImageOptimizationOutcomeDTO {
        let storage = try requireStorage()
        guard !Task.isCancelled else {
            return Self.cancelledImageOptimizationOutcome(originalBytes: 0)
        }
        guard !imageOptimizationInProgress.contains(itemID) else {
            return Self.busyImageOptimizationOutcome(
                message: "Image optimization is already running for this item"
            )
        }
        guard imageOptimizationInProgress.count < maxActiveImageOptimizationRequests else {
            return Self.busyImageOptimizationOutcome(message: "Image optimization queue is busy")
        }

        imageOptimizationInProgress.insert(itemID)
        defer {
            imageOptimizationInProgress.remove(itemID)
        }

        guard let item = try await storage.findByID(itemID) else {
            return ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: 0, optimizedBytes: 0)
        }
        guard item.type == .image else {
            return ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: item.sizeBytes, optimizedBytes: item.sizeBytes)
        }

        let options = PngquantService.Options(
            binaryPath: settings.pngquantBinaryPath,
            qualityMin: settings.pngquantCopyImageQualityMin,
            qualityMax: settings.pngquantCopyImageQualityMax,
            speed: settings.pngquantCopyImageSpeed,
            colors: settings.pngquantCopyImageColors
        )

        guard await imageOptimizationPermitPool.acquire() else {
            if Task.isCancelled {
                return Self.cancelledImageOptimizationOutcome(originalBytes: item.sizeBytes)
            }
            return Self.busyImageOptimizationOutcome(message: "Image optimization queue is busy")
        }
        guard !Task.isCancelled else {
            await imageOptimizationPermitPool.release()
            return Self.cancelledImageOptimizationOutcome(originalBytes: item.sizeBytes)
        }

        let outcome: ImageOptimizationOutcomeDTO
        if let storageRef = item.storageRef, !storageRef.isEmpty {
            outcome = await optimizeExternalImage(
                item,
                storageRef: storageRef,
                storage: storage,
                options: options
            )
        } else if let rawData = item.rawData {
            outcome = await optimizeInlineImage(
                item,
                rawData: rawData,
                storage: storage,
                options: options
            )
        } else {
            // Fallback: item has no inline data and no storageRef (unexpected)
            outcome = ImageOptimizationOutcomeDTO(
                result: .noChange,
                originalBytes: item.sizeBytes,
                optimizedBytes: item.sizeBytes
            )
        }
        await imageOptimizationPermitPool.release()
        return outcome
    }

    func imageOptimizationAdmissionSnapshot() async -> ImageOptimizationAdmissionSnapshot {
        let permitSnapshot = await imageOptimizationPermitPool.snapshot()
        return ImageOptimizationAdmissionSnapshot(
            admittedRequestCount: imageOptimizationInProgress.count,
            activeProcessCount: permitSnapshot.activeCount,
            queuedRequestCount: permitSnapshot.queuedCount,
            requestCapacity: maxActiveImageOptimizationRequests
        )
    }

    private func optimizeInlineImage(
        _ item: StorageService.StoredItem,
        rawData: Data,
        storage: StorageService,
        options: PngquantService.Options
    ) async -> ImageOptimizationOutcomeDTO {
        let originalBytes = rawData.count
        do {
            let compressionTask = Task.detached(priority: .utility) {
                try PngquantService.compressPNGData(rawData, options: options)
            }
            let compressed = try await withTaskCancellationHandler(operation: {
                try await compressionTask.value
            }, onCancel: {
                compressionTask.cancel()
            })

            guard compressed != rawData else {
                return ImageOptimizationOutcomeDTO(
                    result: .noChange,
                    originalBytes: originalBytes,
                    optimizedBytes: originalBytes
                )
            }
            guard !Task.isCancelled else {
                return Self.cancelledImageOptimizationOutcome(originalBytes: originalBytes)
            }

            let newHash = ClipboardMonitor.computeHashStatic(compressed)
            let optimizedBytes = compressed.count
            guard let updated = try await storage.compareAndSwapItemPayload(
                expected: item,
                contentHash: newHash,
                sizeBytes: optimizedBytes,
                storageRef: nil,
                rawData: compressed
            ) else {
                return Self.supersededImageOptimizationOutcome(originalBytes: originalBytes)
            }
            guard let published = await publishOptimizedItem(updated, storage: storage),
                  Self.hasSamePayload(published, as: updated) else {
                return Self.supersededImageOptimizationOutcome(originalBytes: originalBytes)
            }
            return ImageOptimizationOutcomeDTO(
                result: .optimized,
                originalBytes: originalBytes,
                optimizedBytes: optimizedBytes,
                resultingContentHash: newHash
            )
        } catch {
            return ImageOptimizationOutcomeDTO(
                result: .failed(message: error.localizedDescription),
                originalBytes: originalBytes,
                optimizedBytes: originalBytes
            )
        }
    }

    private func optimizeExternalImage(
        _ item: StorageService.StoredItem,
        storageRef: String,
        storage: StorageService,
        options: PngquantService.Options
    ) async -> ImageOptimizationOutcomeDTO {
        guard StorageService.validateStorageRef(
            storageRef,
            externalStoragePath: storage.externalStorageDirectoryPath
        ) else {
            return ImageOptimizationOutcomeDTO(
                result: .failed(message: "Invalid storageRef"),
                originalBytes: item.sizeBytes,
                optimizedBytes: item.sizeBytes
            )
        }

        let sourceURL = URL(fileURLWithPath: storageRef)
        // Hidden staging files are skipped by full orphan enumeration. The storage commit moves
        // this complete payload to a new random managed path immediately before CAS.
        let stagedURL = sourceURL.deletingLastPathComponent().appendingPathComponent(
            ".scopy-optimize-\(UUID().uuidString).stage"
        )
        defer {
            try? FileManager.default.removeItem(at: stagedURL)
        }

        var originalBytes = max(0, item.sizeBytes)
        do {
            let stagedOriginalData = try await Task.detached(priority: .utility) { () throws -> Data in
                try FileManager.default.copyItem(at: sourceURL, to: stagedURL)
                return try Data(contentsOf: stagedURL, options: [.mappedIfSafe])
            }.value
            originalBytes = stagedOriginalData.count
            // External payload bytes may legitimately have been edited out of band while the DB
            // hash remains stale. Fingerprint the bytes actually staged instead of assuming the
            // persisted content hash is current.
            let sourceFingerprint = ClipboardMonitor.computeHashStatic(stagedOriginalData)

            var didTranscodeToPNG = false
            if !PngquantService.isLikelyPNG(stagedOriginalData) {
                didTranscodeToPNG = try await Task.detached(priority: .utility) { () throws -> Bool in
                    guard let pngData = ClipboardMonitor.convertTIFFToPNG(stagedOriginalData) else {
                        return false
                    }
                    try StorageService.writeAtomically(pngData, to: stagedURL.path)
                    return true
                }.value
            }

            guard PngquantService.isLikelyPNGFile(stagedURL) else {
                return ImageOptimizationOutcomeDTO(
                    result: .noChange,
                    originalBytes: originalBytes,
                    optimizedBytes: originalBytes
                )
            }

            let compressionTask = Task.detached(priority: .utility) {
                try PngquantService.compressPNGFileInPlace(stagedURL, options: options)
            }
            let replaced = try await withTaskCancellationHandler(operation: {
                try await compressionTask.value
            }, onCancel: {
                compressionTask.cancel()
            })
            guard replaced || didTranscodeToPNG else {
                return ImageOptimizationOutcomeDTO(
                    result: .noChange,
                    originalBytes: originalBytes,
                    optimizedBytes: originalBytes
                )
            }

            let optimizedData = try await Task.detached(priority: .utility) {
                try Data(contentsOf: stagedURL, options: [.mappedIfSafe])
            }.value
            let optimizedBytes = optimizedData.count
            guard optimizedBytes < originalBytes else {
                return ImageOptimizationOutcomeDTO(
                    result: .noChange,
                    originalBytes: originalBytes,
                    optimizedBytes: originalBytes
                )
            }
            guard !Task.isCancelled else {
                return Self.cancelledImageOptimizationOutcome(originalBytes: originalBytes)
            }

            let newHash = ClipboardMonitor.computeHashStatic(optimizedData)
            let stableOriginalBytes = originalBytes
            let leasedOutcome = await storage.withExternalImageSourceLease(
                sourceURL: sourceURL
            ) { [self] sourceLease in
                await commitOptimizedExternalImageUnderLease(
                    item: item,
                    sourceURL: sourceURL,
                    stagedURL: stagedURL,
                    stagedOriginalData: stagedOriginalData,
                    sourceFingerprint: sourceFingerprint,
                    optimizedBytes: optimizedBytes,
                    newHash: newHash,
                    originalBytes: stableOriginalBytes,
                    storage: storage,
                    sourceLease: sourceLease
                )
            }
            return leasedOutcome ?? Self.supersededImageOptimizationOutcome(originalBytes: stableOriginalBytes)
        } catch {
            return ImageOptimizationOutcomeDTO(
                result: .failed(message: error.localizedDescription),
                originalBytes: originalBytes,
                optimizedBytes: originalBytes
            )
        }
    }

    private func commitOptimizedExternalImageUnderLease(
        item: StorageService.StoredItem,
        sourceURL: URL,
        stagedURL: URL,
        stagedOriginalData: Data,
        sourceFingerprint: String,
        optimizedBytes: Int,
        newHash: String,
        originalBytes: Int,
        storage: StorageService,
        sourceLease: StorageService.ExternalImageSourceLease
    ) async -> ImageOptimizationOutcomeDTO {
        await imageOptimizationInterlock?(.afterExternalSourceLeaseBeforeValidation, item.id)
        let liveSourceStillMatches = await externalSourceMatches(
            sourceURL,
            expectedData: stagedOriginalData,
            expectedFingerprint: sourceFingerprint
        )
        guard liveSourceStillMatches, !Task.isCancelled else {
            return Self.supersededImageOptimizationOutcome(originalBytes: originalBytes)
        }

        let updated: StorageService.StoredItem
        do {
            guard let value = try await storage.commitOptimizedExternalImagePayload(
                expected: item,
                stagedURL: stagedURL,
                contentHash: newHash,
                sizeBytes: optimizedBytes
            ) else {
                return Self.supersededImageOptimizationOutcome(originalBytes: originalBytes)
            }
            updated = value
        } catch {
            return ImageOptimizationOutcomeDTO(
                result: .failed(message: error.localizedDescription),
                originalBytes: originalBytes,
                optimizedBytes: originalBytes
            )
        }

        await imageOptimizationInterlock?(.afterExternalPayloadCommit, item.id)
        let postCommitSourceMatches = await externalSourceMatches(
            sourceURL,
            expectedData: stagedOriginalData,
            expectedFingerprint: sourceFingerprint
        )
        if !postCommitSourceMatches {
            let reconciliation = await reconcileExternalSourceOwnership(
                sourceURL: sourceURL,
                committedItem: updated,
                storage: storage,
                sourceLease: sourceLease
            )

            switch reconciliation {
            case .sourceUnavailable:
                    let current = try? await storage.findByID(item.id)
                    guard let current,
                          Self.hasSamePayload(current, as: updated) else {
                        _ = await publishAuthoritativeItemState(
                            id: item.id,
                            storage: storage,
                            priority: .userInitiated
                        )
                        return Self.supersededImageOptimizationOutcome(originalBytes: originalBytes)
                    }
                case .adopted, .failedOrUnstable:
                    _ = await publishAuthoritativeItemState(
                        id: item.id,
                        storage: storage,
                        priority: .userInitiated
                    )
                    return Self.supersededImageOptimizationOutcome(originalBytes: originalBytes)
                }
        }

        guard let published = await publishOptimizedItem(updated, storage: storage),
              Self.hasSamePayload(published, as: updated) else {
            return Self.supersededImageOptimizationOutcome(originalBytes: originalBytes)
        }
        return ImageOptimizationOutcomeDTO(
            result: .optimized,
            originalBytes: originalBytes,
            optimizedBytes: optimizedBytes,
            resultingContentHash: newHash
        )
    }

    private func publishOptimizedItem(
        _ updated: StorageService.StoredItem,
        storage: StorageService
    ) async -> StorageService.StoredItem? {
        await imageOptimizationInterlock?(.beforeSearchPublication, updated.id)
        guard let current = await publishAuthoritativeItemState(
            id: updated.id,
            storage: storage,
            priority: .userInitiated
        ), Self.hasSamePayload(current, as: updated) else {
            return nil
        }
        return current
    }

    @discardableResult
    private func publishAuthoritativeItemState(
        id: UUID,
        storage: StorageService,
        priority: TaskPriority,
        kind: AuthoritativePublicationKind = .contentUpdated,
        metadataInterlockPoint: MetadataPublicationInterlockPoint? = nil
    ) async -> StorageService.StoredItem? {
        let publication = await reservePublication(for: id)
        guard let current = await synchronizeSearchWithCurrentItem(id: id, storage: storage) else {
            let latest: StorageService.StoredItem?
            do {
                latest = try await storage.findByID(id)
            } catch {
                await eventQueue.discardPublication(publication)
                return nil
            }
            guard latest == nil else {
                await eventQueue.discardPublication(publication)
                return nil
            }
            let accepted = await yieldEvent(.itemDeleted(id), publication: publication)
            guard accepted else { return nil }
            return nil
        }

        let event: ClipboardEvent
        switch kind {
        case .newItem:
            let dto = await toDTO(
                current,
                storage: storage,
                thumbnailGenerationPriority: priority
            )
            event = .newItem(dto)
        case .itemUpdated:
            let dto = await toDTO(
                current,
                storage: storage,
                thumbnailGenerationPriority: priority
            )
            event = .itemUpdated(dto)
        case .contentUpdated:
            let dto = await toDTO(
                current,
                storage: storage,
                thumbnailGenerationPriority: priority
            )
            event = .itemContentUpdated(dto)
        case .pinState:
            event = current.isPinned ? .itemPinned(id) : .itemUnpinned(id)
        }
        if let metadataInterlockPoint {
            await metadataPublicationInterlock?(metadataInterlockPoint, id)
        }
        let accepted = await yieldEvent(event, publication: publication)
        guard accepted else { return nil }
        return current
    }

    /// Search publication is an awaited actor hop, so every pass validates the row both before
    /// and after applying the candidate. A bounded repair loop prevents an older full DTO from
    /// escaping when a same-ID replacement, metadata update, or deletion wins during that hop.
    private func synchronizeSearchWithCurrentItem(
        id: UUID,
        storage: StorageService
    ) async -> StorageService.StoredItem? {
        guard let search else { return nil }

        let initial: StorageService.StoredItem?
        do {
            initial = try await storage.findByID(id)
        } catch {
            await search.invalidateCache()
            return nil
        }

        var candidate = initial
        for _ in 0..<3 {
            guard let candidateItem = candidate else {
                await search.handleDeletion(id: id)
                return nil
            }

            await search.handleUpsertedItem(candidateItem)

            let latest: StorageService.StoredItem?
            do {
                latest = try await storage.findByID(id)
            } catch {
                await search.invalidateCache()
                return nil
            }

            guard let latest else {
                await search.handleDeletion(id: id)
                return nil
            }
            if Self.hasSameItemState(latest, as: candidateItem) {
                return latest
            }
            candidate = latest
        }

        await search.invalidateCache()
        return nil
    }

    private func externalSourceMatches(
        _ sourceURL: URL,
        expectedData: Data,
        expectedFingerprint: String
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let liveData = try? Data(contentsOf: sourceURL, options: [.mappedIfSafe]) else {
                return false
            }
            return liveData.count == expectedData.count &&
                ClipboardMonitor.computeHashStatic(liveData) == expectedFingerprint
        }.value
    }

    /// If an uncooperative external writer changes the source during the commit window, return
    /// DB ownership to that live source only while the just-committed payload is still the winner.
    /// Re-read and advance the fingerprint a few times so a second in-place write does not leave
    /// the row describing bytes that were already superseded.
    private func reconcileExternalSourceOwnership(
        sourceURL: URL,
        committedItem: StorageService.StoredItem,
        storage: StorageService,
        sourceLease: StorageService.ExternalImageSourceLease
    ) async -> ExternalSourceReconciliationResult {
        let result = await storage.reconcileExternalImageSourceOwnership(
            committedItem: committedItem,
            sourceURL: sourceURL,
            sourceLease: sourceLease,
            verificationInterlock: { [imageOptimizationInterlock] attempt in
                await imageOptimizationInterlock?(
                    .afterExternalSourceAdoptionBeforeVerification(attempt: attempt),
                    committedItem.id
                )
            }
        )
        switch result {
        case .adopted:
            return .adopted
        case .sourceUnavailable:
            return .sourceUnavailable
        case .failedOrUnstable:
            return .failedOrUnstable
        }
    }

    private static func hasSamePayload(
        _ lhs: StorageService.StoredItem,
        as rhs: StorageService.StoredItem
    ) -> Bool {
        lhs.id == rhs.id &&
            lhs.type == rhs.type &&
            lhs.contentHash == rhs.contentHash &&
            lhs.plainText == rhs.plainText &&
            lhs.sizeBytes == rhs.sizeBytes &&
            lhs.fileSizeBytes == rhs.fileSizeBytes &&
            lhs.storageRef == rhs.storageRef &&
            lhs.rawData == rhs.rawData
    }

    private static func hasSameItemState(
        _ lhs: StorageService.StoredItem,
        as rhs: StorageService.StoredItem
    ) -> Bool {
        hasSamePayload(lhs, as: rhs) &&
            lhs.note == rhs.note &&
            lhs.appBundleID == rhs.appBundleID &&
            lhs.createdAt == rhs.createdAt &&
            lhs.lastUsedAt == rhs.lastUsedAt &&
            lhs.useCount == rhs.useCount &&
            lhs.isPinned == rhs.isPinned
    }

    private static func supersededImageOptimizationOutcome(
        originalBytes: Int
    ) -> ImageOptimizationOutcomeDTO {
        ImageOptimizationOutcomeDTO(
            result: .failed(message: "Image changed while optimization was running"),
            originalBytes: originalBytes,
            optimizedBytes: originalBytes
        )
    }

    private static func cancelledImageOptimizationOutcome(
        originalBytes: Int
    ) -> ImageOptimizationOutcomeDTO {
        ImageOptimizationOutcomeDTO(
            result: .failed(message: "Image optimization was cancelled"),
            originalBytes: originalBytes,
            optimizedBytes: originalBytes
        )
    }

    private static func busyImageOptimizationOutcome(
        message: String
    ) -> ImageOptimizationOutcomeDTO {
        ImageOptimizationOutcomeDTO(
            result: .failed(message: message),
            originalBytes: 0,
            optimizedBytes: 0
        )
    }

    func getRecentApps(limit: Int) async throws -> [String] {
        let storage = try requireStorage()
        return try await storage.getRecentApps(limit: limit)
    }

    // MARK: - Internals

    private func requireMonitor() throws -> ClipboardMonitor {
        guard let monitor else { throw ClipboardServiceError.notStarted }
        return monitor
    }

    private func requireStorage() throws -> StorageService {
        guard let storage else { throw ClipboardServiceError.notStarted }
        return storage
    }

    private func requireSearch() throws -> SearchEngineImpl {
        guard let search else { throw ClipboardServiceError.notStarted }
        return search
    }

    private func getMonitorStream() async -> AsyncStream<ClipboardMonitor.ClipboardContent>? {
        guard let monitor else { return nil }
        return monitor.contentStream
    }

    private func handleNewContent(_ content: ClipboardMonitor.ClipboardContent) async {
        guard let storage, search != nil else { return }

        if content.type == .image && !settings.saveImages {
            if content.fileOwnership == .transient, let ingestURL = content.ingestFileURL {
                try? FileManager.default.removeItem(at: ingestURL)
            }
            await acknowledgeIngestEnvelopeIfNeeded(content, storage: storage)
            return
        }
        if content.type == .file && !settings.saveFiles {
            if content.fileOwnership == .transient, let ingestURL = content.ingestFileURL {
                try? FileManager.default.removeItem(at: ingestURL)
            }
            await acknowledgeIngestEnvelopeIfNeeded(content, storage: storage)
            return
        }

        let preparedContent = await prepareContentForStorage(content)

        do {
            let outcome = try await storage.upsertItemWithOutcome(preparedContent)
            switch outcome {
            case .inserted(let storedItem):
                _ = await publishAuthoritativeItemState(
                    id: storedItem.id,
                    storage: storage,
                    priority: .userInitiated,
                    kind: .newItem
                )
            case .updated(let storedItem):
                _ = await publishAuthoritativeItemState(
                    id: storedItem.id,
                    storage: storage,
                    priority: .userInitiated,
                    kind: .itemUpdated
                )
            case .alreadyApplied:
                break
            }

            await acknowledgeIngestEnvelopeIfNeeded(preparedContent, storage: storage)
            scheduleCleanup(storage: storage)
        } catch {
            ScopyLog.app.warning("Failed to store clipboard item: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func prepareContentForStorage(
        _ content: ClipboardMonitor.ClipboardContent
    ) async -> ClipboardMonitor.ClipboardContent {
        guard content.type == .image else { return content }
        guard settings.pngquantCopyImageEnabled else { return content }

        let options = PngquantService.Options(
            binaryPath: settings.pngquantBinaryPath,
            qualityMin: settings.pngquantCopyImageQualityMin,
            qualityMax: settings.pngquantCopyImageQualityMax,
            speed: settings.pngquantCopyImageSpeed,
            colors: settings.pngquantCopyImageColors
        )

        switch content.payload {
        case .data(let data):
            let compressed = await Task.detached(priority: .utility) {
                PngquantService.compressBestEffort(data, options: options)
            }.value

            guard compressed != data else { return content }
            let hash = ClipboardMonitor.computeHashStatic(compressed)
            return ClipboardMonitor.ClipboardContent(
                type: content.type,
                plainText: content.plainText,
                payload: .data(compressed),
                note: content.note,
                appBundleID: content.appBundleID,
                contentHash: hash,
                sizeBytes: compressed.count,
                fileSizeBytes: content.fileSizeBytes,
                ingestEnvelopeURL: content.ingestEnvelopeURL,
                ingestID: content.ingestID,
                fileOwnership: content.fileOwnership
            )
        case .file(let url):
            let preparedURL: URL
            let preparedOwnership: ClipboardMonitor.ClipboardContent.FileOwnership
            if content.fileOwnership == .durableSpool {
                guard let copiedURL = await Task.detached(priority: .utility, operation: {
                    try? ClipboardMonitor.createTransientWorkCopy(for: content)
                }).value else {
                    return content
                }
                let replaced = await Task.detached(priority: .utility) {
                    PngquantService.compressFileBestEffort(copiedURL, options: options)
                }.value
                guard replaced else {
                    try? FileManager.default.removeItem(at: copiedURL)
                    return content
                }
                preparedURL = copiedURL
                preparedOwnership = .transient
            } else {
                let replaced = await Task.detached(priority: .utility) {
                    PngquantService.compressFileBestEffort(url, options: options)
                }.value
                guard replaced else { return content }
                preparedURL = url
                preparedOwnership = content.fileOwnership
            }

            let updatedSize: Int = {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: preparedURL.path),
                      let size = attrs[.size] as? Int else { return content.sizeBytes }
                return size
            }()

            let updatedHash: String = {
                guard let data = try? Data(contentsOf: preparedURL, options: [.mappedIfSafe]) else {
                    return content.contentHash
                }
                return ClipboardMonitor.computeHashStatic(data)
            }()

            return ClipboardMonitor.ClipboardContent(
                type: content.type,
                plainText: content.plainText,
                payload: .file(preparedURL),
                note: content.note,
                appBundleID: content.appBundleID,
                contentHash: updatedHash,
                sizeBytes: updatedSize,
                fileSizeBytes: content.fileSizeBytes,
                ingestEnvelopeURL: content.ingestEnvelopeURL,
                ingestID: content.ingestID,
                fileOwnership: preparedOwnership
            )
        case .none:
            return content
        }
    }

    private func acknowledgeIngestEnvelopeIfNeeded(
        _ content: ClipboardMonitor.ClipboardContent,
        storage: StorageService
    ) async {
        guard let envelopeURL = content.ingestEnvelopeURL else { return }
        let outcome = await MainActor.run { [monitor] in
            monitor?.acknowledgeIngestEnvelope(at: envelopeURL)
        }
        guard case .terminal(let acknowledgement) = outcome else { return }
        do {
            try await storage.removeIngestReceipt(acknowledgement.ingestID)
            _ = await MainActor.run { [monitor] in
                monitor?.completeTerminalIngestAcknowledgement(acknowledgement)
            }
        } catch {
            ScopyLog.app.warning(
                "Failed to complete ingest acknowledgement: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func yieldEvent(_ event: ClipboardEvent) async {
        await eventQueue.enqueue(event)
    }

    private func cleanupCommitHandler() -> StorageService.CleanupCommitHandler {
        { [weak self] result in
            guard let self else { return }
            await self.handoffCommittedCleanup(result)
        }
    }

    /// The caller may be a debounce task that becomes cancelled after SQLite commits. A detached
    /// handoff gives the already-committed search/UI convergence work an independent cancellation
    /// lifetime; cancellation remains meaningful only before a cleanup commit.
    private func handoffCommittedCleanup(_ result: StorageService.CleanupResult) async {
        guard !result.deletedItemIDs.isEmpty else { return }
        let handoff = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.publishCommittedCleanup(result)
        }
        await handoff.value
    }

    private func publishCommittedCleanup(_ result: StorageService.CleanupResult) async {
        var seen: Set<UUID> = []
        let deletedItemIDs = result.deletedItemIDs.filter { seen.insert($0).inserted }
        guard !deletedItemIDs.isEmpty else { return }
        let deletedSet = Set(deletedItemIDs)

        if let search {
            await search.invalidateCache()
        }
        fileSizeComputationLastAttemptAt.remove { deletedSet.contains($0.itemID) }
        await fileSizeComputationQueue?.cancelPending { deletedSet.contains($0.itemID) }
        await eventQueue.invalidatePublications(itemIDs: deletedItemIDs)
        await yieldEvent(.itemsRemoved(deletedItemIDs))
    }

    private func reservePublication(for itemID: UUID) async -> ClipboardEventQueue.PublicationToken {
        await eventQueue.reservePublication(itemID: itemID)
    }

    @discardableResult
    private func yieldEvent(
        _ event: ClipboardEvent,
        publication: ClipboardEventQueue.PublicationToken
    ) async -> Bool {
        await eventQueue.enqueue(event, publication: publication)
    }

    private func scheduleCleanup(storage: StorageService) {
        cleanupTask?.cancel()
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(cleanupDebounceDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.runCleanupIfNeeded(storage: storage)
        }
    }

    private func runCleanupIfNeeded(storage: StorageService) async {
        guard !isCleanupRunning else { return }
        isCleanupRunning = true
        defer { isCleanupRunning = false }

        let now = Date()
        let needsFull = now.timeIntervalSince(lastFullCleanupAt) >= fullCleanupInterval
        let needsLight = now.timeIntervalSince(lastLightCleanupAt) >= lightCleanupInterval
        guard needsLight || needsFull else { return }

        let mode: StorageService.CleanupMode = needsFull ? .full : .light
        do {
            _ = try await storage.performCleanup(
                mode: mode,
                onCommitted: cleanupCommitHandler()
            )
            lastLightCleanupAt = now
            if needsFull { lastFullCleanupAt = now }
        } catch {
            ScopyLog.app.warning("Scheduled cleanup failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func startBackgroundMediaQueuesIfNeeded() async {
        await startThumbnailGenerationQueueIfNeeded()
        await startFileSizeComputationQueueIfNeeded()
    }

    private func startThumbnailGenerationQueueIfNeeded() async {
        guard isStarted, thumbnailGenerationQueue == nil else { return }

        let queue = ThumbnailWorkQueue(
            workerLimit: maxConcurrentThumbnailGenerations,
            pendingLimit: maxPendingThumbnailGenerations,
            merge: { existing, incoming in
                var itemIDs = existing.itemIDs
                itemIDs.formUnion(incoming.itemIDs)
                return ThumbnailGenerationWork(
                    item: incoming.item,
                    itemIDs: itemIDs,
                    maxHeight: incoming.maxHeight,
                    externalStorageRoot: incoming.externalStorageRoot,
                    thumbnailCacheRoot: incoming.thumbnailCacheRoot
                )
            },
            operation: { [weak self] work, priority in
                guard let self else { return nil }
                return await self.performThumbnailGeneration(work, priority: priority)
            },
            completion: { [weak self] work, thumbnailPath in
                guard let self, let thumbnailPath else { return }
                await self.publishGeneratedThumbnail(work, thumbnailPath: thumbnailPath)
            }
        )
        thumbnailGenerationQueue = queue
        await queue.start()
    }

    private func startFileSizeComputationQueueIfNeeded() async {
        guard isStarted, fileSizeComputationQueue == nil else { return }

        let queue = FileSizeWorkQueue(
            workerLimit: maxConcurrentFileSizeComputations,
            pendingLimit: maxPendingFileSizeComputations,
            merge: { _, incoming in incoming },
            operation: { [weak self] work, _ in
                guard let self else { return nil }
                return await self.performFileSizeComputation(work)
            },
            completion: { [weak self] _, result in
                guard let self, let result else { return }
                await self.applyComputedFileSizeBytes(
                    expected: result.expected,
                    fileSizeBytes: result.fileSizeBytes
                )
            }
        )
        fileSizeComputationQueue = queue
        await queue.start()
    }

    private func stopThumbnailGenerationQueue() async {
        let queue = thumbnailGenerationQueue
        thumbnailGenerationQueue = nil
        await queue?.stop()
    }

    private func stopBackgroundMediaQueues() async {
        let thumbnailQueue = thumbnailGenerationQueue
        let fileSizeQueue = fileSizeComputationQueue
        thumbnailGenerationQueue = nil
        fileSizeComputationQueue = nil
        await thumbnailQueue?.stop()
        await fileSizeQueue?.stop()
        fileSizeComputationLastAttemptAt.removeAll()
    }

    func backgroundMediaSchedulingSnapshot() async -> BackgroundMediaSchedulingSnapshot {
        let thumbnail = await thumbnailGenerationQueue?.snapshot()
        let fileSize = await fileSizeComputationQueue?.snapshot()
        return BackgroundMediaSchedulingSnapshot(
            thumbnailActiveCount: thumbnail?.activeCount ?? 0,
            thumbnailPendingCount: thumbnail?.pendingCount ?? 0,
            thumbnailWorkerCount: thumbnail?.workerCount ?? 0,
            thumbnailMaxActiveCount: thumbnail?.maxActiveCount ?? 0,
            thumbnailMaxPendingCount: thumbnail?.maxPendingCount ?? 0,
            fileSizeActiveCount: fileSize?.activeCount ?? 0,
            fileSizePendingCount: fileSize?.pendingCount ?? 0,
            fileSizeWorkerCount: fileSize?.workerCount ?? 0,
            fileSizeMaxActiveCount: fileSize?.maxActiveCount ?? 0,
            fileSizeMaxPendingCount: fileSize?.maxPendingCount ?? 0,
            fileSizeRetryTimestampCount: fileSizeComputationLastAttemptAt.count
        )
    }

    private func toDTO(
        _ item: StorageService.StoredItem,
        storage: StorageService,
        thumbnailGenerationPriority: TaskPriority = .utility
    ) async -> ClipboardItemDTO {
        var thumbnailPath: String? = nil
        let fileSizeBytes: Int? = item.fileSizeBytes
        if settings.showImageThumbnails {
            let thumbnailCacheRoot = storage.thumbnailCacheDirectoryPath
            switch item.type {
            case .image:
                let filename = "\(item.contentHash).png"
                if let path = thumbnailPathIfExists(filename: filename, thumbnailCacheRoot: thumbnailCacheRoot) {
                    thumbnailPath = path
                } else if shouldScheduleImageThumbnailGeneration(for: item, externalStorageRoot: storage.externalStorageDirectoryPath) {
                    await scheduleThumbnailGenerationIfNeeded(
                        for: item,
                        storage: storage,
                        priority: thumbnailGenerationPriority
                    )
                }
            case .file:
                if let preview = FilePreviewSupport.previewSummary(from: item.plainText, requireExists: false),
                   preview.shouldGenerateThumbnail {
                    let filename = StorageService.fileThumbnailFilename(for: item.contentHash)
                    if let path = thumbnailPathIfExists(filename: filename, thumbnailCacheRoot: thumbnailCacheRoot) {
                        thumbnailPath = path
                    } else {
                        await scheduleThumbnailGenerationIfNeeded(
                            for: item,
                            storage: storage,
                            priority: thumbnailGenerationPriority
                        )
                    }
                }
            default:
                break
            }
        }

        if item.type == .file, fileSizeBytes == nil {
            await scheduleFileSizeComputationIfNeeded(expected: item)
        }

        return ClipboardItemDTO(
            id: item.id,
            type: item.type,
            contentHash: item.contentHash,
            plainText: item.plainText,
            note: item.note,
            appBundleID: item.appBundleID,
            createdAt: item.createdAt,
            lastUsedAt: item.lastUsedAt,
            isPinned: item.isPinned,
            sizeBytes: item.sizeBytes,
            fileSizeBytes: fileSizeBytes,
            thumbnailPath: thumbnailPath,
            storageRef: item.storageRef
        )
    }

    private func scheduleThumbnailGenerationIfNeeded(
        for item: StorageService.StoredItem,
        storage: StorageService,
        priority: TaskPriority
    ) async {
        guard let queue = thumbnailGenerationQueue else { return }
        let typeNamespace = item.type == .file ? "file" : "image"
        let key = ThumbnailGenerationKey(typeNamespace: typeNamespace, contentHash: item.contentHash)
        let work = ThumbnailGenerationWork(
            item: item,
            itemIDs: [item.id],
            maxHeight: settings.thumbnailHeight,
            externalStorageRoot: storage.externalStorageDirectoryPath,
            thumbnailCacheRoot: storage.thumbnailCacheDirectoryPath
        )
        _ = await queue.submit(
            key: key,
            work: work,
            priority: Self.backgroundWorkPriority(from: priority)
        )
    }

    private func scheduleFileSizeComputationIfNeeded(expected: StorageService.StoredItem) async {
        let key = FileSizeComputationKey(expected: expected)
        let now = Date()
        if fileSizeComputationLastAttemptAt.containsRecent(
            key,
            now: now,
            interval: fileSizeComputationRetryInterval
        ) {
            return
        }
        guard let queue = fileSizeComputationQueue else { return }
        _ = await queue.cancelPending { pendingKey in
            pendingKey.itemID == expected.id && pendingKey != key
        }
        _ = await queue.submit(
            key: key,
            work: FileSizeComputationWork(expected: expected),
            priority: .utility
        )
    }

    private func performFileSizeComputation(_ work: FileSizeComputationWork) async -> FileSizeComputationResult? {
        guard isStarted, !Task.isCancelled else { return nil }
        let key = FileSizeComputationKey(expected: work.expected)
        fileSizeComputationLastAttemptAt.record(key, at: Date())

        let task = Task.detached(priority: .utility) {
            guard !Task.isCancelled,
                  let fileSizeBytes = FilePreviewSupport.totalFileSizeBytes(from: work.expected.plainText) else {
                return nil as FileSizeComputationResult?
            }
            return FileSizeComputationResult(expected: work.expected, fileSizeBytes: fileSizeBytes)
        }
        return await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    func applyComputedFileSizeBytes(
        expected: StorageService.StoredItem,
        fileSizeBytes: Int
    ) async {
        guard isStarted, let storage else { return }
        let key = FileSizeComputationKey(expected: expected)

        do {
            guard try await storage.updateFileSizeBytes(
                expected: expected,
                fileSizeBytes: fileSizeBytes
            ) != nil else {
                fileSizeComputationLastAttemptAt.remove(key)
                return
            }
            fileSizeComputationLastAttemptAt.remove(key)
            await metadataPublicationInterlock?(.afterFileSizeCommit, expected.id)
            _ = await publishAuthoritativeItemState(
                id: expected.id,
                storage: storage,
                priority: .utility,
                metadataInterlockPoint: .afterFileSizeDTOConstructionBeforeEvent
            )
        } catch {
            ScopyLog.app.warning("Failed to update fileSizeBytes for item \(expected.id.uuidString, privacy: .private): \(error.localizedDescription, privacy: .private)")
        }
    }

    private func performThumbnailGeneration(
        _ work: ThumbnailGenerationWork,
        priority: BackgroundWorkPriority
    ) async -> String? {
        guard isStarted, !Task.isCancelled, let storage else { return nil }
        let item = work.item
        let quickLookScale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        let storagePath = item.storageRef
        let rawData = item.rawData
        let fallbackImageData: Data?
        if item.type == .image,
           (storagePath == nil || storagePath?.isEmpty == true),
           rawData == nil,
           !Task.isCancelled {
            fallbackImageData = await storage.loadPayloadData(for: item)
        } else {
            fallbackImageData = nil
        }
        guard !Task.isCancelled else { return nil }

        let generationTask = Task.detached(priority: priority.taskPriority) {
            await Self.generateAndPersistThumbnail(
                work: work,
                quickLookScale: quickLookScale,
                fallbackImageData: fallbackImageData
            )
        }
        return await withTaskCancellationHandler(operation: {
            await generationTask.value
        }, onCancel: {
            generationTask.cancel()
        })
    }

    nonisolated private static func generateAndPersistThumbnail(
        work: ThumbnailGenerationWork,
        quickLookScale: CGFloat,
        fallbackImageData: Data?
    ) async -> String? {
        guard !Task.isCancelled else { return nil }
        let item = work.item
        let pngData: Data?
        switch item.type {
            case .image:
                if let storagePath = item.storageRef, !storagePath.isEmpty {
                    guard StorageService.validateStorageRef(
                        storagePath,
                        externalStoragePath: work.externalStorageRoot
                    ) else {
                        ScopyLog.app.warning("Thumbnail skipped: invalid storageRef (possible traversal)")
                        return nil
                    }
                    pngData = StorageService.makeThumbnailPNG(
                        fromFileAtPath: storagePath,
                        maxHeight: work.maxHeight
                    )
                } else if let rawData = item.rawData {
                    pngData = StorageService.makeThumbnailPNG(from: rawData, maxHeight: work.maxHeight)
                } else if let fallbackImageData {
                    pngData = StorageService.makeThumbnailPNG(
                        from: fallbackImageData,
                        maxHeight: work.maxHeight
                    )
                } else {
                    pngData = nil
                }
            case .file:
                guard let preview = FilePreviewSupport.previewSummary(from: item.plainText, requireExists: true),
                      preview.shouldGenerateThumbnail else {
                    return nil
                }
                switch preview.kind {
                case .image:
                    pngData = StorageService.makeThumbnailPNG(
                        fromFileAtPath: preview.path,
                        maxHeight: work.maxHeight
                    )
                case .video:
                    pngData = FilePreviewSupport.makeVideoThumbnailPNG(
                        from: preview.info.url,
                        maxHeight: work.maxHeight
                    )
                case .other:
                    let maxSidePixels = max(1, Int(CGFloat(work.maxHeight) * quickLookScale))
                    pngData = await FilePreviewSupport.makeQuickLookThumbnailPNG(
                        from: preview.info.url,
                        maxSidePixels: maxSidePixels,
                        scale: quickLookScale
                    )
                }
            default:
                pngData = nil
        }

        guard !Task.isCancelled, let pngData else { return nil }
        let filename = item.type == .file
            ? StorageService.fileThumbnailFilename(for: item.contentHash)
            : "\(item.contentHash).png"
        let thumbnailPath = (work.thumbnailCacheRoot as NSString).appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: thumbnailPath) {
            return thumbnailPath
        }
        if !FileManager.default.fileExists(atPath: work.thumbnailCacheRoot) {
            try? FileManager.default.createDirectory(
                atPath: work.thumbnailCacheRoot,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
        guard !Task.isCancelled else { return nil }
        do {
            try StorageService.writeAtomically(pngData, to: thumbnailPath)
            return Task.isCancelled ? nil : thumbnailPath
        } catch {
            ScopyLog.app.warning("Failed to write thumbnail: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    private func publishGeneratedThumbnail(
        _ work: ThumbnailGenerationWork,
        thumbnailPath: String
    ) async {
        guard isStarted, settings.showImageThumbnails, let storage else { return }
        rememberThumbnailExists(thumbnailPath: thumbnailPath)
        let itemIDs = work.itemIDs.sorted { $0.uuidString < $1.uuidString }
        for itemID in itemIDs {
            let publication = await reservePublication(for: itemID)
            guard let current = try? await storage.findByID(itemID),
                  current.type == work.item.type,
                  current.contentHash == work.item.contentHash else {
                await eventQueue.discardPublication(publication)
                continue
            }
            await yieldEvent(
                .thumbnailUpdated(
                    itemID: itemID,
                    expectedType: work.item.type,
                    expectedContentHash: work.item.contentHash,
                    thumbnailPath: thumbnailPath
                ),
                publication: publication
            )
        }
    }

    nonisolated private static func backgroundWorkPriority(
        from taskPriority: TaskPriority
    ) -> BackgroundWorkPriority {
        taskPriority == .userInitiated || taskPriority == .high ? .userInitiated : .utility
    }

}

// MARK: - Thumbnail Cache Index

extension ClipboardService {
    private func scheduleThumbnailCacheIndexBuildIfNeeded(thumbnailCacheRoot: String) {
        guard !thumbnailCacheRoot.isEmpty else { return }

        if let index = thumbnailCacheIndex, index.root == thumbnailCacheRoot {
            return
        }

        thumbnailCacheIndexTask?.cancel()
        let generation = thumbnailCacheIndexGeneration
        thumbnailCacheIndexTask = Task.detached(priority: .utility) { [weak self, thumbnailCacheRoot, generation] in
            let filenames: [String]
            do {
                filenames = try FileManager.default.contentsOfDirectory(atPath: thumbnailCacheRoot)
            } catch {
                filenames = []
            }

            guard !Task.isCancelled else { return }

            let index = ThumbnailCacheIndex(root: thumbnailCacheRoot, filenames: Set(filenames))
            await self?.setThumbnailCacheIndex(index, generation: generation)
        }
    }

    private func setThumbnailCacheIndex(_ index: ThumbnailCacheIndex, generation: UInt64) {
        guard generation == thumbnailCacheIndexGeneration else { return }
        thumbnailCacheIndex = index
    }

    private func invalidateThumbnailCacheIndex() {
        thumbnailCacheIndexGeneration &+= 1
        thumbnailCacheIndexTask?.cancel()
        thumbnailCacheIndexTask = nil
        thumbnailCacheIndex = nil
    }

    private func thumbnailPathIfExists(filename: String, thumbnailCacheRoot: String) -> String? {
        if var index = thumbnailCacheIndex, index.root == thumbnailCacheRoot {
            let path = index.pathIfExists(filename: filename)
            thumbnailCacheIndex = index
            return path
        }

        let path = (thumbnailCacheRoot as NSString).appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        if var index = thumbnailCacheIndex, index.root == thumbnailCacheRoot {
            index.remember(filename: filename)
            thumbnailCacheIndex = index
        } else {
            thumbnailCacheIndex = ThumbnailCacheIndex(root: thumbnailCacheRoot, filenames: [filename])
        }

        return path
    }

    private func rememberThumbnailExists(thumbnailPath: String) {
        let root = (thumbnailPath as NSString).deletingLastPathComponent
        guard !root.isEmpty else { return }

        let filename = (thumbnailPath as NSString).lastPathComponent
        guard !filename.isEmpty else { return }

        if var index = thumbnailCacheIndex, index.root == root {
            index.remember(filename: filename)
            thumbnailCacheIndex = index
        } else {
            thumbnailCacheIndex = ThumbnailCacheIndex(root: root, filenames: [filename])
        }
    }

    private func shouldScheduleImageThumbnailGeneration(for item: StorageService.StoredItem, externalStorageRoot: String) -> Bool {
        guard item.type == .image else { return false }

        guard let storageRef = item.storageRef, !storageRef.isEmpty else {
            return true
        }

        let filename = (storageRef as NSString).lastPathComponent
        let nameWithoutExt = (filename as NSString).deletingPathExtension

        // Mirror the early safe checks of `StorageService.validateStorageRef` without touching filesystem.
        guard UUID(uuidString: nameWithoutExt) != nil else { return false }
        guard !storageRef.contains("..") && !filename.contains("/") else { return false }

        let allowedPath = (externalStorageRoot as NSString).standardizingPath
        let normalizedRef = (storageRef as NSString).standardizingPath
        guard normalizedRef.hasPrefix(allowedPath + "/") else { return false }

        return true
    }
}
