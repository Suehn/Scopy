import CryptoKit
import Foundation

/// Shared origin cache for previews and exports. Fetching is bounded and off the UI actor;
/// only decoded, downscaled PNG bytes reach WebKit. Successful entries also work offline.
actor SourceIconService {
    static let shared = SourceIconService()
    static let maximumEntries = 256
    private struct Entry: Codable {
        let png: Data?
        let fetchedAt: Date
    }
    private struct Flight {
        let task: Task<Data?, Never>
        var consumers: Set<UUID>
        var didPersist = false
    }
    private let fetcher: LinkEnrichmentFetcher
    private let directory: URL
    private let pool = AsyncPermitPool(limit: 6, maxPending: 24)
    private var cache: [String: Entry] = [:]
    private var flights: [String: Flight] = [:]

    init(directory: URL? = nil, fetcher: LinkEnrichmentFetcher = .init(requestTimeout: 2, resourceTimeout: 4)) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scopy/SourceIcons", isDirectory: true)
        self.fetcher = fetcher
    }

    func icon(origin: URL, allowNetwork: Bool) async -> Data? {
        let key = SHA256.hash(data: Data(origin.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        if cache[key] == nil, let data = try? Data(contentsOf: fileURL(key)), data.count <= 48 * 1024,
           let entry = try? JSONDecoder().decode(Entry.self, from: data) {
            remember(entry, key: key)
        }
        if let entry = cache[key] {
            let ttl: TimeInterval = entry.png == nil ? 3600 : 30 * 86400
            if !allowNetwork || Date().timeIntervalSince(entry.fetchedAt) < ttl { return entry.png }
        }
        guard allowNetwork, !Task.isCancelled else { return cache[key]?.png }
        let consumer = UUID()
        if flights[key] == nil {
            let fetcher = self.fetcher
            let pool = self.pool
            let task = Task {
                guard await pool.acquire() else { return nil as Data? }
                let png = await fetcher.fetchFavicon(origin: origin)
                await pool.release()
                return Task.isCancelled ? nil : png
            }
            flights[key] = Flight(task: task, consumers: [])
        }
        flights[key]?.consumers.insert(consumer)
        guard let task = flights[key]?.task else { return nil }
        return await withTaskCancellationHandler(operation: {
            let result = await task.value
            guard !Task.isCancelled else { release(key: key, consumer: consumer); return nil }
            if !task.isCancelled, flights[key]?.didPersist == false {
                flights[key]?.didPersist = true
                // Keep a previously valid icon on a transient refresh failure.
                let entry = Entry(png: result ?? cache[key]?.png, fetchedAt: Date())
                remember(entry, key: key)
                persist(entry, key: key)
            }
            release(key: key, consumer: consumer)
            return cache[key]?.png
        }, onCancel: {
            Task { await self.release(key: key, consumer: consumer) }
        })
    }

    private func release(key: String, consumer: UUID) {
        guard flights[key]?.consumers.remove(consumer) != nil else { return }
        if flights[key]?.consumers.isEmpty == true {
            flights.removeValue(forKey: key)?.task.cancel()
        }
    }

    private func fileURL(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }

    private func remember(_ entry: Entry, key: String) {
        cache[key] = entry
        if cache.count > Self.maximumEntries,
           let oldest = cache.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
            cache.removeValue(forKey: oldest)
        }
    }

    private func persist(_ entry: Entry, key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entry) { try? data.write(to: fileURL(key), options: .atomic) }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                  includingPropertiesForKeys: [.contentModificationDateKey]), files.count > Self.maximumEntries else { return }
        let sorted = files.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for file in sorted.prefix(files.count - Self.maximumEntries) { try? FileManager.default.removeItem(at: file) }
    }
}
