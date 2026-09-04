import CryptoKit
import Foundation
import os

enum SearchIndexDiskCache {
    private static let fullIndexDiskCacheVersion: Int = 5
    private static let fullIndexDiskCacheMetadataVersion: Int = 2
    private static let shortQueryIndexDiskCacheVersion: Int = 3

    struct FullPaths: Sendable {
        let cachePath: String
        let checksumPath: String
        let metadataPath: String
    }

    struct ShortPaths: Sendable {
        let cachePath: String
        let checksumPath: String
    }

    struct FullPersistRequest: Sendable {
        fileprivate let cache: FullIndexDiskCacheV4
        fileprivate let metadata: SearchEngineImpl.FullIndexDiskCacheMetadataV2
        fileprivate let cachePath: String
        fileprivate let checksumPath: String
        fileprivate let metadataPath: String
    }

    struct ShortPersistRequest: Sendable {
        fileprivate let cache: ShortQueryIndexDiskCacheV2
        fileprivate let cachePath: String
        fileprivate let checksumPath: String
    }

    fileprivate struct FullIndexDiskCacheV4: Codable, Sendable {
        let version: Int
        let mutationSeq: Int64
        let items: [DiskIndexedItem?]
        let asciiCharPostings: [[Int]]
        let nonASCIICharPostings: [String: [Int]]
    }

    struct ShortQueryIndexDiskCacheV2: Codable, Sendable {
        let version: Int
        let mutationSeq: Int64
        let slots: [DiskShortQuerySlot]
        let asciiCharPostings: [[Int]]
        let asciiBigramPostings: [DiskUInt16Postings]
        let nonASCIIBigramPostings: [DiskUInt32Postings]
    }

    struct DiskShortQuerySlot: Codable, Sendable {
        let id: String?
        let contentHash: String
        let type: String
        let plainTextHash: String?
        let noteHash: String?
    }

    struct DiskUInt16Postings: Codable, Sendable {
        let key: UInt16
        let postings: [Int]
    }

    struct DiskUInt32Postings: Codable, Sendable {
        let key: UInt32
        let postings: [Int]
    }

    fileprivate struct DiskIndexedItem: Codable, Sendable {
        let id: String
        let type: String
        let contentHash: String
        let plainTextLower: String
        let appBundleID: String?
        let createdAt: TimeInterval
        let lastUsedAt: TimeInterval
        let useCount: Int
        let isPinned: Bool
        let sizeBytes: Int
        let storageRef: String?

        init(from item: SearchEngineImpl.IndexedItem) {
            self.id = item.id.uuidString
            self.type = item.type.rawValue
            self.contentHash = item.contentHash
            self.plainTextLower = item.plainTextLower
            self.appBundleID = item.appBundleID
            self.createdAt = item.createdAt.timeIntervalSince1970
            self.lastUsedAt = item.lastUsedAt.timeIntervalSince1970
            self.useCount = item.useCount
            self.isPinned = item.isPinned
            self.sizeBytes = item.sizeBytes
            self.storageRef = item.storageRef
        }
    }

    private enum FullIndexDiskCachePayloadParseResult: Sendable {
        case success(SearchEngineImpl.FullFuzzyIndex)
        case decodeFailed
        case payloadInvalid
    }

    static func fullPaths(dbPath: String) -> FullPaths {
        let cachePath = "\(dbPath).fullindex.v\(fullIndexDiskCacheVersion).bin"
        return FullPaths(
            cachePath: cachePath,
            checksumPath: cachePath + ".sha256",
            metadataPath: cachePath + ".metadata.plist"
        )
    }

    static func shortPaths(dbPath: String) -> ShortPaths {
        let cachePath = "\(dbPath).shortindex.v\(shortQueryIndexDiskCacheVersion).bin"
        return ShortPaths(cachePath: cachePath, checksumPath: cachePath + ".sha256")
    }

    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Deletes cache files written by other (older) cache versions next to the database.
    static func removeStaleCacheFiles(dbPath: String) {
        let dbURL = URL(fileURLWithPath: dbPath)
        let directory = dbURL.deletingLastPathComponent()
        let dbName = dbURL.lastPathComponent
        let full = fullPaths(dbPath: dbPath)
        let short = shortPaths(dbPath: dbPath)
        let currentPrefixes = [full.cachePath, short.cachePath].map { URL(fileURLWithPath: $0).lastPathComponent }
        let stalePrefixes = ["\(dbName).fullindex.", "\(dbName).shortindex."]

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            guard stalePrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            guard !currentPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func loadShortSnapshot(dbPath: String) -> SearchEngineImpl.ShortQueryIndexSnapshot? {
        guard let stamp = dbContentStamp(dbPath: dbPath) else { return nil }
        let paths = shortPaths(dbPath: dbPath)
        guard FileManager.default.fileExists(atPath: paths.cachePath) else { return nil }

        guard let checksumRaw = try? String(contentsOfFile: paths.checksumPath, encoding: .utf8) else { return nil }
        let checksum = checksumRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard checksum.count == 64 else { return nil }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: paths.cachePath), options: [.mappedIfSafe]) else {
            return nil
        }

