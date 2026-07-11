import AppKit
import Foundation
import ImageIO

struct SendableThumbnailCGImage: @unchecked Sendable {
    let image: CGImage
}

actor ThumbnailDecodeCoordinator {
    struct Snapshot: Sendable, Equatable {
        let isRunning: Bool
        let activeUniqueCount: Int
        let pendingUniqueCount: Int
        let totalWaiterCount: Int
        let workerCount: Int
        let waitingWorkerCount: Int
        let maxActiveUniqueCount: Int
        let maxPendingUniqueCount: Int
        let maxTotalWaiterCount: Int
        let workerLimit: Int
        let pendingLimit: Int
        let waiterLimit: Int
        let activePaths: [String]
        let pendingPaths: [String]
        let pendingUserInitiated: [Bool]
    }

    private struct RequestWaiter {
        let id: UUID
        let coalescedAt: CFAbsoluteTime?
        let continuation: CheckedContinuation<SendableThumbnailCGImage?, Never>
    }

    private struct DecodeJob {
        let path: String
        var priority: TaskPriority
        let sequence: UInt64
        let queuedAt: CFAbsoluteTime?
        var waiters: [UUID: RequestWaiter]
    }

    private struct WorkerWaiter {
        let id: UUID
        let generation: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    typealias DecodeOperation = @Sendable (_ path: String, _ priority: TaskPriority) async -> SendableThumbnailCGImage?

    static let shared = ThumbnailDecodeCoordinator(limit: 2, maxPending: 64, maxWaiters: 128)

    private let limit: Int
    private let maxPending: Int
    private let maxWaiters: Int
    private let decodeOperation: DecodeOperation
    private var isRunning = false
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var waiterCount = 0
    private var pendingOrder: [String] = []
    private var pendingByPath: [String: DecodeJob] = [:]
    private var activeByPath: [String: DecodeJob] = [:]
    private var workerTasks: [UUID: Task<Void, Never>] = [:]
    private var workerWaiters: [WorkerWaiter] = []
    private var maxObservedActiveCount = 0
    private var maxObservedPendingCount = 0
    private var maxObservedWaiterCount = 0

    init(
        limit: Int,
        maxPending: Int = 64,
        maxWaiters: Int = 128,
        decodeOperation: DecodeOperation? = nil
    ) {
        self.limit = max(1, limit)
        self.maxPending = max(1, maxPending)
        self.maxWaiters = max(1, maxWaiters)
        self.decodeOperation = decodeOperation ?? { path, priority in
            let task = Task.detached(priority: priority) {
                Self.decode(path: path)
            }
            return await withTaskCancellationHandler(operation: {
                await task.value
            }, onCancel: {
                task.cancel()
            })
        }
    }

    deinit {
        workerTasks.values.forEach { $0.cancel() }
        workerWaiters.forEach { $0.continuation.resume(returning: false) }
        pendingByPath.values.flatMap { $0.waiters.values }.forEach {
            $0.continuation.resume(returning: nil)
        }
        activeByPath.values.flatMap { $0.waiters.values }.forEach {
            $0.continuation.resume(returning: nil)
        }
    }

    func load(path: String, priority: TaskPriority) async -> SendableThumbnailCGImage? {
        guard !path.isEmpty, !Task.isCancelled else { return nil }
        startWorkersIfNeeded()
        let requestID = UUID()

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                admit(
                    path: path,
                    priority: priority,
                    requestID: requestID,
                    continuation: continuation
                )
            }
        }, onCancel: {
            Task { await self.cancelRequest(id: requestID, path: path) }
        })
    }

    func snapshot() -> Snapshot {
        Snapshot(
            isRunning: isRunning,
            activeUniqueCount: activeByPath.count,
            pendingUniqueCount: pendingByPath.count,
            totalWaiterCount: waiterCount,
            workerCount: workerTasks.count,
            waitingWorkerCount: workerWaiters.count,
            maxActiveUniqueCount: maxObservedActiveCount,
            maxPendingUniqueCount: maxObservedPendingCount,
            maxTotalWaiterCount: maxObservedWaiterCount,
            workerLimit: limit,
            pendingLimit: maxPending,
            waiterLimit: maxWaiters,
            activePaths: activeByPath.keys.sorted(),
            pendingPaths: pendingOrder,
            pendingUserInitiated: pendingOrder.map {
                pendingByPath[$0].map { Self.isUserInitiated($0.priority) } ?? false
            }
        )
    }

    func stop() async {
        guard isRunning || !workerTasks.isEmpty else {
            clearJobs(resumingWith: nil)
            return
        }

        isRunning = false
        generation &+= 1
        clearJobs(resumingWith: nil)

        let suspendedWorkers = workerWaiters
        workerWaiters.removeAll(keepingCapacity: true)
        suspendedWorkers.forEach { $0.continuation.resume(returning: false) }

        let tasks = Array(workerTasks.values)
        workerTasks.removeAll(keepingCapacity: true)
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
    }

    private func startWorkersIfNeeded() {
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1
        let workerGeneration = generation
        for _ in 0..<limit {
            let workerID = UUID()
            workerTasks[workerID] = Task(priority: .utility) { [weak self] in
                await self?.workerLoop(id: workerID, generation: workerGeneration)
            }
        }
    }

    private func admit(
        path: String,
        priority: TaskPriority,
        requestID: UUID,
        continuation: CheckedContinuation<SendableThumbnailCGImage?, Never>
    ) {
        guard isRunning else {
            continuation.resume(returning: nil)
            return
        }

        if var active = activeByPath[path] {
            guard waiterCount < maxWaiters else {
                continuation.resume(returning: nil)
                return
            }
            active.waiters[requestID] = RequestWaiter(
                id: requestID,
                coalescedAt: ScrollPerformanceProfile.isEnabled ? CFAbsoluteTimeGetCurrent() : nil,
                continuation: continuation
            )
            activeByPath[path] = active
            waiterCount += 1
            maxObservedWaiterCount = max(maxObservedWaiterCount, waiterCount)
            return
        }

        if var pending = pendingByPath[path] {
            guard waiterCount < maxWaiters else {
                continuation.resume(returning: nil)
                return
            }
            pending.priority = Self.higherPriority(pending.priority, priority)
            pending.waiters[requestID] = RequestWaiter(
                id: requestID,
                coalescedAt: ScrollPerformanceProfile.isEnabled ? CFAbsoluteTimeGetCurrent() : nil,
                continuation: continuation
            )
            pendingByPath[path] = pending
            waiterCount += 1
            maxObservedWaiterCount = max(maxObservedWaiterCount, waiterCount)
            return
        }

        if pendingByPath.count >= maxPending {
            guard Self.isUserInitiated(priority),
                  let utilityIndex = pendingOrder.firstIndex(where: {
                      guard let pending = pendingByPath[$0] else { return false }
                      return !Self.isUserInitiated(pending.priority)
                  }) else {
                continuation.resume(returning: nil)
                return
            }
            let replacedPath = pendingOrder.remove(at: utilityIndex)
            if let replaced = pendingByPath.removeValue(forKey: replacedPath) {
                waiterCount -= replaced.waiters.count
                replaced.waiters.values.forEach { $0.continuation.resume(returning: nil) }
            }
        }

        guard waiterCount < maxWaiters else {
            continuation.resume(returning: nil)
            return
        }

        sequence &+= 1
        let waiter = RequestWaiter(id: requestID, coalescedAt: nil, continuation: continuation)
        let job = DecodeJob(
            path: path,
            priority: priority,
            sequence: sequence,
            queuedAt: ScrollPerformanceProfile.isEnabled ? CFAbsoluteTimeGetCurrent() : nil,
            waiters: [requestID: waiter]
        )
        pendingOrder.append(path)
        pendingByPath[path] = job
        waiterCount += 1
        maxObservedPendingCount = max(maxObservedPendingCount, pendingByPath.count)
        maxObservedWaiterCount = max(maxObservedWaiterCount, waiterCount)
        wakeOneWorker()
    }

    private func workerLoop(id: UUID, generation workerGeneration: UInt64) async {
        while !Task.isCancelled,
              let job = await nextJob(workerID: id, generation: workerGeneration) {
            if let queuedAt = job.queuedAt {
                ScrollPerformanceProfile.recordMetric(
                    name: "image.thumbnail_queue_wait_ms",
                    elapsedMs: (CFAbsoluteTimeGetCurrent() - queuedAt) * 1000
                )
            }

            let decodeStart = ScrollPerformanceProfile.isEnabled ? CFAbsoluteTimeGetCurrent() : nil
            let result = await decodeOperation(job.path, job.priority)
            if let decodeStart {
                ScrollPerformanceProfile.recordMetric(
                    name: "image.thumbnail_imageio_decode_ms",
                    elapsedMs: (CFAbsoluteTimeGetCurrent() - decodeStart) * 1000
                )
            }
            finish(path: job.path, result: result, generation: workerGeneration)
        }
        workerTasks.removeValue(forKey: id)
    }

    private func nextJob(workerID: UUID, generation workerGeneration: UInt64) async -> DecodeJob? {
        while isRunning, generation == workerGeneration, !Task.isCancelled {
            if let job = popNextJob() {
                activeByPath[job.path] = job
                maxObservedActiveCount = max(maxObservedActiveCount, activeByPath.count)
                return job
            }
            guard await suspendWorker(id: workerID, generation: workerGeneration) else { return nil }
        }
        return nil
    }

    private func popNextJob() -> DecodeJob? {
        guard !pendingOrder.isEmpty else { return nil }
        let nextIndex = pendingOrder.firstIndex(where: {
            pendingByPath[$0].map { Self.isUserInitiated($0.priority) } ?? false
        }) ?? 0
        let path = pendingOrder.remove(at: nextIndex)
        return pendingByPath.removeValue(forKey: path)
    }

    private func finish(
        path: String,
        result: SendableThumbnailCGImage?,
        generation workerGeneration: UInt64
    ) {
        guard isRunning, generation == workerGeneration,
              let job = activeByPath.removeValue(forKey: path) else { return }
        waiterCount -= job.waiters.count
        for waiter in job.waiters.values {
            if let coalescedAt = waiter.coalescedAt {
                ScrollPerformanceProfile.recordMetric(
                    name: "image.thumbnail_inflight_wait_ms",
                    elapsedMs: (CFAbsoluteTimeGetCurrent() - coalescedAt) * 1000
                )
            }
            waiter.continuation.resume(returning: result)
        }
    }

    private func cancelRequest(id: UUID, path: String) {
        if var pending = pendingByPath[path], let waiter = pending.waiters.removeValue(forKey: id) {
            waiterCount -= 1
            waiter.continuation.resume(returning: nil)
            if pending.waiters.isEmpty {
                pendingByPath.removeValue(forKey: path)
                pendingOrder.removeAll { $0 == path }
            } else {
                pendingByPath[path] = pending
            }
            return
        }

        if var active = activeByPath[path], let waiter = active.waiters.removeValue(forKey: id) {
            waiterCount -= 1
            waiter.continuation.resume(returning: nil)
            activeByPath[path] = active
        }
    }

    private func clearJobs(resumingWith result: SendableThumbnailCGImage?) {
        let waiters = pendingByPath.values.flatMap { $0.waiters.values }
            + activeByPath.values.flatMap { $0.waiters.values }
        pendingOrder.removeAll(keepingCapacity: true)
        pendingByPath.removeAll(keepingCapacity: true)
        activeByPath.removeAll(keepingCapacity: true)
        waiterCount = 0
        waiters.forEach { $0.continuation.resume(returning: result) }
    }

    private func suspendWorker(id: UUID, generation workerGeneration: UInt64) async -> Bool {
        guard isRunning, generation == workerGeneration, !Task.isCancelled else { return false }
        let waiterID = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard isRunning, generation == workerGeneration, !Task.isCancelled else {
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

    private nonisolated static func higherPriority(_ lhs: TaskPriority, _ rhs: TaskPriority) -> TaskPriority {
        if isUserInitiated(lhs) || isUserInitiated(rhs) {
            return .userInitiated
        }
        return .utility
    }

    private nonisolated static func isUserInitiated(_ priority: TaskPriority) -> Bool {
        priority == .userInitiated || priority == .high
    }

    private nonisolated static func decode(path: String) -> SendableThumbnailCGImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return SendableThumbnailCGImage(image: image)
    }
}

