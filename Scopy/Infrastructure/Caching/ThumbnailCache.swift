import AppKit
import Foundation

final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache: NSCache<NSString, NSImage>

    private init() {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 1000
        self.cache = cache
    }

    func cachedImage(path: String) -> NSImage? {
        cache.object(forKey: path as NSString)
    }

    func store(_ image: NSImage, forPath path: String) {
        cache.setObject(image, forKey: path as NSString)
    }

    func loadImage(path: String) async -> NSImage? {
        if let cached = cachedImage(path: path) {
            return cached
        }

        let data = await Task.detached(priority: .utility) {
            try? Data(contentsOf: URL(fileURLWithPath: path))
        }.value

        guard !Task.isCancelled else { return nil }
        guard let data else { return nil }

        let image = await MainActor.run { NSImage(data: data) }
        guard !Task.isCancelled else { return nil }
        guard let image else { return nil }

        store(image, forPath: path)
        return image
    }

    func clear() {
        cache.removeAllObjects()
    }
}

