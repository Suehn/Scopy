import Foundation
import os

/// Synchronous, lock-guarded sidecar store for link-enrichment artifacts.
///
/// Artifacts are derived caches keyed by markdown content hash, stored as one JSON file
/// per key under Application Support. Reads are memory-cached so the render-context
/// resolver can consult the store synchronously on every context build.
final class LinkEnrichmentStore: @unchecked Sendable {
    static let shared = LinkEnrichmentStore()

    static let maximumEntries = 500

    private enum MemoryEntry {
        case payload(LinkEnrichmentPayload)
        case miss
    }

    private let lock = NSLock()
    private var memory: [String: MemoryEntry] = [:]
    private var memoryOrder: [String] = []
    private let directory: URL
    private static let logger = Logger(subsystem: "com.scopy.app", category: "LinkEnrichment")

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scopy/LinkEnrichment", isDirectory: true)
    }

    func payload(forContentKey key: String) -> LinkEnrichmentPayload? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = memory[key] {
            touchMemoryEntryLocked(key)
            switch cached {
            case .payload(let payload): return payload
            case .miss: return nil
            }
        }
        let loaded = readFromDisk(key: key)
        cacheLocked(loaded.map(MemoryEntry.payload) ?? .miss, key: key)
        return loaded
    }

    func write(_ payload: LinkEnrichmentPayload, forContentKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        cacheLocked(.payload(payload), key: key)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL(key: key), options: .atomic)
        } catch {
            Self.logger.error("Could not persist link enrichment: \(String(describing: error), privacy: .public)")
        }
        pruneLocked()
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

    private func pruneLocked() {
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

    private func cacheLocked(_ entry: MemoryEntry, key: String) {
        memory[key] = entry
        touchMemoryEntryLocked(key)
        while memoryOrder.count > Self.maximumEntries {
            memory.removeValue(forKey: memoryOrder.removeFirst())
        }
    }

    private func touchMemoryEntryLocked(_ key: String) {
        if let index = memoryOrder.firstIndex(of: key) {
            memoryOrder.remove(at: index)
        }
        memoryOrder.append(key)
    }
}
