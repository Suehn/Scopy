import AppKit
import Foundation
import ImageIO

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
        let cgImage: CGImage? = await Task.detached(priority: priority) { () async -> CGImage? in
            let url = URL(fileURLWithPath: path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately: true
            ]
            return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        }.value

        guard !Task.isCancelled else { return nil }
        guard let cgImage else { return nil }

        if let profileStart {
            let elapsed = (CFAbsoluteTimeGetCurrent() - profileStart) * 1000
            ScrollPerformanceProfile.recordMetric(name: "image.thumbnail_decode_ms", elapsedMs: elapsed)
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        store(image, forPath: path)
        return image
    }

    public func clear() {
        cache.removeAllObjects()
    }
}
