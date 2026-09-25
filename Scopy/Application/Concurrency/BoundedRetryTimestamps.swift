import Foundation

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
