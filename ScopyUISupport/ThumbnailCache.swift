import AppKit
import Foundation
import ImageIO

private struct SendableThumbnailCGImage: @unchecked Sendable {
    let image: CGImage
}

private actor ThumbnailDecodeCoordinator {
    static let shared = ThumbnailDecodeCoordinator(limit: 2)

    private let limit: Int
    private var activeCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inFlight: [String: Task<SendableThumbnailCGImage?, Never>] = [:]

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func load(path: String, priority: TaskPriority) async -> SendableThumbnailCGImage? {
        if let task = inFlight[path] {
            let waitStart = ScrollPerformanceProfile.isEnabled ? CFAbsoluteTimeGetCurrent() : nil
            let result = await task.value
            if let waitStart {
                let elapsed = (CFAbsoluteTimeGetCurrent() - waitStart) * 1000
                ScrollPerformanceProfile.recordMetric(name: "image.thumbnail_inflight_wait_ms", elapsedMs: elapsed)
            }
            return result
        }

        let task = Task.detached(priority: priority) { () -> SendableThumbnailCGImage? in
            let queueStart = ScrollPerformanceProfile.isEnabled ? CFAbsoluteTimeGetCurrent() : nil
            await ThumbnailDecodeCoordinator.shared.acquire()
            let decodeStart = ScrollPerformanceProfile.isEnabled ? CFAbsoluteTimeGetCurrent() : nil
            if let queueStart, let decodeStart {
                ScrollPerformanceProfile.recordMetric(
                    name: "image.thumbnail_queue_wait_ms",
                    elapsedMs: (decodeStart - queueStart) * 1000
                )
            }
            let result = Self.decode(path: path)
            if let decodeStart {
                ScrollPerformanceProfile.recordMetric(
                    name: "image.thumbnail_imageio_decode_ms",
                    elapsedMs: (CFAbsoluteTimeGetCurrent() - decodeStart) * 1000
                )
            }
            await ThumbnailDecodeCoordinator.shared.release()
            return result
        }
        inFlight[path] = task
        let result = await task.value
        inFlight[path] = nil
        return result
    }

    private func acquire() async {
        if activeCount < limit {
            activeCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if let continuation = waiters.first {
            waiters.removeFirst()
            continuation.resume()
            return
        }
        activeCount = max(0, activeCount - 1)
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