        // A stale cache (every commit bumps mutation_seq) is rejected from its header before the
        // checksum and decode touch the payload.
        guard let header = SearchIndexBinaryCodec.header(of: data),
              header.format == SearchIndexBinaryCodec.shortFormat,
              header.version == shortQueryIndexDiskCacheVersion,
              header.mutationSeq == stamp.mutationSeq else { return nil }

        let computedChecksum = sha256Hex(data)
        guard computedChecksum == checksum else { return nil }

        guard let cache = SearchIndexBinaryCodec.decodeShort(data) else { return nil }
        guard cache.version == shortQueryIndexDiskCacheVersion else { return nil }
        guard cache.mutationSeq == stamp.mutationSeq else { return nil }
        let liveSlotCount = cache.slots.lazy.filter { $0.id != nil }.count
        guard liveSlotCount == stamp.itemCount else { return nil }

        guard cache.asciiCharPostings.count == 128 else { return nil }

        let slotCount = cache.slots.count
        for postings in cache.asciiCharPostings {
            if !validateDiskCachePostings(postings, itemsCount: slotCount) { return nil }
        }
        for entry in cache.asciiBigramPostings {
            if entry.key >= 16384 { return nil }
            if !validateDiskCachePostings(entry.postings, itemsCount: slotCount) { return nil }
        }
        for entry in cache.nonASCIIBigramPostings {
            if !validateDiskCachePostings(entry.postings, itemsCount: slotCount) { return nil }
        }

