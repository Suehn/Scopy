import AppKit
import Foundation
import ImageIO

struct SendableThumbnailCGImage: @unchecked Sendable {
    let image: CGImage
}

/// Owns thumbnail cache entries and their bounded loads. Only ImageIO runs off the UI actor.
@MainActor
public final class ThumbnailCache {
    public static let shared = ThumbnailCache()

    typealias DecodeOperation = @Sendable (_ path: String, _ priority: TaskPriority) async -> SendableThumbnailCGImage?

    private struct Waiter {
        let startedAt: CFAbsoluteTime?
        let isCoalesced: Bool
        let continuation: CheckedContinuation<NSImage?, Never>
    }

    private final class Load {
        let id = UUID()
        let path: String
        let queuedAt: CFAbsoluteTime?
        var priority: TaskPriority
        var waiters: [UUID: Waiter]

        init(path: String, priority: TaskPriority, waiterID: UUID, waiter: Waiter) {
            self.path = path
            self.priority = priority
            self.queuedAt = waiter.startedAt
            self.waiters = [waiterID: waiter]
        }
    }

    private let cache: NSCache<NSString, NSImage>
    private let limit: Int
    private let maxPending: Int
    private let maxWaiters: Int
    private let decodeOperation: DecodeOperation
    private var loads: [String: Load] = [:]
    private var pending: [String] = []
    // An invalidated decode still owns its slot until ImageIO returns.
    private var active: [UUID: Task<Void, Never>] = [:]
    private var waiterCount = 0

    private init(
        limit: Int = 2,
        maxPending: Int = 64,
        maxWaiters: Int = 128,
        decodeOperation: DecodeOperation? = nil
    ) {
        self.limit = max(1, limit)
        self.maxPending = max(1, maxPending)
        self.maxWaiters = max(1, maxWaiters)
        self.decodeOperation = decodeOperation ?? { path, _ in Self.decode(path: path) }
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 1000
        // Charge decoded bytes; NSCache uses this budget as an eviction hint.
        cache.totalCostLimit = 32 * 1024 * 1024
        self.cache = cache
    }

    public func cachedImage(path: String) -> NSImage? {
        cache.object(forKey: path as NSString)
    }