/// In-memory thumbnail cache for UI rendering.
@MainActor
public final class ThumbnailCache {
    public static let shared = ThumbnailCache()

    private let cache: NSCache<NSString, NSImage>

    private init() {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 1000
        self.cache = cache
    }

    public func cachedImage(path: String) -> NSImage? {
        cache.object(forKey: path as NSString)
    }

    public func store(_ image: NSImage, forPath path: String) {
        cache.setObject(image, forKey: path as NSString)
    }

    public func remove(path: String) {
        cache.removeObject(forKey: path as NSString)
    }

    public func loadImage(path: String) async -> NSImage? {
        await loadImage(path: path, priority: .utility)
    }

    public func loadImage(path: String, priority: TaskPriority) async -> NSImage? {
        if let cached = cachedImage(path: path) {
            return cached
        }

        let profileStart = ScrollPerformanceProfile.isEnabled ? CFAbsoluteTimeGetCurrent() : nil
        let decoded = await ThumbnailDecodeCoordinator.shared.load(path: path, priority: priority)

        guard !Task.isCancelled else { return nil }
        guard let cgImage = decoded?.image else { return nil }

        if let profileStart {
            let elapsed = (CFAbsoluteTimeGetCurrent() - profileStart) * 1000
            ScrollPerformanceProfile.recordMetric(name: "image.thumbnail_decode_ms", elapsedMs: elapsed)
        }
        let commitStart = ScrollPerformanceProfile.isEnabled ? CFAbsoluteTimeGetCurrent() : nil
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        store(image, forPath: path)
        if let commitStart {
            ScrollPerformanceProfile.recordMetric(
                name: "image.thumbnail_main_commit_ms",
                elapsedMs: (CFAbsoluteTimeGetCurrent() - commitStart) * 1000
            )
        }
        if let profileStart {
            ScrollPerformanceProfile.recordMetric(
                name: "image.thumbnail_load_total_ms",
                elapsedMs: (CFAbsoluteTimeGetCurrent() - profileStart) * 1000
            )
        }
        return image
    }

    public func clear() {
        cache.removeAllObjects()
    }
}