        guard let index = SearchEngineImpl.ShortQueryIndex(diskCache: cache) else { return nil }
        return SearchEngineImpl.ShortQueryIndexSnapshot(index: index, source: .diskCache)
    }

    static func loadFullSnapshot(
        dbPath: String,
        metrics: inout SearchEngineImpl.SearchWarmLoadMetrics
    ) -> SearchEngineImpl.FullIndexSnapshot? {
        let preflight = metrics.measure("full_index_disk_cache_preflight") {
            preflightFullIndex(dbPath: dbPath)
        }

        switch preflight {
        case .skip(let reason, let metadata):
            metrics.addReason(reason)
            recordFullIndexDiskCacheMetadataCounters(metadata, metrics: &metrics)
            return nil
        case .candidate(let candidate):
            if let preflightReason = candidate.preflightReason {
                metrics.addReason(preflightReason)
            }
            recordFullIndexDiskCacheMetadataCounters(candidate.metadata, metrics: &metrics)
            let outcome = metrics.measure("full_index_disk_cache_load") {
                loadFullSnapshot(from: candidate)
            }
            recordFullIndexDiskCacheMetadataCounters(outcome.metadata, metrics: &metrics)
            metrics.addReason(outcome.reason)
            guard let snapshot = outcome.snapshot else { return nil }
            metrics.markSource(snapshot.source)
            return snapshot
        }
    }

    static func preflightFullIndex(dbPath: String) -> SearchEngineImpl.FullIndexDiskCachePreflightResult {
        let paths = fullPaths(dbPath: dbPath)
        guard FileManager.default.fileExists(atPath: paths.cachePath) else {
            return .skip(reason: .metadataMissing, metadata: nil)
        }

        guard let stamp = dbContentStamp(dbPath: dbPath) else {
            return .skip(reason: .fingerprintMismatch, metadata: nil)
        }

        guard FileManager.default.fileExists(atPath: paths.metadataPath),
              let metadataData = try? Data(contentsOf: URL(fileURLWithPath: paths.metadataPath), options: [.mappedIfSafe]) else {
            guard FileManager.default.fileExists(atPath: paths.checksumPath) else {
                return .skip(reason: .metadataMissing, metadata: nil)
            }
            return .candidate(
                SearchEngineImpl.FullIndexDiskCacheLoadCandidate(
                    stamp: stamp,
                    metadata: nil,
                    cachePath: paths.cachePath,
                    checksumPath: paths.checksumPath,
                    metadataPath: paths.metadataPath,
                    preflightReason: .metadataMissing
                )
            )
        }

        let decoder = PropertyListDecoder()
        guard let metadata = try? decoder.decode(SearchEngineImpl.FullIndexDiskCacheMetadataV2.self, from: metadataData),
              metadata.version == fullIndexDiskCacheMetadataVersion else {
            guard FileManager.default.fileExists(atPath: paths.checksumPath) else {
                return .skip(reason: .metadataMissing, metadata: nil)
            }
            return .candidate(
                SearchEngineImpl.FullIndexDiskCacheLoadCandidate(
                    stamp: stamp,
                    metadata: nil,
                    cachePath: paths.cachePath,
                    checksumPath: paths.checksumPath,
                    metadataPath: paths.metadataPath,
                    preflightReason: .metadataMissing
                )
            )
        }

        guard metadata.mutationSeq == stamp.mutationSeq else {
            return .skip(reason: .fingerprintMismatch, metadata: metadata)
        }

        let isTombstoneStale = SearchEngineImpl.shouldMarkFullIndexStaleDueToTombstones(
            itemCount: metadata.itemCount,
            tombstoneCount: metadata.tombstoneCount
        )
        if isTombstoneStale {
            return .skip(reason: .tombstoneStale, metadata: metadata)
        }

        // Live count must line up with scopy_meta: guards against a swapped-in database whose
        // mutation_seq happens to collide with the cached one.
        guard metadata.itemCount - metadata.tombstoneCount == stamp.itemCount else {
            return .skip(reason: .fingerprintMismatch, metadata: metadata)
        }

        guard FileManager.default.fileExists(atPath: paths.checksumPath) else {
            return .skip(reason: .payloadInvalid, metadata: metadata)
        }

        return .candidate(
            SearchEngineImpl.FullIndexDiskCacheLoadCandidate(
                stamp: stamp,
                metadata: metadata,
                cachePath: paths.cachePath,
                checksumPath: paths.checksumPath,
                metadataPath: paths.metadataPath,
                preflightReason: nil
            )
        )
    }

    static func loadFullSnapshot(
        from candidate: SearchEngineImpl.FullIndexDiskCacheLoadCandidate
    ) -> SearchEngineImpl.FullIndexDiskCacheLoadOutcome {
        #if DEBUG
        let loadStart = CFAbsoluteTimeGetCurrent()
        #endif

        guard let checksumRaw = try? String(contentsOfFile: candidate.checksumPath, encoding: .utf8) else {
            return SearchEngineImpl.FullIndexDiskCacheLoadOutcome(snapshot: nil, reason: .payloadInvalid, metadata: candidate.metadata)
        }
        let checksum = checksumRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard checksum.count == 64 else {
            return SearchEngineImpl.FullIndexDiskCacheLoadOutcome(snapshot: nil, reason: .payloadInvalid, metadata: candidate.metadata)
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: candidate.cachePath), options: [.mappedIfSafe]) else {
            return SearchEngineImpl.FullIndexDiskCacheLoadOutcome(snapshot: nil, reason: .payloadInvalid, metadata: candidate.metadata)
        }

        let computedChecksum = sha256Hex(data)
        guard computedChecksum == checksum else {
            return SearchEngineImpl.FullIndexDiskCacheLoadOutcome(snapshot: nil, reason: .checksumMismatch, metadata: candidate.metadata)
        }

        let parseResult = decodeFullIndexDiskCachePayload(data, stamp: candidate.stamp)
        let index: SearchEngineImpl.FullFuzzyIndex
        switch parseResult {
        case .success(let parsedIndex):
            index = parsedIndex
        case .decodeFailed:
            return SearchEngineImpl.FullIndexDiskCacheLoadOutcome(snapshot: nil, reason: .decodeFailed, metadata: candidate.metadata)
        case .payloadInvalid:
            return SearchEngineImpl.FullIndexDiskCacheLoadOutcome(snapshot: nil, reason: .payloadInvalid, metadata: candidate.metadata)
        }

        let metadata = candidate.metadata ?? makeFullIndexDiskCacheMetadata(
            mutationSeq: candidate.stamp.mutationSeq,
            index: index,
            payloadByteSize: data.count
        )
        if candidate.metadata == nil {
            persistFullIndexDiskCacheMetadataIfPossible(metadata, at: candidate.metadataPath)
        }
        if SearchEngineImpl.shouldMarkFullIndexStaleDueToTombstones(
            itemCount: index.items.count,
            tombstoneCount: index.tombstoneCount
        ) {
            return SearchEngineImpl.FullIndexDiskCacheLoadOutcome(snapshot: nil, reason: .tombstoneStale, metadata: metadata)
        }

        // Same invariant as preflight for the metadata-bootstrap path: a cache is valid only
        // when its mutation_seq AND live item count both match scopy_meta.
        guard index.idToSlot.count == candidate.stamp.itemCount else {
            return SearchEngineImpl.FullIndexDiskCacheLoadOutcome(snapshot: nil, reason: .fingerprintMismatch, metadata: metadata)
        }

        #if DEBUG
        let totalMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
        ScopyLog.search.debug(
            "Loaded fullIndex disk cache via metadata preflight: bytes=\(data.count, privacy: .public) totalMs=\(totalMs, privacy: .public)"
        )
        #endif

        return SearchEngineImpl.FullIndexDiskCacheLoadOutcome(
            snapshot: SearchEngineImpl.FullIndexSnapshot(index: index, startDataVersion: 0, endDataVersion: 0, source: .diskCache),
            reason: .diskCacheHit,
            metadata: metadata
        )
    }

    static func makeShortPersistRequest(
        index: SearchEngineImpl.ShortQueryIndex,
        dbPath: String,
        mutationSeq: Int64
    ) -> ShortPersistRequest? {
        guard index.asciiCharPostingsCount == 128 else { return nil }
        let paths = shortPaths(dbPath: dbPath)
        return ShortPersistRequest(
            cache: index.toDiskCache(version: shortQueryIndexDiskCacheVersion, mutationSeq: mutationSeq),
            cachePath: paths.cachePath,
            checksumPath: paths.checksumPath
        )
    }

    static func writeShortPersistRequest(_ request: ShortPersistRequest) throws {
        let data = SearchIndexBinaryCodec.encodeShort(request.cache)
        try data.write(to: URL(fileURLWithPath: request.cachePath), options: [.atomic])
        let checksum = sha256Hex(data)
        try checksum.write(to: URL(fileURLWithPath: request.checksumPath), atomically: true, encoding: .utf8)
    }

    static func makeFullPersistRequest(
        index: SearchEngineImpl.FullFuzzyIndex,
        dbPath: String,
        mutationSeq: Int64
    ) -> FullPersistRequest? {
        guard index.asciiCharPostings.count == 128 else { return nil }

        var nonASCII: [String: [Int]] = [:]
        nonASCII.reserveCapacity(index.nonASCIICharPostings.count)
        for (ch, postings) in index.nonASCIICharPostings {
            nonASCII[String(ch)] = postings
        }

        let cache = FullIndexDiskCacheV4(
            version: fullIndexDiskCacheVersion,
            mutationSeq: mutationSeq,
            items: index.items.map { $0.map(DiskIndexedItem.init(from:)) },
            asciiCharPostings: index.asciiCharPostings,
            nonASCIICharPostings: nonASCII
        )
        let metadata = makeFullIndexDiskCacheMetadata(mutationSeq: mutationSeq, index: index, payloadByteSize: 0)
        let paths = fullPaths(dbPath: dbPath)
        return FullPersistRequest(
            cache: cache,
            metadata: metadata,
            cachePath: paths.cachePath,
            checksumPath: paths.checksumPath,
            metadataPath: paths.metadataPath
        )
    }

    static func writeFullPersistRequest(_ request: FullPersistRequest) throws {
        let data = encodeFullPayload(request.cache)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try data.write(to: URL(fileURLWithPath: request.cachePath), options: [.atomic])
        let checksum = sha256Hex(data)
        try checksum.write(to: URL(fileURLWithPath: request.checksumPath), atomically: true, encoding: .utf8)
        let metadataWithPayloadSize = SearchEngineImpl.FullIndexDiskCacheMetadataV2(
            version: request.metadata.version,
            mutationSeq: request.metadata.mutationSeq,
            itemCount: request.metadata.itemCount,
            tombstoneCount: request.metadata.tombstoneCount,
            tombstoneRatio: request.metadata.tombstoneRatio,
            payloadByteSize: UInt64(data.count)
        )
        let metadataData = try encoder.encode(metadataWithPayloadSize)
        try metadataData.write(to: URL(fileURLWithPath: request.metadataPath), options: [.atomic])
    }

    private static func validateDiskCachePostings(_ postings: [Int], itemsCount: Int) -> Bool {
        guard !postings.isEmpty else { return true }

        let first = postings[0]
        if first < 0 { return false }

        let last = postings[postings.count - 1]
        if last >= itemsCount { return false }

        // Sample a few indices to catch obviously corrupted or unsorted postings without scanning the full array.
        if postings.count > 1 {
            var indices = [
                0,
                postings.count / 4,
                postings.count / 2,
                (postings.count * 3) / 4,
                postings.count - 1,
            ]
            indices.sort()

            var previousIndex: Int = -1
            var previousValue: Int = -1
            for index in indices {
                if index == previousIndex { continue }
                let value = postings[index]
                if value < 0 || value >= itemsCount { return false }
                if previousValue >= 0, value <= previousValue { return false }
                previousIndex = index
                previousValue = value
            }
        }

        // Validate small windows at the beginning and end (cheap and catches many truncation/corruption patterns).
        let window = min(8, postings.count)
        var previous = postings[0]
        for i in 1..<window {
            let value = postings[i]
            if value <= previous { return false }
            previous = value
        }
        if postings.count > window {
            previous = postings[postings.count - window]
            for i in (postings.count - window + 1)..<postings.count {
                let value = postings[i]
                if value <= previous { return false }
                previous = value
            }
        }

        return true
    }

    /// Reads the logical content stamp from `scopy_meta`. Databases without that table
    /// (never migrated by StorageService) simply don't participate in disk caching.
    private static func dbContentStamp(dbPath: String) -> SearchEngineImpl.DBContentStamp? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        let flags = SQLiteConnection.openFlags(for: dbPath, readOnly: true)
        guard let conn = try? SQLiteConnection(path: dbPath, flags: flags) else { return nil }
        defer { conn.close() }

        do {
            try conn.execute("PRAGMA query_only = 1")
            try conn.execute("PRAGMA busy_timeout = 500")
            let stmt = try conn.prepare("SELECT mutation_seq, item_count FROM scopy_meta WHERE id = 1")
            guard try stmt.step() else { return nil }
            return SearchEngineImpl.DBContentStamp(
                mutationSeq: stmt.columnInt64(0),
                itemCount: stmt.columnInt(1)
            )
        } catch {
            return nil
        }
    }

    private static func makeFullIndexDiskCacheMetadata(
        mutationSeq: Int64,
        index: SearchEngineImpl.FullFuzzyIndex,
        payloadByteSize: Int
    ) -> SearchEngineImpl.FullIndexDiskCacheMetadataV2 {
        SearchEngineImpl.FullIndexDiskCacheMetadataV2(
            version: fullIndexDiskCacheMetadataVersion,
            mutationSeq: mutationSeq,
            itemCount: index.items.count,
            tombstoneCount: index.tombstoneCount,
            tombstoneRatio: index.items.isEmpty ? 0 : Double(index.tombstoneCount) / Double(index.items.count),
            payloadByteSize: UInt64(max(0, payloadByteSize))
        )
    }

    private static func persistFullIndexDiskCacheMetadataIfPossible(
        _ metadata: SearchEngineImpl.FullIndexDiskCacheMetadataV2,
        at path: String
    ) {
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(metadata)
            try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        } catch {
            // Best-effort cache metadata bootstrap: ignore failures.
        }
    }

    private static func recordFullIndexDiskCacheMetadataCounters(
        _ metadata: SearchEngineImpl.FullIndexDiskCacheMetadataV2?,
        metrics: inout SearchEngineImpl.SearchWarmLoadMetrics
    ) {
        guard let metadata else { return }
        metrics.addCounter("full_index_cache_metadata_item_count", value: metadata.itemCount)
        metrics.addCounter("full_index_cache_metadata_tombstone_count", value: metadata.tombstoneCount)
        metrics.addCounter("full_index_cache_metadata_tombstone_ratio_bps", value: Int((metadata.tombstoneRatio * 10_000).rounded()))
        metrics.addCounter("full_index_cache_metadata_payload_bytes", value: Int(min(metadata.payloadByteSize, UInt64(Int.max))))
    }

    private static func encodeFullPayload(_ cache: FullIndexDiskCacheV4) -> Data {
        SearchIndexBinaryCodec.encodeFull(
            version: cache.version,
            mutationSeq: cache.mutationSeq,
            items: cache.items.map { item in
                item.map {
                    SearchIndexBinaryCodec.FullItem(
                        id: $0.id, type: $0.type, contentHash: $0.contentHash, plainTextLower: $0.plainTextLower,
                        appBundleID: $0.appBundleID, createdAt: $0.createdAt, lastUsedAt: $0.lastUsedAt,
                        useCount: $0.useCount, isPinned: $0.isPinned, sizeBytes: $0.sizeBytes, storageRef: $0.storageRef
                    )
                }
            },
            asciiCharPostings: cache.asciiCharPostings,
            nonASCIICharPostings: cache.nonASCIICharPostings.keys.sorted().map { key in
                (key: key, postings: cache.nonASCIICharPostings[key] ?? [])
            }
        )
    }

    private static func decodeFullIndexDiskCachePayload(
        _ data: Data,
        stamp: SearchEngineImpl.DBContentStamp
    ) -> FullIndexDiskCachePayloadParseResult {
        guard let payload = SearchIndexBinaryCodec.decodeFull(data) else {
            return .decodeFailed
        }
        guard payload.version == fullIndexDiskCacheVersion else {
            return .payloadInvalid
        }
        guard payload.mutationSeq == stamp.mutationSeq else {
            return .payloadInvalid
        }
        guard payload.asciiCharPostings.count == 128 else {
            return .payloadInvalid
        }

        var items: [SearchEngineImpl.IndexedItem?] = []
        items.reserveCapacity(payload.items.count)

        var idToSlot: [UUID: Int] = [:]
        idToSlot.reserveCapacity(payload.items.count)

        for (slot, diskItem) in payload.items.enumerated() {
            guard let diskItem else {
                items.append(nil)
                continue
            }
            guard let id = UUID(uuidString: diskItem.id),
                  let type = ClipboardItemType(rawValue: diskItem.type) else {
                return .payloadInvalid
            }
            items.append(
                SearchEngineImpl.IndexedItem(
                    id: id,
                    type: type,
                    contentHash: diskItem.contentHash,
                    plainTextLower: diskItem.plainTextLower,
                    appBundleID: diskItem.appBundleID,
                    createdAt: Date(timeIntervalSince1970: diskItem.createdAt),
                    lastUsedAt: Date(timeIntervalSince1970: diskItem.lastUsedAt),
                    useCount: diskItem.useCount,
                    isPinned: diskItem.isPinned,
                    sizeBytes: diskItem.sizeBytes,
                    storageRef: diskItem.storageRef
                )
            )
            idToSlot[id] = slot
        }

        let itemsCount = items.count
        for postings in payload.asciiCharPostings {
            guard validateDiskCachePostings(postings, itemsCount: itemsCount) else {
                return .payloadInvalid
            }
        }

        var nonASCIICharPostings: [Character: [Int]] = [:]
        nonASCIICharPostings.reserveCapacity(payload.nonASCIICharPostings.count)
        for entry in payload.nonASCIICharPostings {
            guard entry.key.count == 1,
                  let character = entry.key.first,
                  nonASCIICharPostings[character] == nil,
                  validateDiskCachePostings(entry.postings, itemsCount: itemsCount) else {
                return .payloadInvalid
            }
            nonASCIICharPostings[character] = entry.postings
        }

        let tombstones = max(0, items.count - idToSlot.count)
        return .success(
            SearchEngineImpl.FullFuzzyIndex(
                items: items,
                idToSlot: idToSlot,
                asciiCharPostings: payload.asciiCharPostings,
                nonASCIICharPostings: nonASCIICharPostings,
                tombstoneCount: tombstones
            )
        )
    }

    // MARK: - Test seams

    static func debugDecodeShortCache(_ data: Data) -> ShortQueryIndexDiskCacheV2? {
        SearchIndexBinaryCodec.decodeShort(data)
    }

    static func debugEncodeShortCache(_ cache: ShortQueryIndexDiskCacheV2) -> Data {
        SearchIndexBinaryCodec.encodeShort(cache)
    }

    static func debugDecodeFullPayload(_ data: Data) -> SearchIndexBinaryCodec.FullPayload? {
        SearchIndexBinaryCodec.decodeFull(data)
    }

    static func debugEncodeFullPayload(_ payload: SearchIndexBinaryCodec.FullPayload, asciiCharPostings: [[Int]]) -> Data {
        SearchIndexBinaryCodec.encodeFull(
            version: payload.version,
            mutationSeq: payload.mutationSeq,
            items: payload.items,
            asciiCharPostings: asciiCharPostings,
            nonASCIICharPostings: payload.nonASCIICharPostings
        )
    }

}