    public func loadImage(path: String, priority: TaskPriority = .utility) async -> NSImage? {
        guard !path.isEmpty, !Task.isCancelled else { return nil }
        if let cached = cachedImage(path: path) { return cached }
        let waiterID = UUID()
        let image: NSImage? = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                admit(path: path, priority: priority, waiterID: waiterID, continuation: continuation)
            }
        }, onCancel: {
            Task { @MainActor in self.cancelWaiter(id: waiterID, path: path) }
        })
        return Task.isCancelled ? nil : image
    }

    public func remove(path: String) {
        cache.removeObject(forKey: path as NSString)
        guard let load = loads.removeValue(forKey: path) else { return }
        pending.removeAll { $0 == path }
        active[load.id]?.cancel()
        waiterCount -= load.waiters.count
        load.waiters.values.forEach { $0.continuation.resume(returning: nil) }
    }

    public func clear() {
        cache.removeAllObjects()
        let removed = loads.values
        loads.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        waiterCount = 0
        active.values.forEach { $0.cancel() }
        for load in removed {
            load.waiters.values.forEach { $0.continuation.resume(returning: nil) }
        }
    }

    private func admit(
        path: String,
        priority: TaskPriority,
        waiterID: UUID,
        continuation: CheckedContinuation<NSImage?, Never>
    ) {
        let existing = loads[path]
        if existing == nil, pending.count >= maxPending {
            guard Self.isUserInitiated(priority),
                  let replaced = pending.first(where: { !Self.isUserInitiated(loads[$0]!.priority) }) else {
                continuation.resume(returning: nil)
                return
            }
            remove(path: replaced)
        }
        guard waiterCount < maxWaiters else {
            continuation.resume(returning: nil)
            return
        }
        let waiter = Waiter(
            startedAt: ScrollPerformanceProfile.isEnabled ? CFAbsoluteTimeGetCurrent() : nil,
            isCoalesced: existing != nil,
            continuation: continuation
        )
        if let load = existing {
            if active[load.id] == nil, Self.isUserInitiated(priority) { load.priority = .userInitiated }
            load.waiters[waiterID] = waiter
        } else {
            loads[path] = Load(path: path, priority: priority, waiterID: waiterID, waiter: waiter)
            pending.append(path)
        }
        waiterCount += 1
        startAvailableLoads()
    }

    private func startAvailableLoads() {
        while active.count < limit, !pending.isEmpty {
            let index = pending.firstIndex(where: { Self.isUserInitiated(loads[$0]!.priority) }) ?? 0
            let path = pending.remove(at: index)
            let load = loads[path]!
            let id = load.id
            let priority = load.priority
            let queuedAt = load.queuedAt
            let operation = decodeOperation
            active[id] = Task.detached(priority: priority) {
                if let queuedAt {
                    ScrollPerformanceProfile.recordTiming(
                        name: "image.thumbnail_queue_wait_ms",
                        elapsedMs: (CFAbsoluteTimeGetCurrent() - queuedAt) * 1000
                    )
                }
                let startedAt = ScrollPerformanceProfile.isEnabled ? CFAbsoluteTimeGetCurrent() : nil
                let image = await operation(path, priority)
                if let startedAt {
                    ScrollPerformanceProfile.recordTiming(
                        name: "image.thumbnail_imageio_decode_ms",
                        elapsedMs: (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
                    )
                }
                await self.finish(path: path, id: id, decoded: image)
            }
        }
    }

    private func finish(path: String, id: UUID, decoded: SendableThumbnailCGImage?) {
        active.removeValue(forKey: id)
        defer { startAvailableLoads() }
        guard let load = loads[path], load.id == id else { return }
        loads.removeValue(forKey: path)
        waiterCount -= load.waiters.count
        guard !load.waiters.isEmpty else { return }

        let finishedAt = ScrollPerformanceProfile.isEnabled ? CFAbsoluteTimeGetCurrent() : nil
        let image = decoded.map { decoded in
            let cgImage = decoded.image
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            cache.setObject(image, forKey: path as NSString, cost: cgImage.bytesPerRow * cgImage.height)
            return image
        }
        if let finishedAt, image != nil {
            ScrollPerformanceProfile.recordTiming(
                name: "image.thumbnail_main_commit_ms",
                elapsedMs: (CFAbsoluteTimeGetCurrent() - finishedAt) * 1000
            )
        }
        for waiter in load.waiters.values {
            if let startedAt = waiter.startedAt, let finishedAt {
                let elapsed = (finishedAt - startedAt) * 1000
                if waiter.isCoalesced {
                    ScrollPerformanceProfile.recordTiming(name: "image.thumbnail_inflight_wait_ms", elapsedMs: elapsed)
                }
                if image != nil {
                    ScrollPerformanceProfile.recordTiming(name: "image.thumbnail_decode_ms", elapsedMs: elapsed)
                    ScrollPerformanceProfile.recordTiming(
                        name: "image.thumbnail_load_total_ms",
                        elapsedMs: (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
                    )
                }
            }
            waiter.continuation.resume(returning: image)
        }
    }

    private func cancelWaiter(id: UUID, path: String) {
        guard let load = loads[path], let waiter = load.waiters.removeValue(forKey: id) else { return }
        waiterCount -= 1
        waiter.continuation.resume(returning: nil)
        if load.waiters.isEmpty, active[load.id] == nil {
            loads.removeValue(forKey: path)
            pending.removeAll { $0 == path }
        }
    }

    private static func isUserInitiated(_ priority: TaskPriority) -> Bool {
        priority == .userInitiated || priority == .high
    }

    private nonisolated static func decode(path: String) -> SendableThumbnailCGImage? {
        guard !Task.isCancelled else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        guard !Task.isCancelled,
              let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else { return nil }
        return SendableThumbnailCGImage(image: image)
    }

#if DEBUG
    struct SnapshotForTesting {
        let activeCount: Int
        let pendingCount: Int
        let waiterCount: Int
        let pendingPaths: [String]
        let pendingUserInitiated: [Bool]
    }

    static func makeForTesting(
        limit: Int = 2,
        maxPending: Int = 64,
        maxWaiters: Int = 128,
        decodeOperation: @escaping DecodeOperation
    ) -> ThumbnailCache {
        ThumbnailCache(limit: limit, maxPending: maxPending, maxWaiters: maxWaiters, decodeOperation: decodeOperation)
    }

    func snapshotForTesting() -> SnapshotForTesting {
        SnapshotForTesting(
            activeCount: active.count,
            pendingCount: pending.count,
            waiterCount: waiterCount,
            pendingPaths: pending,
            pendingUserInitiated: pending.map { Self.isUserInitiated(loads[$0]!.priority) }
        )
    }
#endif
}
