import CoreGraphics
import Foundation

@MainActor
final class HoverPreviewImageCache {
    static let shared = HoverPreviewImageCache()

    private final class Entry {
        let image: CGImage

        init(image: CGImage) {
            self.image = image
        }
    }

    private let ttl: TimeInterval
    private let now: () -> Date
    private let cache: NSCache<NSString, Entry>
    private var expiresAt: [String: Date] = [:]
    private var cleanupTask: Task<Void, Never>?

    init(ttl: TimeInterval = 60, now: @escaping () -> Date = { Date() }) {
        self.ttl = ttl
        self.now = now

        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 40
        cache.totalCostLimit = 160 * 1024 * 1024
        self.cache = cache

        startCleanupLoopIfNeeded()
    }

    deinit {
        cleanupTask?.cancel()
    }

    func image(forKey key: String) -> CGImage? {
        guard !key.isEmpty else { return nil }

        let current = now()

        if let expiry = expiresAt[key], expiry <= current {
            remove(key)
            return nil
        }

        guard let entry = cache.object(forKey: key as NSString) else {
            expiresAt.removeValue(forKey: key)
            return nil
        }

        // Sliding TTL: keep hot previews around during repeated hover actions.
        expiresAt[key] = current.addingTimeInterval(ttl)
        return entry.image
    }

    func setImage(_ image: CGImage, forKey key: String) {
        guard !key.isEmpty else { return }

        let cost = Self.estimatedCostBytes(for: image)
        let perItemLimit = 96 * 1024 * 1024
        if cost > perItemLimit {
            return
        }

        let entry = Entry(image: image)
        cache.setObject(entry, forKey: key as NSString, cost: cost)
        expiresAt[key] = now().addingTimeInterval(ttl)
    }

    func remove(_ key: String) {
        expiresAt.removeValue(forKey: key)
        cache.removeObject(forKey: key as NSString)
    }

    func removeAll() {
        expiresAt.removeAll()
        cache.removeAllObjects()
    }

    // MARK: - Cleanup

    private func startCleanupLoopIfNeeded() {
        guard cleanupTask == nil else { return }

        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await MainActor.run {
                    self?.cleanupExpired()
                }
            }
        }
    }

    private func cleanupExpired() {
        let current = now()
        var toRemove: [String] = []
        toRemove.reserveCapacity(expiresAt.count)

        for (key, expiry) in expiresAt {
            if expiry <= current || cache.object(forKey: key as NSString) == nil {
                toRemove.append(key)
            }
        }

        for key in toRemove {
            remove(key)
        }
    }

    private static func estimatedCostBytes(for image: CGImage) -> Int {
        let w = max(1, image.width)
        let h = max(1, image.height)
        let bytesPerPixel = 4

        let pixels = Int64(w) * Int64(h)
        let bytes = pixels * Int64(bytesPerPixel)
        return Int(min(Int64(Int.max), bytes))
    }
}
