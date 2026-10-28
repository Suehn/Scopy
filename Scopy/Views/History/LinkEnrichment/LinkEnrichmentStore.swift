import Foundation
import ScopyKit

/// Serializes sidecar I/O away from the main actor.
///
/// Artifacts are derived caches keyed by markdown content hash, stored as one JSON file
/// per key under Application Support. The bounded memory cache avoids repeated reads while
/// document preparation awaits a frozen payload; views never consult this store synchronously.
actor LinkEnrichmentStore {
    static let shared = LinkEnrichmentStore()

    static let maximumEntries = 500

    private enum MemoryEntry {
        case payload(LinkEnrichmentPayload)
        case miss
    }

    private var memory: [String: MemoryEntry] = [:]
    private var memoryOrder: [String] = []
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scopy/LinkEnrichment", isDirectory: true)
    }

    func payload(forContentKey key: String) -> LinkEnrichmentPayload? {
        if let cached = memory[key] {
            touchMemoryEntry(key)
            switch cached {
            case .payload(let payload): return payload
            case .miss: return nil
            }
        }
        let loaded = readFromDisk(key: key)
        cache(loaded.map(MemoryEntry.payload) ?? .miss, key: key)
        return loaded
    }

    func write(_ payload: LinkEnrichmentPayload, forContentKey key: String) {
        cache(.payload(payload), key: key)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL(key: key), options: .atomic)
        } catch {
            ScopyLog.ui.error("Could not persist link enrichment: \(String(describing: error), privacy: .private)")
        }
        prune()
    }

    private func fileURL(key: String) -> URL {
        directory.appendingPathComponent(key + ".json", isDirectory: false)
    }

    private func readFromDisk(key: String) -> LinkEnrichmentPayload? {
        guard let data = try? Data(contentsOf: fileURL(key: key)),
              let payload = try? JSONDecoder().decode(LinkEnrichmentPayload.self, from: data),
              payload.version == LinkEnrichmentPayload.formatVersion
        else { return nil }
        return payload
    }

    private func prune() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ), entries.count > Self.maximumEntries else { return }
        let sorted = entries.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l < r
        }
        for stale in sorted.prefix(entries.count - Self.maximumEntries) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    private func cache(_ entry: MemoryEntry, key: String) {
        memory[key] = entry
        touchMemoryEntry(key)
        while memoryOrder.count > Self.maximumEntries {
            memory.removeValue(forKey: memoryOrder.removeFirst())
        }
    }

    private func touchMemoryEntry(_ key: String) {
        if let index = memoryOrder.firstIndex(of: key) {
            memoryOrder.remove(at: index)
        }
        memoryOrder.append(key)
    }
}
