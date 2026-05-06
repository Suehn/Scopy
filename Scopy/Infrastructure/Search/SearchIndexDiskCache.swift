import CryptoKit
import Foundation
import os

enum SearchIndexDiskCache {
    private static let fullIndexDiskCacheVersion: Int = 3
    private static let fullIndexDiskCacheMetadataVersion: Int = 1
    private static let shortQueryIndexDiskCacheVersion: Int = 1

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
        fileprivate let cache: FullIndexDiskCacheV3
        fileprivate let metadata: SearchEngineImpl.FullIndexDiskCacheMetadataV1
        fileprivate let cachePath: String
        fileprivate let checksumPath: String
        fileprivate let metadataPath: String
    }

    struct ShortPersistRequest: Sendable {
        fileprivate let cache: ShortQueryIndexDiskCacheV1
        fileprivate let cachePath: String
        fileprivate let checksumPath: String
    }

    fileprivate struct FullIndexDiskCacheV3: Codable, Sendable {
        let version: Int
        let dbFileSize: UInt64
        let dbFileModifiedAt: TimeInterval
        let walFileSize: UInt64
        let walFileModifiedAt: TimeInterval
        let shmFileSize: UInt64
        let shmFileModifiedAt: TimeInterval
        let items: [DiskIndexedItem?]
        let asciiCharPostings: [[Int]]
        let nonASCIICharPostings: [String: [Int]]
    }

    struct ShortQueryIndexDiskCacheV1: Codable, Sendable {
        let version: Int
        let dbFileSize: UInt64
        let dbFileModifiedAt: TimeInterval
        let walFileSize: UInt64
        let walFileModifiedAt: TimeInterval
        let shmFileSize: UInt64
        let shmFileModifiedAt: TimeInterval
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
        let cachePath = "\(dbPath).fullindex.v\(fullIndexDiskCacheVersion).plist"
        return FullPaths(
            cachePath: cachePath,
            checksumPath: cachePath + ".sha256",
            metadataPath: cachePath + ".metadata.plist"
        )
    }

    static func shortPaths(dbPath: String) -> ShortPaths {
        let cachePath = "\(dbPath).shortindex.v\(shortQueryIndexDiskCacheVersion).plist"
        return ShortPaths(cachePath: cachePath, checksumPath: cachePath + ".sha256")
    }

    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func loadShortSnapshot(dbPath: String) -> SearchEngineImpl.ShortQueryIndexSnapshot? {
        guard let fp = dbFileFingerprint(dbPath: dbPath) else { return nil }
        let paths = shortPaths(dbPath: dbPath)
        guard FileManager.default.fileExists(atPath: paths.cachePath) else { return nil }

        guard let checksumRaw = try? String(contentsOfFile: paths.checksumPath, encoding: .utf8) else { return nil }
        let checksum = checksumRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard checksum.count == 64 else { return nil }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: paths.cachePath), options: [.mappedIfSafe]) else {
            return nil
        }

        let computedChecksum = sha256Hex(data)
        guard computedChecksum == checksum else { return nil }

        let decoder = PropertyListDecoder()
        guard let cache = try? decoder.decode(ShortQueryIndexDiskCacheV1.self, from: data) else { return nil }
        guard cache.version == shortQueryIndexDiskCacheVersion else { return nil }
        guard cache.dbFileSize == fp.dbSize,
              cache.dbFileModifiedAt == fp.dbModifiedAt,
              cache.walFileSize == fp.walSize,
              cache.walFileModifiedAt == fp.walModifiedAt,
              cache.shmFileSize == fp.shmSize,
              cache.shmFileModifiedAt == fp.shmModifiedAt else {
            return nil
        }

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

        guard let fp = dbFileFingerprint(dbPath: dbPath) else {
            return .skip(reason: .payloadInvalid, metadata: nil)
        }

        guard FileManager.default.fileExists(atPath: paths.metadataPath),
              let metadataData = try? Data(contentsOf: URL(fileURLWithPath: paths.metadataPath), options: [.mappedIfSafe]) else {
            guard FileManager.default.fileExists(atPath: paths.checksumPath) else {
                return .skip(reason: .metadataMissing, metadata: nil)
            }
            return .candidate(
                SearchEngineImpl.FullIndexDiskCacheLoadCandidate(
                    fingerprint: fp,
                    metadata: nil,
                    cachePath: paths.cachePath,
                    checksumPath: paths.checksumPath,
                    metadataPath: paths.metadataPath,
                    preflightReason: .metadataMissing
                )
            )
        }

        let decoder = PropertyListDecoder()
        guard let metadata = try? decoder.decode(SearchEngineImpl.FullIndexDiskCacheMetadataV1.self, from: metadataData),
              metadata.version == fullIndexDiskCacheMetadataVersion else {
            guard FileManager.default.fileExists(atPath: paths.checksumPath) else {
                return .skip(reason: .metadataMissing, metadata: nil)
            }
            return .candidate(
                SearchEngineImpl.FullIndexDiskCacheLoadCandidate(
                    fingerprint: fp,
                    metadata: nil,
                    cachePath: paths.cachePath,
                    checksumPath: paths.checksumPath,
                    metadataPath: paths.metadataPath,
                    preflightReason: .metadataMissing
                )
            )
        }

        guard fullIndexCacheFingerprintMatches(metadata.fingerprint, fp) else {
            return .skip(reason: .fingerprintMismatch, metadata: metadata)
        }

        let isTombstoneStale = SearchEngineImpl.shouldMarkFullIndexStaleDueToTombstones(
            itemCount: metadata.itemCount,
            tombstoneCount: metadata.tombstoneCount
        )
        if isTombstoneStale {
            return .skip(reason: .tombstoneStale, metadata: metadata)
        }

        guard FileManager.default.fileExists(atPath: paths.checksumPath) else {
            return .skip(reason: .payloadInvalid, metadata: metadata)
        }

        return .candidate(
            SearchEngineImpl.FullIndexDiskCacheLoadCandidate(
                fingerprint: fp,
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

        let parseResult = decodeFullIndexDiskCachePayload(data, fingerprint: candidate.fingerprint)
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
            fingerprint: candidate.fingerprint,
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
        dbPath: String
    ) -> ShortPersistRequest? {
        guard index.asciiCharPostingsCount == 128 else { return nil }
        guard let fp = dbFileFingerprint(dbPath: dbPath) else { return nil }
        let paths = shortPaths(dbPath: dbPath)
        return ShortPersistRequest(
            cache: index.toDiskCache(version: shortQueryIndexDiskCacheVersion, fp: fp),
            cachePath: paths.cachePath,
            checksumPath: paths.checksumPath
        )
    }

    static func writeShortPersistRequest(_ request: ShortPersistRequest) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(request.cache)
        try data.write(to: URL(fileURLWithPath: request.cachePath), options: [.atomic])
        let checksum = sha256Hex(data)
        try checksum.write(to: URL(fileURLWithPath: request.checksumPath), atomically: true, encoding: .utf8)
    }

    static func makeFullPersistRequest(
        index: SearchEngineImpl.FullFuzzyIndex,
        dbPath: String
    ) -> FullPersistRequest? {
        guard index.asciiCharPostings.count == 128 else { return nil }
        guard let fp = dbFileFingerprint(dbPath: dbPath) else { return nil }

        var nonASCII: [String: [Int]] = [:]
        nonASCII.reserveCapacity(index.nonASCIICharPostings.count)
        for (ch, postings) in index.nonASCIICharPostings {
            nonASCII[String(ch)] = postings
        }

        let cache = FullIndexDiskCacheV3(
            version: fullIndexDiskCacheVersion,
            dbFileSize: fp.dbSize,
            dbFileModifiedAt: fp.dbModifiedAt,
            walFileSize: fp.walSize,
            walFileModifiedAt: fp.walModifiedAt,
            shmFileSize: fp.shmSize,
            shmFileModifiedAt: fp.shmModifiedAt,
            items: index.items.map { $0.map(DiskIndexedItem.init(from:)) },
            asciiCharPostings: index.asciiCharPostings,
            nonASCIICharPostings: nonASCII
        )
        let metadata = makeFullIndexDiskCacheMetadata(fingerprint: fp, index: index, payloadByteSize: 0)
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
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(request.cache)
        try data.write(to: URL(fileURLWithPath: request.cachePath), options: [.atomic])
        let checksum = sha256Hex(data)
        try checksum.write(to: URL(fileURLWithPath: request.checksumPath), atomically: true, encoding: .utf8)
        let metadataWithPayloadSize = SearchEngineImpl.FullIndexDiskCacheMetadataV1(
            version: request.metadata.version,
            fingerprint: request.metadata.fingerprint,
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

    private static func dbFileFingerprint(
        dbPath: String
    ) -> SearchEngineImpl.DBFileFingerprint? {
        do {
            let dbAttrs = try FileManager.default.attributesOfItem(atPath: dbPath)
            guard let dbSize = dbAttrs[.size] as? NSNumber,
                  let dbModifiedAt = dbAttrs[.modificationDate] as? Date else {
                return nil
            }

            let walPath = "\(dbPath)-wal"
            var walSize: UInt64 = 0
            var walModifiedAt: TimeInterval = 0
            if FileManager.default.fileExists(atPath: walPath) {
                let walAttrs = try FileManager.default.attributesOfItem(atPath: walPath)
                guard let size = walAttrs[.size] as? NSNumber,
                      let modifiedAt = walAttrs[.modificationDate] as? Date else {
                    return nil
                }
                walSize = size.uint64Value
                walModifiedAt = modifiedAt.timeIntervalSince1970
            }

            let shmPath = "\(dbPath)-shm"
            var shmSize: UInt64 = 0
            var shmModifiedAt: TimeInterval = 0
            if FileManager.default.fileExists(atPath: shmPath) {
                let shmAttrs = try FileManager.default.attributesOfItem(atPath: shmPath)
                guard let size = shmAttrs[.size] as? NSNumber,
                      let modifiedAt = shmAttrs[.modificationDate] as? Date else {
                    return nil
                }
                shmSize = size.uint64Value
                shmModifiedAt = modifiedAt.timeIntervalSince1970
            }

            return SearchEngineImpl.DBFileFingerprint(
                dbSize: dbSize.uint64Value,
                dbModifiedAt: dbModifiedAt.timeIntervalSince1970,
                walSize: walSize,
                walModifiedAt: walModifiedAt,
                shmSize: shmSize,
                shmModifiedAt: shmModifiedAt
            )
        } catch {
            return nil
        }
    }

    private static func makeFullIndexDiskCacheMetadata(
        fingerprint: SearchEngineImpl.DBFileFingerprint,
        index: SearchEngineImpl.FullFuzzyIndex,
        payloadByteSize: Int
    ) -> SearchEngineImpl.FullIndexDiskCacheMetadataV1 {
        SearchEngineImpl.FullIndexDiskCacheMetadataV1(
            version: fullIndexDiskCacheMetadataVersion,
            fingerprint: fingerprint,
            itemCount: index.items.count,
            tombstoneCount: index.tombstoneCount,
            tombstoneRatio: index.items.isEmpty ? 0 : Double(index.tombstoneCount) / Double(index.items.count),
            payloadByteSize: UInt64(max(0, payloadByteSize))
        )
    }

    private static func persistFullIndexDiskCacheMetadataIfPossible(
        _ metadata: SearchEngineImpl.FullIndexDiskCacheMetadataV1,
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

    private static func fullIndexCacheFingerprintMatches(
        _ lhs: SearchEngineImpl.DBFileFingerprint,
        _ rhs: SearchEngineImpl.DBFileFingerprint
    ) -> Bool {
        lhs.dbSize == rhs.dbSize &&
        lhs.dbModifiedAt == rhs.dbModifiedAt &&
        lhs.walSize == rhs.walSize &&
        lhs.walModifiedAt == rhs.walModifiedAt
    }

    private static func recordFullIndexDiskCacheMetadataCounters(
        _ metadata: SearchEngineImpl.FullIndexDiskCacheMetadataV1?,
        metrics: inout SearchEngineImpl.SearchWarmLoadMetrics
    ) {
        guard let metadata else { return }
        metrics.addCounter("full_index_cache_metadata_item_count", value: metadata.itemCount)
        metrics.addCounter("full_index_cache_metadata_tombstone_count", value: metadata.tombstoneCount)
        metrics.addCounter("full_index_cache_metadata_tombstone_ratio_bps", value: Int((metadata.tombstoneRatio * 10_000).rounded()))
        metrics.addCounter("full_index_cache_metadata_payload_bytes", value: Int(min(metadata.payloadByteSize, UInt64(Int.max))))
    }

    private static func decodeFullIndexDiskCachePayload(
        _ data: Data,
        fingerprint: SearchEngineImpl.DBFileFingerprint
    ) -> FullIndexDiskCachePayloadParseResult {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return .decodeFailed
        }
        guard let payload = root as? [String: Any] else {
            return .payloadInvalid
        }

        guard plistInt(payload["version"]) == fullIndexDiskCacheVersion else {
            return .payloadInvalid
        }
        guard plistUInt64(payload["dbFileSize"]) == fingerprint.dbSize,
              plistTimeInterval(payload["dbFileModifiedAt"]) == fingerprint.dbModifiedAt else {
            return .payloadInvalid
        }
        guard plistUInt64(payload["walFileSize"]) == fingerprint.walSize,
              plistTimeInterval(payload["walFileModifiedAt"]) == fingerprint.walModifiedAt else {
            return .payloadInvalid
        }
        guard let rawItems = payload["items"] as? [Any],
              let rawASCIIPostings = payload["asciiCharPostings"] as? [Any],
              rawASCIIPostings.count == 128,
              let rawNonASCIIPostings = payload["nonASCIICharPostings"] as? [String: Any] else {
            return .payloadInvalid
        }

        var items: [SearchEngineImpl.IndexedItem?] = []
        items.reserveCapacity(rawItems.count)

        var idToSlot: [UUID: Int] = [:]
        idToSlot.reserveCapacity(rawItems.count)

        for (slot, rawItem) in rawItems.enumerated() {
            if rawItem is NSNull {
                items.append(nil)
                continue
            }
            guard let diskItem = rawItem as? [String: Any],
                  let idString = plistString(diskItem["id"]),
                  let id = UUID(uuidString: idString),
                  let typeRaw = plistString(diskItem["type"]),
                  let type = ClipboardItemType(rawValue: typeRaw),
                  let contentHash = plistString(diskItem["contentHash"]),
                  let plainTextLower = plistString(diskItem["plainTextLower"]),
                  let createdAt = plistTimeInterval(diskItem["createdAt"]),
                  let lastUsedAt = plistTimeInterval(diskItem["lastUsedAt"]),
                  let useCount = plistInt(diskItem["useCount"]),
                  let isPinned = plistBool(diskItem["isPinned"]),
                  let sizeBytes = plistInt(diskItem["sizeBytes"]) else {
                return .payloadInvalid
            }

            let item = SearchEngineImpl.IndexedItem(
                id: id,
                type: type,
                contentHash: contentHash,
                plainTextLower: plainTextLower,
                appBundleID: plistOptionalString(diskItem["appBundleID"]),
                createdAt: Date(timeIntervalSince1970: createdAt),
                lastUsedAt: Date(timeIntervalSince1970: lastUsedAt),
                useCount: useCount,
                isPinned: isPinned,
                sizeBytes: sizeBytes,
                storageRef: plistOptionalString(diskItem["storageRef"])
            )
            items.append(item)
            idToSlot[id] = slot
        }

        let itemsCount = items.count

        var asciiCharPostings: [[Int]] = []
        asciiCharPostings.reserveCapacity(rawASCIIPostings.count)
        for rawPostings in rawASCIIPostings {
            guard let postings = rawPostings as? [Int],
                  validateDiskCachePostings(postings, itemsCount: itemsCount) else {
                return .payloadInvalid
            }
            asciiCharPostings.append(postings)
        }

        var nonASCIICharPostings: [Character: [Int]] = [:]
        nonASCIICharPostings.reserveCapacity(rawNonASCIIPostings.count)
        for (rawKey, rawPostings) in rawNonASCIIPostings {
            guard rawKey.count == 1,
                  let character = rawKey.first,
                  let postings = rawPostings as? [Int],
                  validateDiskCachePostings(postings, itemsCount: itemsCount) else {
                return .payloadInvalid
            }
            nonASCIICharPostings[character] = postings
        }

        let tombstones = max(0, items.count - idToSlot.count)
        return .success(
            SearchEngineImpl.FullFuzzyIndex(
                items: items,
                idToSlot: idToSlot,
                asciiCharPostings: asciiCharPostings,
                nonASCIICharPostings: nonASCIICharPostings,
                tombstoneCount: tombstones
            )
        )
    }

    private static func plistString(_ value: Any?) -> String? {
        value as? String
    }

    private static func plistOptionalString(_ value: Any?) -> String? {
        value as? String
    }

    private static func plistBool(_ value: Any?) -> Bool? {
        value as? Bool
    }

    private static func plistInt(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private static func plistUInt64(_ value: Any?) -> UInt64? {
        if let uint64Value = value as? UInt64 {
            return uint64Value
        }
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        return nil
    }

    private static func plistTimeInterval(_ value: Any?) -> TimeInterval? {
        if let timeIntervalValue = value as? TimeInterval {
            return timeIntervalValue
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        return nil
    }
}
