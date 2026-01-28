import CryptoKit
import Foundation
import SQLite3
import os

public actor SearchEngineImpl {
    // MARK: - Types

    public enum SearchError: Error, LocalizedError {
        case databaseNotOpen
        case invalidQuery(String)
        case searchFailed(String)
        case timeout

        public var errorDescription: String? {
            switch self {
            case .databaseNotOpen: return "Database is not open"
            case .invalidQuery(let msg): return "Invalid query: \(msg)"
            case .searchFailed(let msg): return "Search failed: \(msg)"
            case .timeout: return "Search timed out"
            }
        }
    }

    public struct SearchPerfMetrics: Sendable {
        public struct Phase: Sendable {
            public let name: String
            public let ms: Double

            public init(name: String, ms: Double) {
                self.name = name
                self.ms = ms
            }
        }

        public struct Counter: Sendable {
            public let name: String
            public let value: Int

            public init(name: String, value: Int) {
                self.name = name
                self.value = value
            }
        }

        public let phases: [Phase]
        public let counters: [Counter]

        public init(phases: [Phase], counters: [Counter]) {
            self.phases = phases
            self.counters = counters
        }
    }

    public struct SearchResult: Sendable {
        public let items: [ClipboardStoredItem]
        public let total: Int
        public let hasMore: Bool
        public let isPrefilter: Bool
        public let searchTimeMs: Double
        public let perf: SearchPerfMetrics?

        public init(
            items: [ClipboardStoredItem],
            total: Int,
            hasMore: Bool,
            isPrefilter: Bool,
            searchTimeMs: Double,
            perf: SearchPerfMetrics? = nil
        ) {
            self.items = items
            self.total = total
            self.hasMore = hasMore
            self.isPrefilter = isPrefilter
            self.searchTimeMs = searchTimeMs
            self.perf = perf
        }
    }

    private struct SQLiteInterruptHandle: @unchecked Sendable {
        let handle: OpaquePointer
    }

    private enum Perf {
        static let metricsEnabled: Bool = ProcessInfo.processInfo.environment["SCOPY_PERF_METRICS"] == "1"
        static let signpostsEnabled: Bool = ProcessInfo.processInfo.environment["SCOPY_PERF_SIGNPOSTS"] == "1"
        static let log = OSLog(subsystem: "com.scopy.app", category: "perf")
    }

    private final class PerfContext {
        private(set) var phases: [SearchPerfMetrics.Phase] = []
        private(set) var counters: [SearchPerfMetrics.Counter] = []

        func addPhase(_ name: String, ms: Double) {
            phases.append(SearchPerfMetrics.Phase(name: name, ms: ms))
        }

        func addCounter(_ name: String, value: Int) {
            counters.append(SearchPerfMetrics.Counter(name: name, value: value))
        }

        func measure<T>(_ name: String, _ block: () throws -> T) rethrows -> T {
            let start = CFAbsoluteTimeGetCurrent()
            defer {
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
                addPhase(name, ms: elapsedMs)
            }
            return try block()
        }

        func measureAsync<T>(_ name: String, _ block: () async throws -> T) async rethrows -> T {
            let start = CFAbsoluteTimeGetCurrent()
            defer {
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
                addPhase(name, ms: elapsedMs)
            }
            return try await block()
        }

        func snapshot() -> SearchPerfMetrics {
            SearchPerfMetrics(phases: phases, counters: counters)
        }
    }

    private struct CachedRecentItem {
        let item: ClipboardStoredItem
        let combinedLower: String
    }

    private struct IndexedItem: Sendable {
        let id: UUID
        let type: ClipboardItemType
        let contentHash: String
        let plainTextLower: String
        let appBundleID: String?
        let createdAt: Date
        var lastUsedAt: Date
        var useCount: Int
        var isPinned: Bool
        let sizeBytes: Int
        let storageRef: String?

        init(from item: ClipboardStoredItem) {
            self.id = item.id
            self.type = item.type
            self.contentHash = item.contentHash
            var combined = item.plainText
            if let note = item.note, !note.isEmpty {
                combined.append("\n")
                combined.append(note)
            }
            let lower = combined.lowercased()
            self.plainTextLower = lower
            self.appBundleID = item.appBundleID
            self.createdAt = item.createdAt
            self.lastUsedAt = item.lastUsedAt
            self.useCount = item.useCount
            self.isPinned = item.isPinned
            self.sizeBytes = item.sizeBytes
            self.storageRef = item.storageRef
        }

        init(
            id: UUID,
            type: ClipboardItemType,
            contentHash: String,
            plainTextLower: String,
            appBundleID: String?,
            createdAt: Date,
            lastUsedAt: Date,
            useCount: Int,
            isPinned: Bool,
            sizeBytes: Int,
            storageRef: String?
        ) {
            self.id = id
            self.type = type
            self.contentHash = contentHash
            self.plainTextLower = plainTextLower
            self.appBundleID = appBundleID
            self.createdAt = createdAt
            self.lastUsedAt = lastUsedAt
            self.useCount = useCount
            self.isPinned = isPinned
            self.sizeBytes = sizeBytes
            self.storageRef = storageRef
        }
    }

    private struct FullFuzzyIndex: Sendable {
        var items: [IndexedItem?]
        var idToSlot: [UUID: Int]
        // ASCII-only char index: 128
        var asciiCharPostings: [[Int]]
        var nonASCIICharPostings: [Character: [Int]]
        var tombstoneCount: Int
    }

    private enum FullIndexSnapshotSource: String, Sendable {
        case database
        case diskCache
    }

    private struct FullIndexSnapshot: Sendable {
        let index: FullFuzzyIndex
        let startDataVersion: Int64
        let endDataVersion: Int64
        let source: FullIndexSnapshotSource
    }

    private enum ShortQueryIndexSnapshotSource: String, Sendable {
        case database
        case diskCache
    }

    private struct ShortQueryIndexSnapshot: Sendable {
        let index: ShortQueryIndex
        let source: ShortQueryIndexSnapshotSource
    }

    private struct FullIndexDiskCacheV3: Codable, Sendable {
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

    private struct ShortQueryIndexDiskCacheV1: Codable, Sendable {
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

    private struct DiskShortQuerySlot: Codable, Sendable {
        let id: String?
        let contentHash: String
        let type: String
        let plainTextHash: String?
        let noteHash: String?
    }

    private struct DiskUInt16Postings: Codable, Sendable {
        let key: UInt16
        let postings: [Int]
    }

    private struct DiskUInt32Postings: Codable, Sendable {
        let key: UInt32
        let postings: [Int]
    }

    private struct DiskIndexedItem: Codable, Sendable {
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

        init(from item: IndexedItem) {
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

    private struct ShortQueryIndex: Sendable {
        // ASCII-only char index: 128
        private static let asciiCharCount = 128
        // ASCII-only bigram index: 128 * 128
        private static let asciiBigramCount = 128 * 128

        private var slotToIDString: [String?] = []
        private var slotToContentHash: [String] = []
        private var slotToType: [ClipboardItemType] = []
        private var slotToPlainTextHash: [String?] = []
        private var slotToNoteHash: [String?] = []
        private var idToSlot: [UUID: Int] = [:]

        private var asciiCharPostings: [[Int]] = Array(repeating: [], count: Self.asciiCharCount)
        // Key: (a << 7) | b
        private var asciiBigramPostings: [UInt16: [Int]] = [:]

        // Key: (a << 16) | b
        //
        // This covers the hottest non-ASCII short query case (e.g. 2 CJK chars like “数学”),
        // where SQLite `instr()` substring scans become expensive on large text corpora.
        private var nonASCIIBigramPostings: [UInt32: [Int]] = [:]

        // Scratch stamps to keep postings unique per ingestion pass.
        private var ingestStamp: UInt32 = 1
        private var seenASCIICharStamp: [UInt32] = Array(repeating: 0, count: Self.asciiCharCount)
        private var seenASCIIBigramStamp: [UInt32] = Array(repeating: 0, count: Self.asciiBigramCount)
        private var seenNonASCIIBigramStamp: [UInt32: UInt32] = [:]

        // Scratch stamps to deduplicate candidate lists at query time.
        private var candidateStamp: UInt32 = 1
        private var slotCandidateStamp: [UInt32] = []

        init(reserveSlots: Int) {
            let reserve = max(0, reserveSlots)
            slotToIDString.reserveCapacity(reserve)
            slotToContentHash.reserveCapacity(reserve)
            slotToType.reserveCapacity(reserve)
            slotToPlainTextHash.reserveCapacity(reserve)
            slotToNoteHash.reserveCapacity(reserve)
            idToSlot.reserveCapacity(reserve)
            slotCandidateStamp.reserveCapacity(reserve)
        }

        func healthStats() -> (slots: Int, live: Int, tombstones: Int) {
            let slots = slotToIDString.count
            let live = idToSlot.count
            let tombstones = max(0, slots - live)
            return (slots, live, tombstones)
        }

        mutating func markDeleted(id: UUID) {
            guard let slot = idToSlot.removeValue(forKey: id),
                  slot < slotToIDString.count else {
                return
            }
            slotToIDString[slot] = nil
        }

        mutating func upsert(_ item: ClipboardStoredItem) {
            upsert(
                id: item.id,
                type: item.type,
                contentHash: item.contentHash,
                plainText: item.plainText,
                note: item.note
            )
        }

        mutating func upsert(
            id: UUID,
            type: ClipboardItemType,
            contentHash: String,
            plainText: String,
            note: String?
        ) {
            let newPlainTextHash: String? = (type == .text) ? nil : SearchEngineImpl.sha256Hex(Data(plainText.utf8))
            let newNoteHash: String? = note.flatMap { raw in
                guard !raw.isEmpty else { return nil }
                return SearchEngineImpl.sha256Hex(Data(raw.utf8))
            }

            if let slot = idToSlot[id],
               slot < slotToIDString.count {
                if slot < slotToContentHash.count,
                   slot < slotToType.count,
                   slot < slotToPlainTextHash.count,
                   slot < slotToNoteHash.count {
                    let shouldReindex: Bool
                    if type == .text {
                        // For text items, contentHash tracks plain_text changes well; avoid re-ingesting on usage updates.
                        shouldReindex = slotToContentHash[slot] != contentHash || slotToType[slot] != type || slotToNoteHash[slot] != newNoteHash
                    } else {
                        // For non-text items, plain_text may change without affecting contentHash (e.g. "[Image: ...]").
                        // Track a separate plainTextHash to avoid re-indexing on pure metadata updates.
                        shouldReindex = slotToContentHash[slot] != contentHash
                            || slotToType[slot] != type
                            || slotToPlainTextHash[slot] != newPlainTextHash
                            || slotToNoteHash[slot] != newNoteHash
                    }
                    if !shouldReindex { return }
                }

                // Never ingest into an existing slot: postings must remain strictly increasing to keep disk cache valid.
                markDeleted(id: id)
            }

            let slot = slotToIDString.count
            let idString = id.uuidString
            slotToIDString.append(idString)
            slotToContentHash.append(contentHash)
            slotToType.append(type)
            slotToPlainTextHash.append(newPlainTextHash)
            slotToNoteHash.append(newNoteHash)
            idToSlot[id] = slot
            slotCandidateStamp.append(0)

            ingestASCII(plainText: plainText, note: note, slot: slot)
            ingestNonASCIIBigramsUTF16(plainText: plainText, note: note, slot: slot)
        }

        mutating func candidateIDStrings(for tokenLower: String) -> [String] {
            let token = tokenLower.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return [] }
            guard token.canBeConverted(to: .ascii) else { return [] }

            let bytes = Array(token.utf8)
            guard bytes.count == 1 || bytes.count == 2 else { return [] }

            func lowerASCII(_ b: UInt8) -> UInt8 {
                if b >= 65 && b <= 90 { return b | 0x20 }
                return b
            }

            let slots: [Int]
            switch bytes.count {
            case 1:
                let c = Int(lowerASCII(bytes[0]))
                guard c >= 0 && c < Self.asciiCharCount else { return [] }
                slots = asciiCharPostings[c]
            case 2:
                let a = Int(lowerASCII(bytes[0]))
                let b = Int(lowerASCII(bytes[1]))
                guard a >= 0 && a < Self.asciiCharCount, b >= 0 && b < Self.asciiCharCount else { return [] }
                let key = UInt16((a << 7) | b)
                slots = asciiBigramPostings[key] ?? []
            default:
                return []
            }

            if slots.isEmpty { return [] }

            return uniqueIDStrings(from: slots)
        }

        mutating func candidateIDStringsForNonASCIIBigram(tokenLower: String) -> [String]? {
            let token = tokenLower.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return nil }
            guard !token.canBeConverted(to: .ascii) else { return nil }

            var units: [UInt16] = []
            units.reserveCapacity(2)
            for cu in token.utf16 {
                units.append(cu)
                if units.count > 2 { break }
            }

            // Only handle the hottest case: 2-UTF16-unit tokens that are fully non-ASCII.
            // Examples:
            // - "数学" => 2 units (CJK), supported.
            // - "😀"  => 2 units (surrogates), supported as a single Unicode scalar.
            guard units.count == 2,
                  units[0] >= 128,
                  units[1] >= 128 else {
                return nil
            }

            let key = (UInt32(units[0]) << 16) | UInt32(units[1])
            let slots = nonASCIIBigramPostings[key] ?? []
            if slots.isEmpty { return [] }
            return uniqueIDStrings(from: slots)
        }

        private mutating func uniqueIDStrings(from slots: [Int]) -> [String] {
            candidateStamp &+= 1
            if candidateStamp == 0 {
                candidateStamp = 1
                slotCandidateStamp = Array(repeating: 0, count: slotCandidateStamp.count)
            }

            var result: [String] = []
            result.reserveCapacity(min(256, slots.count))

            for slot in slots {
                guard slot < slotToIDString.count else { continue }
                if slot < slotCandidateStamp.count {
                    if slotCandidateStamp[slot] == candidateStamp { continue }
                    slotCandidateStamp[slot] = candidateStamp
                }
                if let id = slotToIDString[slot] {
                    result.append(id)
                }
            }
            return result
        }

        private mutating func ingestASCII(plainText: String, note: String?, slot: Int) {
            guard !plainText.isEmpty || (note?.isEmpty == false) else { return }

            ingestStamp &+= 1
            if ingestStamp == 0 {
                ingestStamp = 1
                seenASCIICharStamp = Array(repeating: 0, count: seenASCIICharStamp.count)
                seenASCIIBigramStamp = Array(repeating: 0, count: seenASCIIBigramStamp.count)
                seenNonASCIIBigramStamp.removeAll(keepingCapacity: true)
            }

            @inline(__always)
            func lowerASCII(_ b: UInt8) -> UInt8 {
                if b >= 65 && b <= 90 { return b | 0x20 }
                return b
            }

            func ingestPart(_ text: String) {
                var prev: UInt8? = nil
                for raw in text.utf8 {
                    guard raw < 128 else {
                        prev = nil
                        continue
                    }

                    let b = lowerASCII(raw)

                    let c = Int(b)
                    if seenASCIICharStamp[c] != ingestStamp {
                        seenASCIICharStamp[c] = ingestStamp
                        asciiCharPostings[c].append(slot)
                    }

                    if let p = prev {
                        let key = UInt16((Int(p) << 7) | Int(b))
                        let idx = Int(key)
                        if seenASCIIBigramStamp[idx] != ingestStamp {
                            seenASCIIBigramStamp[idx] = ingestStamp
                            asciiBigramPostings[key, default: []].append(slot)
                        }
                    }
                    prev = b
                }
            }

            if !plainText.isEmpty {
                ingestPart(plainText)
            }
            if let note, !note.isEmpty {
                ingestPart(note)
            }
        }

        private mutating func ingestNonASCIIBigramsUTF16(plainText: String, note: String?, slot: Int) {
            guard !plainText.isEmpty || (note?.isEmpty == false) else { return }

            ingestStamp &+= 1
            if ingestStamp == 0 {
                ingestStamp = 1
                seenASCIICharStamp = Array(repeating: 0, count: seenASCIICharStamp.count)
                seenASCIIBigramStamp = Array(repeating: 0, count: seenASCIIBigramStamp.count)
                seenNonASCIIBigramStamp.removeAll(keepingCapacity: true)
            }

            func ingestPart(_ text: String) {
                var prev: UInt16? = nil
                for cu in text.utf16 {
                    guard cu >= 128 else {
                        prev = nil
                        continue
                    }

                    if let p = prev {
                        let key = (UInt32(p) << 16) | UInt32(cu)
                        if seenNonASCIIBigramStamp[key] != ingestStamp {
                            seenNonASCIIBigramStamp[key] = ingestStamp
                            nonASCIIBigramPostings[key, default: []].append(slot)
                        }
                    }
                    prev = cu
                }
            }

            if !plainText.isEmpty {
                ingestPart(plainText)
            }
            if let note, !note.isEmpty {
                ingestPart(note)
            }
        }

        var asciiCharPostingsCount: Int {
            asciiCharPostings.count
        }

        func toDiskCache(
            version: Int,
            fp: (
                dbSize: UInt64,
                dbModifiedAt: TimeInterval,
                walSize: UInt64,
                walModifiedAt: TimeInterval,
                shmSize: UInt64,
                shmModifiedAt: TimeInterval
            )
        ) -> ShortQueryIndexDiskCacheV1 {
            var slots: [DiskShortQuerySlot] = []
            slots.reserveCapacity(slotToIDString.count)
            for i in 0..<slotToIDString.count {
                slots.append(
                    DiskShortQuerySlot(
                        id: slotToIDString[i],
                        contentHash: slotToContentHash[i],
                        type: slotToType[i].rawValue,
                        plainTextHash: slotToPlainTextHash[i],
                        noteHash: slotToNoteHash[i]
                    )
                )
            }

            let asciiBigramKeys = asciiBigramPostings.keys.sorted()
            var asciiBigram: [DiskUInt16Postings] = []
            asciiBigram.reserveCapacity(asciiBigramKeys.count)
            for key in asciiBigramKeys {
                asciiBigram.append(DiskUInt16Postings(key: key, postings: asciiBigramPostings[key] ?? []))
            }

            let nonASCIIBigramKeys = nonASCIIBigramPostings.keys.sorted()
            var nonASCIIBigram: [DiskUInt32Postings] = []
            nonASCIIBigram.reserveCapacity(nonASCIIBigramKeys.count)
            for key in nonASCIIBigramKeys {
                nonASCIIBigram.append(DiskUInt32Postings(key: key, postings: nonASCIIBigramPostings[key] ?? []))
            }

            return ShortQueryIndexDiskCacheV1(
                version: version,
                dbFileSize: fp.dbSize,
                dbFileModifiedAt: fp.dbModifiedAt,
                walFileSize: fp.walSize,
                walFileModifiedAt: fp.walModifiedAt,
                shmFileSize: fp.shmSize,
                shmFileModifiedAt: fp.shmModifiedAt,
                slots: slots,
                asciiCharPostings: asciiCharPostings,
                asciiBigramPostings: asciiBigram,
                nonASCIIBigramPostings: nonASCIIBigram
            )
        }

        init?(diskCache: ShortQueryIndexDiskCacheV1) {
            let slotCount = diskCache.slots.count
            self = ShortQueryIndex(reserveSlots: slotCount)

            slotToIDString = diskCache.slots.map(\.id)
            slotToContentHash = diskCache.slots.map(\.contentHash)
            slotToPlainTextHash = diskCache.slots.map(\.plainTextHash)
            slotToNoteHash = diskCache.slots.map(\.noteHash)

            slotToType = []
            slotToType.reserveCapacity(slotCount)

            idToSlot = [:]
            idToSlot.reserveCapacity(slotCount)

            for (slot, entry) in diskCache.slots.enumerated() {
                guard let type = ClipboardItemType(rawValue: entry.type) else { return nil }
                slotToType.append(type)

                if let idString = entry.id {
                    guard let id = UUID(uuidString: idString) else { return nil }
                    idToSlot[id] = slot
                }
            }

            asciiCharPostings = diskCache.asciiCharPostings

            asciiBigramPostings = [:]
            asciiBigramPostings.reserveCapacity(diskCache.asciiBigramPostings.count)
            for entry in diskCache.asciiBigramPostings {
                if asciiBigramPostings[entry.key] != nil { return nil }
                asciiBigramPostings[entry.key] = entry.postings
            }

            nonASCIIBigramPostings = [:]
            nonASCIIBigramPostings.reserveCapacity(diskCache.nonASCIIBigramPostings.count)
            for entry in diskCache.nonASCIIBigramPostings {
                if nonASCIIBigramPostings[entry.key] != nil { return nil }
                nonASCIIBigramPostings[entry.key] = entry.postings
            }

            ingestStamp = 1
            candidateStamp = 1
            seenNonASCIIBigramStamp = [:]
            seenASCIICharStamp = Array(repeating: 0, count: Self.asciiCharCount)
            seenASCIIBigramStamp = Array(repeating: 0, count: Self.asciiBigramCount)
            slotCandidateStamp = Array(repeating: 0, count: slotCount)
        }
    }

    private struct CorpusMetrics: Sendable {
        let itemCount: Int
        let avgPlainTextLength: Double
        let maxPlainTextLength: Int

        var isHeavyPlainTextCorpus: Bool {
            // Heuristic: long-text corpus makes full-history fuzzy scanning expensive/unpredictable.
            // - avg ≥ 1k chars OR max ≥ 100k chars => prefer FTS for interactive fuzzy queries.
            avgPlainTextLength >= 1024 || maxPlainTextLength >= 100_000
        }
    }

    private struct ScoredSlot {
        let slot: Int
        let score: Int
    }

    private struct BinaryHeap<Element> {
        private(set) var elements: [Element] = []
        private let areSorted: (Element, Element) -> Bool

        init(areSorted: @escaping (Element, Element) -> Bool) {
            self.areSorted = areSorted
        }

        var count: Int { elements.count }
        var peek: Element? { elements.first }

        mutating func reserveCapacity(_ n: Int) {
            elements.reserveCapacity(n)
        }

        mutating func insert(_ value: Element) {
            elements.append(value)
            siftUp(from: elements.count - 1)
        }

        mutating func replaceRoot(with value: Element) {
            guard !elements.isEmpty else {
                elements = [value]
                return
            }
            elements[0] = value
            siftDown(from: 0)
        }

        private mutating func siftUp(from index: Int) {
            var child = index
            var parent = (child - 1) / 2
            while child > 0 && areSorted(elements[child], elements[parent]) {
                elements.swapAt(child, parent)
                child = parent
                parent = (child - 1) / 2
            }
        }

        private mutating func siftDown(from index: Int) {
            var parent = index
            while true {
                let left = parent * 2 + 1
                let right = left + 1
                var candidate = parent

                if left < elements.count && areSorted(elements[left], elements[candidate]) {
                    candidate = left
                }
                if right < elements.count && areSorted(elements[right], elements[candidate]) {
                    candidate = right
                }

                if candidate == parent { return }
                elements.swapAt(parent, candidate)
                parent = candidate
            }
        }
    }

    // MARK: - Properties

    private let dbPath: String
    private var connection: SQLiteConnection?
    private var usesMutationSeq: Bool = false
    private var knownDBChangeToken: Int64?

    private var recentItemsCache: [CachedRecentItem] = []
    private var cacheTimestamp: Date = .distantPast
    private let cacheDuration: TimeInterval = 30.0
    private let shortQueryCacheSize = 2000

    private var fullIndex: FullFuzzyIndex?
    private var fullIndexStale = true
    private var fullIndexGeneration: UInt64 = 0
    private var observedMutationCounter: UInt64 = 0

#if DEBUG
    private var debugFullIndexLastSnapshotSourceValue: FullIndexSnapshotSource?
    private var debugShortQueryIndexLastSnapshotSourceValue: ShortQueryIndexSnapshotSource?
#endif

    private enum FullIndexPendingEvent: Sendable {
        case upsert(ClipboardStoredItem)
        case delete(UUID)
        case pin(UUID, Bool)
    }

    private var fullIndexBuildTask: Task<Void, Never>?
    private var fullIndexBuildGeneration: UInt64 = 0
    private var fullIndexPendingEvents: [FullIndexPendingEvent] = []
    private var fullIndexDiskCachePersistTask: Task<Void, Never>?

    private var shortQueryIndex: ShortQueryIndex?
    private var shortQueryIndexBuildTask: Task<Void, Never>?
    private var shortQueryIndexBuildGeneration: UInt64 = 0
    private var shortQueryIndexPendingUpserts: [ClipboardStoredItem] = []
    private var shortQueryIndexPendingDeletions: [UUID] = []
    private var shortQueryIndexDiskCachePersistTask: Task<Void, Never>?

    private let fullIndexTombstoneRatioStaleThreshold: Double = 0.25
    private let fullIndexTombstoneMinSlotsForStale: Int = 64
    private let fullIndexTombstoneMinCountForStale: Int = 16

    private let shortQueryIndexTombstoneRatioRebuildThreshold: Double = 0.25
    private let shortQueryIndexTombstoneMinSlotsForRebuild: Int = 2000
    private let shortQueryIndexTombstoneMinCountForRebuild: Int = 256

    private struct CachedStatement {
        let sql: String
        let statement: SQLiteStatement
    }

    private var statementCache: [String: CachedStatement] = [:]
    private var statementCacheLRU: [String] = []
    private let statementCacheLimit = 32

    private struct FuzzySortedMatchesCacheKey: Hashable {
        let mode: SearchMode
        let sortMode: SearchSortMode
        let queryLower: String
        let appFilter: String?
        let typeFilter: ClipboardItemType?
        let typeFiltersKey: String?
        let forceFullFuzzy: Bool
        let indexGeneration: UInt64
    }

    private struct FuzzySortedMatchesCacheValue {
        let key: FuzzySortedMatchesCacheKey
        let totalMatches: Int
        let topMatches: [ScoredSlot] // Already sorted by isBetterSlot; may be truncated for deep paging.
    }

    private var fuzzySortedMatchesCache: FuzzySortedMatchesCacheValue?

    private let searchTimeout: TimeInterval = 5.0
    private let initialIndexBuildTimeout: TimeInterval = 30.0

    private static let fullIndexDiskCacheVersion: Int = 3
    private static let shortQueryIndexDiskCacheVersion: Int = 1

    private var corpusMetrics: CorpusMetrics?
    private var corpusMetricsUpdatedAt: Date = .distantPast

    private var charPostingsScratchASCII: [Bool] = Array(repeating: false, count: 128)
    private var charPostingsScratchNonASCII: Set<Character> = []

    private var supportsTrigramFTS: Bool = false

    // MARK: - Initialization

    public init(dbPath: String) {
        self.dbPath = dbPath
    }

    // MARK: - Lifecycle

    public func open() throws {
        try openIfNeeded()
    }

    public func close() async {
        fullIndexBuildTask?.cancel()
        fullIndexBuildTask = nil
        fullIndexBuildGeneration &+= 1
        fullIndexPendingEvents = []

        shortQueryIndexBuildTask?.cancel()
        shortQueryIndexBuildTask = nil
        shortQueryIndexBuildGeneration &+= 1

        scheduleShortQueryIndexDiskCachePersistIfPossible()
        if let task = shortQueryIndexDiskCachePersistTask {
            _ = try? await withTimeout(timeout: 0.25) { await task.value }
        }

        shortQueryIndex = nil
        shortQueryIndexPendingUpserts = []
        shortQueryIndexPendingDeletions = []

        scheduleFullIndexDiskCachePersistIfPossible()
        if let task = fullIndexDiskCachePersistTask {
            _ = try? await withTimeout(timeout: 0.25) { await task.value }
        }

        statementCache = [:]
        statementCacheLRU = []
        fuzzySortedMatchesCache = nil
        corpusMetrics = nil
        corpusMetricsUpdatedAt = .distantPast
        supportsTrigramFTS = false
        knownDBChangeToken = nil
        usesMutationSeq = false
        connection?.close()
        connection = nil
    }

    // MARK: - Cache / Index Updates

    public func invalidateCache() {
        resetRecentCache()
        resetFullIndex()
        resetShortQueryIndex()
        markCorpusMetricsStale()
        refreshKnownDBChangeTokenIfPossible()
        startShortQueryIndexBuildIfNeeded()
    }

    func handleUpsertedItem(_ item: ClipboardStoredItem) {
        observedMutationCounter &+= 1
        if invalidateInMemoryIndexesIfDBChangedExternallyBeforeApplyingInternalMutationIfNeeded() {
            return
        }
        resetQueryCaches()
        handleShortQueryIndexUpsert(item)

        var shouldStaleCorpusMetrics = false

        if fullIndexBuildTask != nil {
            fullIndexPendingEvents.append(.upsert(item))
            markCorpusMetricsStale()
            return
        }

        guard var index = fullIndex, !fullIndexStale else {
            // Index not built yet; upserts may change corpus size/shape before first search.
            markCorpusMetricsStale()
            return
        }

        // Keep the full index always usable by applying upserts incrementally.
        // For text/note changes, we may create tombstones to avoid expensive postings removals.
        let beforeTombstones = index.tombstoneCount
        shouldStaleCorpusMetrics = upsertItemIntoIndex(item, index: &index)

        fullIndex = index
        markIndexChanged()

        if index.tombstoneCount > beforeTombstones,
           shouldMarkFullIndexStaleDueToTombstones(index: index) {
            fullIndexStale = true
            startFullIndexBuildIfNeeded(force: true)
        }

        if shouldStaleCorpusMetrics {
            markCorpusMetricsStale()
        }
    }

    func handlePinnedChange(id: UUID, pinned: Bool) {
        observedMutationCounter &+= 1
        if invalidateInMemoryIndexesIfDBChangedExternallyBeforeApplyingInternalMutationIfNeeded() {
            return
        }
        resetQueryCaches()

        if fullIndexBuildTask != nil {
            fullIndexPendingEvents.append(.pin(id, pinned))
            return
        }

        guard var index = fullIndex,
              !fullIndexStale,
              let slot = index.idToSlot[id],
              slot < index.items.count,
              let existing = index.items[slot] else {
            return
        }

        var updated = existing
        updated.isPinned = pinned
        index.items[slot] = updated
        fullIndex = index
        markIndexChanged()
    }

    func handleDeletion(id: UUID) {
        observedMutationCounter &+= 1
        if invalidateInMemoryIndexesIfDBChangedExternallyBeforeApplyingInternalMutationIfNeeded() {
            return
        }
        markCorpusMetricsStale()
        handleShortQueryIndexDeletion(id: id)

        if fullIndexBuildTask != nil {
            fullIndexPendingEvents.append(.delete(id))
            resetQueryCaches()
            return
        }

        if var index = fullIndex,
           !fullIndexStale,
           let slot = index.idToSlot[id],
           slot < index.items.count {
            if index.items[slot] != nil {
                index.items[slot] = nil
                index.tombstoneCount += 1
            }
            index.idToSlot.removeValue(forKey: id)
            fullIndex = index
            markIndexChanged()

            if shouldMarkFullIndexStaleDueToTombstones(index: index) {
                fullIndexStale = true
                startFullIndexBuildIfNeeded(force: true)
            }
        }

        resetQueryCaches()
    }

    func handleClearAll() {
        observedMutationCounter &+= 1
        invalidateCache()
    }

    private func resetRecentCache() {
        recentItemsCache = []
        cacheTimestamp = .distantPast
    }

    private func resetQueryCaches() {
        resetRecentCache()
        fuzzySortedMatchesCache = nil
    }

    private func resetFullIndex() {
        fullIndexBuildTask?.cancel()
        fullIndexBuildTask = nil
        fullIndexBuildGeneration &+= 1
        fullIndexPendingEvents = []
        fullIndex = nil
        fullIndexStale = true
        markIndexChanged()
    }

    private func resetShortQueryIndex() {
        shortQueryIndexBuildTask?.cancel()
        shortQueryIndexBuildTask = nil
        shortQueryIndexBuildGeneration &+= 1
        shortQueryIndex = nil
        shortQueryIndexPendingUpserts = []
        shortQueryIndexPendingDeletions = []
    }

    private func handleShortQueryIndexUpsert(_ item: ClipboardStoredItem) {
        if shortQueryIndexBuildTask != nil {
            shortQueryIndexPendingUpserts.append(item)
            return
        }

        guard var index = shortQueryIndex else { return }
        index.upsert(item)
        if shouldRebuildShortQueryIndexDueToTombstones(index: index) {
            let liveCount = index.healthStats().live
            resetShortQueryIndex()
            if liveCount >= shortQueryCacheSize {
                startShortQueryIndexBuildIfNeeded()
            }
        } else {
            shortQueryIndex = index
        }
    }

    private func shouldRebuildShortQueryIndexDueToTombstones(index: ShortQueryIndex) -> Bool {
        let stats = index.healthStats()
        guard stats.slots >= shortQueryIndexTombstoneMinSlotsForRebuild else { return false }
        guard stats.tombstones >= shortQueryIndexTombstoneMinCountForRebuild else { return false }

        let ratio = Double(stats.tombstones) / Double(stats.slots)
        return ratio >= shortQueryIndexTombstoneRatioRebuildThreshold
    }

    private func handleShortQueryIndexDeletion(id: UUID) {
        if shortQueryIndexBuildTask != nil {
            shortQueryIndexPendingDeletions.append(id)
            return
        }

        guard var index = shortQueryIndex else { return }
        index.markDeleted(id: id)
        if shouldRebuildShortQueryIndexDueToTombstones(index: index) {
            let liveCount = index.healthStats().live
            resetShortQueryIndex()
            if liveCount >= shortQueryCacheSize {
                startShortQueryIndexBuildIfNeeded()
            }
        } else {
            shortQueryIndex = index
        }
    }

    private func startShortQueryIndexBuildIfNeeded(force: Bool = false) {
        guard shortQueryIndex == nil else { return }
        guard shortQueryIndexBuildTask == nil else { return }

        let estimatedCount = corpusMetrics?.itemCount ?? 0
        guard force || estimatedCount >= shortQueryCacheSize else { return }

        shortQueryIndexPendingUpserts = []
        shortQueryIndexPendingDeletions = []

        shortQueryIndexBuildGeneration &+= 1
        let generation = shortQueryIndexBuildGeneration
        let reserveSlots = estimatedCount

        shortQueryIndexBuildTask = Task.detached(priority: .utility) { [dbPath] in
            let snapshot = Self.loadShortQueryIndexSnapshotFromDiskCache(dbPath: dbPath)
                ?? Self.buildShortQueryIndexSnapshot(dbPath: dbPath, reserveSlots: reserveSlots)
            await self.finishShortQueryIndexBuild(generation: generation, snapshot: snapshot)
        }
    }

    private func shortQueryIndexWaitTimeout(tokenLower: String) -> TimeInterval {
        guard let metrics = corpusMetrics else { return 0 }
        guard metrics.isHeavyPlainTextCorpus else { return 0 }
        if tokenLower.canBeConverted(to: .ascii) {
            return 0.005
        }
        return 0.01
    }

    private func waitForShortQueryIndexBuild(task: Task<Void, Never>, timeout: TimeInterval) async throws {
        do {
            try await withTimeout(timeout: timeout) { await task.value }
        } catch {
            if case SearchError.timeout = error { return }
            throw error
        }
    }

    private func startFullIndexBuildIfNeeded(force: Bool = false) {
        guard fullIndexBuildTask == nil else { return }
        guard fullIndex == nil || fullIndexStale else { return }

        let estimatedCount = corpusMetrics?.itemCount ?? 0
        if !force {
            // Small corpora build quickly on demand; skip background warm-up to avoid extra work/memory.
            guard estimatedCount >= shortQueryCacheSize else { return }
        }

        fullIndexPendingEvents = []
        let startedMutationCounter = observedMutationCounter
        let startedDBChangeToken = knownDBChangeToken ?? (try? fetchDBChangeToken()) ?? 0

        fullIndexBuildGeneration &+= 1
        let generation = fullIndexBuildGeneration
        let reserveSlots = estimatedCount

        fullIndexBuildTask = Task.detached(priority: .utility) { [dbPath, startedMutationCounter, startedDBChangeToken] in
            let snapshot = Self.loadFullIndexSnapshotFromDiskCache(dbPath: dbPath)
                ?? Self.buildFullIndexSnapshot(dbPath: dbPath, reserveSlots: reserveSlots)
            await self.finishFullIndexBuild(
                generation: generation,
                startedMutationCounter: startedMutationCounter,
                startedDBChangeToken: startedDBChangeToken,
                snapshot: snapshot
            )
        }
    }

    private static func buildShortQueryIndexSnapshot(dbPath: String, reserveSlots: Int) -> ShortQueryIndexSnapshot? {
        let flags = SQLiteConnection.openFlags(for: dbPath, readOnly: true)
        let conn: SQLiteConnection
        do {
            conn = try SQLiteConnection(path: dbPath, flags: flags)
        } catch {
            return nil
        }
        defer { conn.close() }

        do {
            try conn.execute("PRAGMA query_only = 1")
            try conn.execute("PRAGMA busy_timeout = 500")
            try conn.execute("PRAGMA cache_size = -64000")
            try conn.execute("PRAGMA temp_store = MEMORY")
            try conn.execute("PRAGMA mmap_size = 268435456")
        } catch {
            return nil
        }

        var index = ShortQueryIndex(reserveSlots: reserveSlots)

        do {
            let stmt = try conn.prepare("SELECT id, type, content_hash, plain_text, note FROM clipboard_items")
            var row = 0
            while try stmt.step() {
                if row % 256 == 0, Task.isCancelled { return nil }
                row += 1

                guard let idString = stmt.columnText(0),
                      let id = UUID(uuidString: idString),
                      let typeRaw = stmt.columnText(1),
                      let type = ClipboardItemType(rawValue: typeRaw) else {
                    continue
                }

                let contentHash = stmt.columnText(2) ?? ""
                let plainText = stmt.columnText(3) ?? ""
                let note = stmt.columnText(4)

                index.upsert(id: id, type: type, contentHash: contentHash, plainText: plainText, note: note)
            }
        } catch {
            return nil
        }

        guard !Task.isCancelled else { return nil }
        return ShortQueryIndexSnapshot(index: index, source: .database)
    }

    private static func buildFullIndexSnapshot(dbPath: String, reserveSlots: Int) -> FullIndexSnapshot? {
        let flags = SQLiteConnection.openFlags(for: dbPath, readOnly: true)
        let conn: SQLiteConnection
        do {
            conn = try SQLiteConnection(path: dbPath, flags: flags)
        } catch {
            return nil
        }
        defer { conn.close() }

        do {
            try conn.execute("PRAGMA query_only = 1")
            try conn.execute("PRAGMA busy_timeout = 500")
            try conn.execute("PRAGMA cache_size = -64000")
            try conn.execute("PRAGMA temp_store = MEMORY")
            try conn.execute("PRAGMA mmap_size = 268435456")
        } catch {
            return nil
        }

        func readDataVersion() -> Int64? {
            do {
                let stmt = try conn.prepare("PRAGMA data_version")
                defer { stmt.reset() }
                guard try stmt.step() else { return nil }
                return stmt.columnInt64(0)
            } catch {
                return nil
            }
        }

        guard let startDataVersion = readDataVersion() else { return nil }

        var items: [IndexedItem?] = []
        if reserveSlots > 0 {
            items.reserveCapacity(reserveSlots)
        }

        var idToSlot: [UUID: Int] = [:]
        if reserveSlots > 0 {
            idToSlot.reserveCapacity(reserveSlots)
        }

        var asciiCharPostings: [[Int]] = Array(repeating: [], count: 128)
        var nonASCIICharPostings: [Character: [Int]] = [:]
        var seenASCII = Array(repeating: false, count: 128)
        var seenNonASCII = Set<Character>()
        seenNonASCII.reserveCapacity(16)

        do {
            let sql = """
                SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                       use_count, is_pinned, size_bytes, storage_ref, file_size_bytes
                FROM clipboard_items
            """
            let stmt = try conn.prepare(sql)
            defer { stmt.reset() }

            var row = 0
            while try stmt.step() {
                if row % 512 == 0, Task.isCancelled { return nil }
                row += 1

                guard let idString = stmt.columnText(0),
                      let id = UUID(uuidString: idString),
                      let typeString = stmt.columnText(1),
                      let type = ClipboardItemType(rawValue: typeString),
                      let contentHash = stmt.columnText(2) else {
                    continue
                }

                let plainText = stmt.columnText(3) ?? ""
                let note = stmt.columnText(4)
                let appBundleID = stmt.columnText(5)
                let createdAt = Date(timeIntervalSince1970: stmt.columnDouble(6))
                let lastUsedAt = Date(timeIntervalSince1970: stmt.columnDouble(7))
                let useCount = stmt.columnInt(8)
                let isPinned = stmt.columnInt(9) != 0
                let sizeBytes = stmt.columnInt(10)
                let storageRef = stmt.columnText(11)
                let fileSizeBytes = stmt.columnIntOptional(12)

                let stored = ClipboardStoredItem(
                    id: id,
                    type: type,
                    contentHash: contentHash,
                    plainText: plainText,
                    note: note,
                    appBundleID: appBundleID,
                    createdAt: createdAt,
                    lastUsedAt: lastUsedAt,
                    useCount: useCount,
                    isPinned: isPinned,
                    sizeBytes: sizeBytes,
                    fileSizeBytes: fileSizeBytes,
                    storageRef: storageRef,
                    rawData: nil
                )

                let indexed = IndexedItem(from: stored)
                let slot = items.count
                items.append(indexed)
                idToSlot[indexed.id] = slot

                appendSlotToCharPostings(
                    text: indexed.plainTextLower,
                    slot: slot,
                    asciiCharPostings: &asciiCharPostings,
                    nonASCIICharPostings: &nonASCIICharPostings,
                    seenASCII: &seenASCII,
                    seenNonASCII: &seenNonASCII
                )
            }
        } catch {
            return nil
        }

        guard let endDataVersion = readDataVersion() else { return nil }
        guard !Task.isCancelled else { return nil }

        let index = FullFuzzyIndex(
            items: items,
            idToSlot: idToSlot,
            asciiCharPostings: asciiCharPostings,
            nonASCIICharPostings: nonASCIICharPostings,
            tombstoneCount: 0
        )
        return FullIndexSnapshot(
            index: index,
            startDataVersion: startDataVersion,
            endDataVersion: endDataVersion,
            source: .database
        )
    }

    private static func fullIndexDiskCachePath(dbPath: String) -> String {
        "\(dbPath).fullindex.v\(fullIndexDiskCacheVersion).plist"
    }

    private static func fullIndexDiskCacheChecksumPath(dbPath: String) -> String {
        fullIndexDiskCachePath(dbPath: dbPath) + ".sha256"
    }

    private static func shortQueryIndexDiskCachePath(dbPath: String) -> String {
        "\(dbPath).shortindex.v\(shortQueryIndexDiskCacheVersion).plist"
    }

    private static func shortQueryIndexDiskCacheChecksumPath(dbPath: String) -> String {
        shortQueryIndexDiskCachePath(dbPath: dbPath) + ".sha256"
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
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
    ) -> (
        dbSize: UInt64,
        dbModifiedAt: TimeInterval,
        walSize: UInt64,
        walModifiedAt: TimeInterval,
        shmSize: UInt64,
        shmModifiedAt: TimeInterval
    )? {
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

            return (
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

    private static func loadShortQueryIndexSnapshotFromDiskCache(dbPath: String) -> ShortQueryIndexSnapshot? {
        guard let fp = dbFileFingerprint(dbPath: dbPath) else { return nil }
        let cachePath = shortQueryIndexDiskCachePath(dbPath: dbPath)
        guard FileManager.default.fileExists(atPath: cachePath) else { return nil }

        let checksumPath = shortQueryIndexDiskCacheChecksumPath(dbPath: dbPath)
        guard let checksumRaw = try? String(contentsOfFile: checksumPath, encoding: .utf8) else { return nil }
        let checksum = checksumRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard checksum.count == 64 else { return nil }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath), options: [.mappedIfSafe]) else {
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

        guard let index = ShortQueryIndex(diskCache: cache) else { return nil }
        return ShortQueryIndexSnapshot(index: index, source: .diskCache)
    }

    private static func loadFullIndexSnapshotFromDiskCache(dbPath: String) -> FullIndexSnapshot? {
        #if DEBUG
        let loadStart = CFAbsoluteTimeGetCurrent()
        #endif

        guard let fp = dbFileFingerprint(dbPath: dbPath) else { return nil }

        let cachePath = fullIndexDiskCachePath(dbPath: dbPath)
        guard FileManager.default.fileExists(atPath: cachePath) else { return nil }

        let checksumPath = fullIndexDiskCacheChecksumPath(dbPath: dbPath)
        guard let checksumRaw = try? String(contentsOfFile: checksumPath, encoding: .utf8) else { return nil }
        let checksum = checksumRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard checksum.count == 64 else { return nil }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath), options: [.mappedIfSafe]) else {
            return nil
        }

        #if DEBUG
        let checksumStart = CFAbsoluteTimeGetCurrent()
        #endif
        let computedChecksum = sha256Hex(data)
        #if DEBUG
        let checksumMs = (CFAbsoluteTimeGetCurrent() - checksumStart) * 1000
        #endif
        guard computedChecksum == checksum else { return nil }

        #if DEBUG
        let decodeStart = CFAbsoluteTimeGetCurrent()
        #endif
        let decoder = PropertyListDecoder()
        guard let cache = try? decoder.decode(FullIndexDiskCacheV3.self, from: data) else { return nil }
        #if DEBUG
        let decodeMs = (CFAbsoluteTimeGetCurrent() - decodeStart) * 1000
        #endif
        guard cache.version == fullIndexDiskCacheVersion else { return nil }
        guard cache.dbFileSize == fp.dbSize, cache.dbFileModifiedAt == fp.dbModifiedAt else { return nil }
        guard cache.walFileSize == fp.walSize, cache.walFileModifiedAt == fp.walModifiedAt else { return nil }
        guard cache.shmFileSize == fp.shmSize, cache.shmFileModifiedAt == fp.shmModifiedAt else { return nil }
        guard cache.asciiCharPostings.count == 128 else { return nil }

        // We rely on the .sha256 sidecar to protect against truncated/corrupted cache files.
        // Keep the remaining validation lightweight to preserve fast startup loads.
        let itemsCount = cache.items.count
        for postings in cache.asciiCharPostings {
            if !validateDiskCachePostings(postings, itemsCount: itemsCount) { return nil }
        }
        for postings in cache.nonASCIICharPostings.values {
            if !validateDiskCachePostings(postings, itemsCount: itemsCount) { return nil }
        }

        guard let index = fullIndexFromDiskCache(cache) else { return nil }
        #if DEBUG
        let totalMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
        ScopyLog.search.debug(
            "Loaded fullIndex disk cache: bytes=\(data.count, privacy: .public) checksumMs=\(checksumMs, privacy: .public) decodeMs=\(decodeMs, privacy: .public) totalMs=\(totalMs, privacy: .public)"
        )
        #endif
        return FullIndexSnapshot(index: index, startDataVersion: 0, endDataVersion: 0, source: .diskCache)
    }

    private static func loadFullIndexFromDiskCache(dbPath: String) -> FullFuzzyIndex? {
        let snapshot = loadFullIndexSnapshotFromDiskCache(dbPath: dbPath)
        return snapshot?.index
    }

    private static func fullIndexFromDiskCache(_ cache: FullIndexDiskCacheV3) -> FullFuzzyIndex? {
        var items: [IndexedItem?] = []
        items.reserveCapacity(cache.items.count)

        var idToSlot: [UUID: Int] = [:]
        idToSlot.reserveCapacity(cache.items.count)

        for (slot, diskItem) in cache.items.enumerated() {
            guard let diskItem,
                  let id = UUID(uuidString: diskItem.id),
                  let type = ClipboardItemType(rawValue: diskItem.type) else {
                items.append(nil)
                continue
            }

            let item = IndexedItem(
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
            items.append(item)
            idToSlot[id] = slot
        }

        var nonASCIICharPostings: [Character: [Int]] = [:]
        nonASCIICharPostings.reserveCapacity(cache.nonASCIICharPostings.count)
        for (rawKey, postings) in cache.nonASCIICharPostings {
            guard rawKey.count == 1, let ch = rawKey.first else { continue }
            nonASCIICharPostings[ch] = postings
        }

        let tombstones = max(0, items.count - idToSlot.count)
        return FullFuzzyIndex(
            items: items,
            idToSlot: idToSlot,
            asciiCharPostings: cache.asciiCharPostings,
            nonASCIICharPostings: nonASCIICharPostings,
            tombstoneCount: tombstones
        )
    }

    private func scheduleShortQueryIndexDiskCachePersistIfPossible() {
        guard shortQueryIndexDiskCachePersistTask == nil else { return }
        invalidateInMemoryIndexesIfDBChangedExternally()
        guard let index = shortQueryIndex else { return }
        guard index.asciiCharPostingsCount == 128 else { return }
        guard let fp = Self.dbFileFingerprint(dbPath: dbPath) else { return }

        let cache = index.toDiskCache(
            version: Self.shortQueryIndexDiskCacheVersion,
            fp: fp
        )

        let cachePath = Self.shortQueryIndexDiskCachePath(dbPath: dbPath)
        let checksumPath = Self.shortQueryIndexDiskCacheChecksumPath(dbPath: dbPath)
        shortQueryIndexDiskCachePersistTask = Task.detached(priority: .utility) { [cache] in
            do {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let data = try encoder.encode(cache)
                try data.write(to: URL(fileURLWithPath: cachePath), options: [.atomic])
                let checksum = Self.sha256Hex(data)
                try checksum.write(to: URL(fileURLWithPath: checksumPath), atomically: true, encoding: .utf8)
            } catch {
                // Best-effort cache: ignore failures.
            }
            await self.finishShortQueryIndexDiskCachePersist()
        }
    }

    private func finishShortQueryIndexDiskCachePersist() {
        shortQueryIndexDiskCachePersistTask = nil
    }

    private func scheduleFullIndexDiskCachePersistIfPossible() {
        guard fullIndexDiskCachePersistTask == nil else { return }
        invalidateInMemoryIndexesIfDBChangedExternally()
        guard let index = fullIndex, !fullIndexStale else { return }
        guard index.asciiCharPostings.count == 128 else { return }
        guard let fp = Self.dbFileFingerprint(dbPath: dbPath) else { return }

        var nonASCII: [String: [Int]] = [:]
        nonASCII.reserveCapacity(index.nonASCIICharPostings.count)
        for (ch, postings) in index.nonASCIICharPostings {
            nonASCII[String(ch)] = postings
        }

        let cache = FullIndexDiskCacheV3(
            version: Self.fullIndexDiskCacheVersion,
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

        let cachePath = Self.fullIndexDiskCachePath(dbPath: dbPath)
        let checksumPath = Self.fullIndexDiskCacheChecksumPath(dbPath: dbPath)
        fullIndexDiskCachePersistTask = Task.detached(priority: .utility) { [cache] in
            do {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let data = try encoder.encode(cache)
                try data.write(to: URL(fileURLWithPath: cachePath), options: [.atomic])
                let checksum = Self.sha256Hex(data)
                try checksum.write(to: URL(fileURLWithPath: checksumPath), atomically: true, encoding: .utf8)
            } catch {
                // Best-effort cache: ignore failures.
            }
            await self.finishFullIndexDiskCachePersist()
        }
    }

    private func finishFullIndexDiskCachePersist() {
        fullIndexDiskCachePersistTask = nil
    }

    private func finishShortQueryIndexBuild(generation: UInt64, snapshot: ShortQueryIndexSnapshot?) {
        guard shortQueryIndexBuildGeneration == generation else { return }
        shortQueryIndexBuildTask = nil

        let pendingDeletions = shortQueryIndexPendingDeletions
        let pendingUpserts = shortQueryIndexPendingUpserts
        shortQueryIndexPendingUpserts = []
        shortQueryIndexPendingDeletions = []

        guard let snapshot else { return }
        var index = snapshot.index

        for id in pendingDeletions {
            index.markDeleted(id: id)
        }

        for item in pendingUpserts {
            index.upsert(item)
        }

        shortQueryIndex = index

#if DEBUG
        debugShortQueryIndexLastSnapshotSourceValue = snapshot.source
#endif

        if snapshot.source == .database {
            scheduleShortQueryIndexDiskCachePersistIfPossible()
        }
    }

    private func finishFullIndexBuild(
        generation: UInt64,
        startedMutationCounter: UInt64,
        startedDBChangeToken: Int64,
        snapshot: FullIndexSnapshot?
    ) {
        guard fullIndexBuildGeneration == generation else { return }
        fullIndexBuildTask = nil

        let pending = fullIndexPendingEvents
        fullIndexPendingEvents = []

        guard let snapshot else { return }
        if usesMutationSeq,
           snapshot.source == .database,
           let currentToken = try? fetchDBChangeToken() {
            let observedDelta = Int64(observedMutationCounter &- startedMutationCounter)
            let expectedToken = startedDBChangeToken &+ observedDelta
            if currentToken != expectedToken {
                // The DB changed during background build, but those commits weren't fully observed via our callbacks
                // (e.g. cleanup transactions, another app instance, or a missed notification). Drop in-memory
                // indexes/caches to guarantee full-history correctness.
                resetQueryCaches()
                resetFullIndex()
                resetShortQueryIndex()
                markCorpusMetricsStale()
                knownDBChangeToken = currentToken
                startShortQueryIndexBuildIfNeeded()
                return
            }
        }

        var index = snapshot.index

#if DEBUG
        debugFullIndexLastSnapshotSourceValue = snapshot.source
#endif

        // Apply changes observed while building in the background.
        for event in pending {
            switch event {
            case .upsert(let item):
                upsertItemIntoIndex(item, index: &index)
            case .delete(let id):
                if let slot = index.idToSlot[id],
                   slot < index.items.count {
                    if index.items[slot] != nil {
                        index.items[slot] = nil
                        index.tombstoneCount += 1
                    }
                    index.idToSlot.removeValue(forKey: id)
                }
            case .pin(let id, let pinned):
                if let slot = index.idToSlot[id],
                   slot < index.items.count,
                   let existing = index.items[slot] {
                    var updated = existing
                    updated.isPinned = pinned
                    index.items[slot] = updated
                }
            }
        }

        fullIndex = index
        fullIndexStale = shouldMarkFullIndexStaleDueToTombstones(index: index)

        markIndexChanged()

        if fullIndexStale {
            startFullIndexBuildIfNeeded(force: true)
        } else if snapshot.source == .database {
            scheduleFullIndexDiskCachePersistIfPossible()
        }
    }

    private func fetchDataVersion() throws -> Int64 {
        let stmt = try prepare("PRAGMA data_version")
        defer { stmt.reset() }
        guard try stmt.step() else { return 0 }
        return stmt.columnInt64(0)
    }

    private func fetchMutationSeq() throws -> Int64 {
        let stmt = try prepare("SELECT mutation_seq FROM scopy_meta WHERE id = 1")
        defer { stmt.reset() }
        guard try stmt.step() else { return 0 }
        return stmt.columnInt64(0)
    }

    private func fetchDBChangeToken() throws -> Int64 {
        if usesMutationSeq {
            return try fetchMutationSeq()
        }
        return try fetchDataVersion()
    }

    private func refreshKnownDBChangeTokenIfPossible() {
        guard connection != nil else { return }
        if let v = try? fetchDBChangeToken() {
            knownDBChangeToken = v
        }
    }

    @discardableResult
    private func invalidateInMemoryIndexesIfDBChangedExternallyBeforeApplyingInternalMutationIfNeeded() -> Bool {
        guard connection != nil else { return false }
        guard let known = knownDBChangeToken else {
            refreshKnownDBChangeTokenIfPossible()
            return false
        }
        guard let current = try? fetchDBChangeToken() else { return false }
        guard current != known else { return false }

        if usesMutationSeq {
            // Our update callbacks are invoked per storage commit, and `mutation_seq` is incremented
            // exactly once per commit. Therefore delta == 1 is the expected case.
            if current == known + 1 {
                knownDBChangeToken = current
                return false
            }
        } else {
            // Fallback: best-effort with `PRAGMA data_version`. We cannot rely on it being a strict
            // per-commit counter across all SQLite builds/modes, but delta == 1 is still the expected
            // case for our own storage commits.
            if current == known + 1 {
                knownDBChangeToken = current
                return false
            }
        }

        resetQueryCaches()
        resetFullIndex()
        resetShortQueryIndex()
        markCorpusMetricsStale()
        knownDBChangeToken = current
        startShortQueryIndexBuildIfNeeded()
        return true
    }

    private func invalidateInMemoryIndexesIfDBChangedExternally() {
        guard connection != nil else { return }
        guard let known = knownDBChangeToken else {
            refreshKnownDBChangeTokenIfPossible()
            return
        }
        guard let current = try? fetchDBChangeToken() else { return }
        guard current != known else { return }

        // DB has changed but we haven't observed it through our update callbacks yet.
        // To guarantee "full history" correctness, drop in-memory indexes/caches and fall back to SQL scans.
        resetQueryCaches()
        resetFullIndex()
        resetShortQueryIndex()
        markCorpusMetricsStale()
        knownDBChangeToken = current
        startShortQueryIndexBuildIfNeeded()
    }

    // MARK: - Search API

    public func search(request: SearchRequest) async throws -> SearchResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let perfContext = Perf.metricsEnabled ? PerfContext() : nil
        let signpostID = Perf.signpostsEnabled ? OSSignpostID(log: Perf.log) : nil

        if let signpostID {
            os_signpost(
                .begin,
                log: Perf.log,
                name: "Search",
                signpostID: signpostID,
                "mode=%{public}@ sort=%{public}@ forceFullFuzzy=%{public}d queryLen=%{public}d",
                request.mode.rawValue,
                request.sortMode.rawValue,
                request.forceFullFuzzy ? 1 : 0,
                request.query.count
            )
        }
        defer {
            if let signpostID {
                os_signpost(.end, log: Perf.log, name: "Search", signpostID: signpostID)
            }
        }

        let timeout: TimeInterval
        switch request.mode {
        case .fuzzy, .fuzzyPlus:
            timeout = (fullIndex == nil || fullIndexStale) ? initialIndexBuildTimeout : searchTimeout
        case .exact, .regex:
            timeout = searchTimeout
        }

        try openIfNeeded()
        let interruptHandle = connection?.handle.map { SQLiteInterruptHandle(handle: $0) }

        let result: SearchResult
        do {
            result = try await withTaskCancellationHandler(operation: {
                try await withTimeout(timeout: timeout) {
                    try await self.searchInternal(request: request, perf: perfContext)
                }
            }, onCancel: {
                if let interruptHandle {
                    sqlite3_interrupt(interruptHandle.handle)
                }
            })
        } catch {
            if case SearchError.timeout = error, let interruptHandle {
                sqlite3_interrupt(interruptHandle.handle)
            }
            throw error
        }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        perfContext?.addPhase("search_total", ms: elapsedMs)
        perfContext?.addCounter("returned_items", value: result.items.count)
        return SearchResult(
            items: result.items,
            total: result.total,
            hasMore: result.hasMore,
            isPrefilter: result.isPrefilter,
            searchTimeMs: elapsedMs,
            perf: perfContext?.snapshot()
        )
    }

    // MARK: - Search Internals

    private func searchInternal(request: SearchRequest, perf: PerfContext?) async throws -> SearchResult {
        try openIfNeeded()
        if let perf {
            perf.measure("refresh_corpus_metrics") { refreshCorpusMetricsIfNeeded() }
        } else {
            refreshCorpusMetricsIfNeeded()
        }

        if let perf {
            perf.measure("invalidate_external_db_change") { invalidateInMemoryIndexesIfDBChangedExternally() }
        } else {
            invalidateInMemoryIndexesIfDBChangedExternally()
        }
        try Task.checkCancellation()

        switch request.mode {
        case .exact:
            return try await searchExact(request: request)
        case .fuzzy:
            return try await searchFuzzy(request: request, perf: perf)
        case .fuzzyPlus:
            return try await searchFuzzyPlus(request: request, perf: perf)
        case .regex:
            return try await searchRegex(request: request)
        }
    }

    private func searchExact(request: SearchRequest) async throws -> SearchResult {
        if request.query.isEmpty {
            return try searchAllWithFilters(request: request)
        }

        if request.query.count <= 2 {
            return try searchInCache(request: request) { item in
                item.plainText.localizedCaseInsensitiveContains(request.query)
            }
        }

        let trimmedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ftsQuery = FTSQueryBuilder.build(userQuery: trimmedQuery) else {
            return try searchAllWithFilters(request: request)
        }

        let fts = try searchWithFTS(query: ftsQuery, request: request, isPrefilter: false)
        if fts.items.isEmpty,
           !trimmedQuery.isEmpty,
           !trimmedQuery.canBeConverted(to: .ascii) {
            let tokens = substringSearchTokens(trimmedQuery)
            let typeFilters = request.typeFilters.map(Array.init)
            if let page = try? searchWithSubstring(
                tokens: tokens,
                sortMode: request.sortMode,
                appFilter: request.appFilter,
                typeFilter: request.typeFilter,
                typeFilters: typeFilters,
                limit: request.limit,
                offset: request.offset
            ), !page.items.isEmpty {
                return SearchResult(items: page.items, total: page.total, hasMore: page.hasMore, isPrefilter: false, searchTimeMs: 0)
            }
        }

        return fts
    }

    private func searchFuzzy(request: SearchRequest, perf: PerfContext?) async throws -> SearchResult {
        if request.query.isEmpty {
            return try searchAllWithFilters(request: request)
        }
        return try await searchFullFuzzy(request: request, mode: .fuzzy, perf: perf)
    }

    private func searchFuzzyPlus(request: SearchRequest, perf: PerfContext?) async throws -> SearchResult {
        if request.query.isEmpty {
            return try searchAllWithFilters(request: request)
        }
        return try await searchFullFuzzy(request: request, mode: .fuzzyPlus, perf: perf)
    }

    private func searchRegex(request: SearchRequest) async throws -> SearchResult {
        guard let regex = try? NSRegularExpression(pattern: request.query, options: [.caseInsensitive]) else {
            throw SearchError.invalidQuery("Invalid regex pattern")
        }

        return try searchInCache(request: request) { item in
            let range = NSRange(item.plainText.startIndex..., in: item.plainText)
            return regex.firstMatch(in: item.plainText, range: range) != nil
        }
    }

    // MARK: - FTS

    private func searchWithFTS(
        query: String,
        request: SearchRequest,
        isPrefilter: Bool
    ) throws -> SearchResult {
        let typeFilters = request.typeFilters.map(Array.init)
        let page = try searchWithFTS(
            ftsQuery: query,
            sortMode: request.sortMode,
            appFilter: request.appFilter,
            typeFilter: request.typeFilter,
            typeFilters: typeFilters,
            limit: request.limit,
            offset: request.offset
        )
        return SearchResult(items: page.items, total: page.total, hasMore: page.hasMore, isPrefilter: isPrefilter, searchTimeMs: 0)
    }

    private func substringSearchTokens(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        let normalized = trimmed
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "-", with: " ")

        return normalized
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func fuzzyPlusTokens(_ queryLower: String) -> [String] {
        let trimmed = queryLower.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        return trimmed
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func buildTrigramFTSQuery(tokens: [String]) -> String? {
        let tokens = tokens.filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        func quotePhrase(_ raw: String) -> String {
            let escaped = raw.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }

        if tokens.count == 1 {
            return quotePhrase(tokens[0])
        }
        return tokens.map(quotePhrase).joined(separator: " AND ")
    }

    private func shouldUseTrigramFTS(tokens: [String]) -> Bool {
        guard supportsTrigramFTS else { return false }
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { $0.count >= 3 }
    }

    private func shouldUseSubstringOnlyFallbackForFuzzyPlus(tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { token in
            token.count >= 3 && token.canBeConverted(to: .ascii)
        }
    }

    // MARK: - Cache Search

    private func searchInCache(
        request: SearchRequest,
        filter: @escaping (ClipboardStoredItem) -> Bool
    ) throws -> SearchResult {
        try refreshCacheIfNeeded()

        var filtered: [ClipboardStoredItem] = []
        filtered.reserveCapacity(min(recentItemsCache.count, request.limit + 1))

        for cached in recentItemsCache {
            let item = cached.item
            if !filter(item) { continue }

            if let appFilter = request.appFilter, item.appBundleID != appFilter { continue }
            if let typeFilters = request.typeFilters, !typeFilters.isEmpty {
                if !typeFilters.contains(item.type) { continue }
            } else if let typeFilter = request.typeFilter {
                if item.type != typeFilter { continue }
            }

            filtered.append(item)
        }

        let totalFiltered = filtered.count
        let start = min(request.offset, totalFiltered)
        let end = min(request.offset + request.limit + 1, totalFiltered)

        var items: [ClipboardStoredItem] = (start < end) ? Array(filtered[start..<end]) : []

        let hasMore = items.count > request.limit
        if hasMore {
            items = Array(items.prefix(request.limit))
        }

        let total = hasMore ? -1 : request.offset + items.count
        return SearchResult(items: items, total: total, hasMore: hasMore, isPrefilter: true, searchTimeMs: 0)
    }

    private func refreshCacheIfNeeded() throws {
        let now = Date()
        let needsRefresh = recentItemsCache.isEmpty || now.timeIntervalSince(cacheTimestamp) > cacheDuration
        guard needsRefresh else { return }

        let items = try fetchRecentSummaries(limit: shortQueryCacheSize, offset: 0)
        recentItemsCache = items.map { item in
            let combined: String = {
                if let note = item.note, !note.isEmpty {
                    return item.plainText + "\n" + note
                }
                return item.plainText
            }()
            return CachedRecentItem(item: item, combinedLower: combined.lowercased())
        }
        cacheTimestamp = now
    }

    // MARK: - Full-History Fuzzy Search

    private func searchFullFuzzy(request: SearchRequest, mode: SearchMode, perf: PerfContext?) async throws -> SearchResult {
        let trimmedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return try searchAllWithFilters(request: request)
        }

        // If fuzzyPlus query consists of long ASCII tokens (>= 3), the match semantics are substring-only.
        // For the "full scan" stage, use SQL substring search directly to avoid expensive full-history scoring.
        if request.forceFullFuzzy,
           mode == .fuzzyPlus {
            let tokens = fuzzyPlusTokens(trimmedQuery.lowercased())
            if shouldUseSubstringOnlyFallbackForFuzzyPlus(tokens: tokens) {
                let typeFilters = request.typeFilters.map(Array.init)
                let page = try searchWithSubstringLike(
                    tokens: tokens,
                    sortMode: request.sortMode,
                    appFilter: request.appFilter,
                    typeFilter: request.typeFilter,
                    typeFilters: typeFilters,
                    limit: request.limit,
                    offset: request.offset
                )
                return SearchResult(items: page.items, total: page.total, hasMore: page.hasMore, isPrefilter: false, searchTimeMs: 0)
            }
        }

        if !request.forceFullFuzzy,
           trimmedQuery.count >= 3,
           shouldPreferFTSForFuzzy(query: trimmedQuery),
           let ftsQuery = FTSQueryBuilder.build(userQuery: trimmedQuery)
        {
            // Fast-path for long-text corpora: return quick prefilter results first, then let UI refine
            // with `forceFullFuzzy=true` to run a full-history scan (progressive search UX).
            let fts: SearchResult
            if let perf {
                fts = try perf.measure("fts_prefilter") {
                    try searchWithFTS(query: ftsQuery, request: request, isPrefilter: true)
                }
            } else {
                fts = try searchWithFTS(query: ftsQuery, request: request, isPrefilter: true)
            }
            if !fts.items.isEmpty {
                // Warm up the full index in the background so the first refine does not pay the cold build cost.
                startFullIndexBuildIfNeeded()
                perf?.addCounter("fts_prefilter_items", value: fts.items.count)
                return fts
            }

            // For fuzzyPlus, long ASCII tokens (>= 3) are required to match contiguously.
            // If FTS yields no matches, use a SQL substring-only fallback to avoid full-history scans,
            // especially for "no result" cases that would otherwise cost O(n * text_length).
            if mode == .fuzzyPlus {
                let tokens = fuzzyPlusTokens(trimmedQuery.lowercased())
                if shouldUseSubstringOnlyFallbackForFuzzyPlus(tokens: tokens) {
                    let typeFilters = request.typeFilters.map(Array.init)
                    let page: (items: [ClipboardStoredItem], total: Int, hasMore: Bool)
                    if let perf {
                        page = try perf.measure("sql_substring_only_fallback") {
                            try searchWithSubstringLike(
                                tokens: tokens,
                                sortMode: request.sortMode,
                                appFilter: request.appFilter,
                                typeFilter: request.typeFilter,
                                typeFilters: typeFilters,
                                limit: request.limit,
                                offset: request.offset
                            )
                        }
                    } else {
                        page = try searchWithSubstringLike(
                            tokens: tokens,
                            sortMode: request.sortMode,
                            appFilter: request.appFilter,
                            typeFilter: request.typeFilter,
                            typeFilters: typeFilters,
                            limit: request.limit,
                            offset: request.offset
                        )
                    }
                    return SearchResult(items: page.items, total: page.total, hasMore: page.hasMore, isPrefilter: false, searchTimeMs: 0)
                }
            }

            if !trimmedQuery.canBeConverted(to: .ascii) {
                let tokens = substringSearchTokens(trimmedQuery)
                let typeFilters = request.typeFilters.map(Array.init)
                let page: (items: [ClipboardStoredItem], total: Int, hasMore: Bool)?
                if let perf {
                    page = try? perf.measure("sql_substring_fallback_non_ascii") {
                        try searchWithSubstring(
                            tokens: tokens,
                            sortMode: request.sortMode,
                            appFilter: request.appFilter,
                            typeFilter: request.typeFilter,
                            typeFilters: typeFilters,
                            limit: request.limit,
                            offset: request.offset
                        )
                    }
                } else {
                    page = try? searchWithSubstring(
                        tokens: tokens,
                        sortMode: request.sortMode,
                        appFilter: request.appFilter,
                        typeFilter: request.typeFilter,
                        typeFilters: typeFilters,
                        limit: request.limit,
                        offset: request.offset
                    )
                }
                if let page, !page.items.isEmpty {
                    // Warm up the full index in the background so the first refine does not pay the cold build cost.
                    startFullIndexBuildIfNeeded()
                    perf?.addCounter("substring_fallback_items", value: page.items.count)
                    return SearchResult(items: page.items, total: page.total, hasMore: page.hasMore, isPrefilter: true, searchTimeMs: 0)
                }
            }

            if trimmedQuery.count <= 6 {
                let fallback = try searchFuzzyInRecentCache(request: request, mode: mode, query: trimmedQuery)
                if !fallback.items.isEmpty {
                    // Warm up the full index in the background so the first refine does not pay the cold build cost.
                    startFullIndexBuildIfNeeded()
                    return fallback
                }
            }

            // Keep the initial (non-forceFullFuzzy) stage fast: even if no prefilter match is found,
            // return an empty prefilter result quickly and allow UI to refine with a full scan.
            startFullIndexBuildIfNeeded()
            return SearchResult(items: [], total: 0, hasMore: false, isPrefilter: true, searchTimeMs: 0)
        }

        if trimmedQuery.count <= 2 {
            // Prefer the in-memory full index if it is already available; otherwise, fall back to a SQL substring scan.
            // This avoids the multi-second "first full scan" penalty on large DBs while keeping match/sort semantics stable.
            if let index = fullIndex, !fullIndexStale {
                perf?.addCounter("short_query_path_full_index", value: 1)
                let normalizedRequest = SearchRequest(
                    query: trimmedQuery,
                    mode: mode,
                    sortMode: request.sortMode,
                    appFilter: request.appFilter,
                    typeFilter: request.typeFilter,
                    typeFilters: request.typeFilters,
                    forceFullFuzzy: request.forceFullFuzzy,
                    limit: request.limit,
                    offset: request.offset
                )
                let result = try searchInFullIndex(index: index, request: normalizedRequest, mode: mode, perf: perf)
                return SearchResult(
                    items: result.items,
                    total: result.total,
                    hasMore: result.hasMore,
                    isPrefilter: result.isPrefilter,
                    searchTimeMs: 0
                )
            }

            let tokenLower = trimmedQuery.lowercased()
            let typeFilters = request.typeFilters.map(Array.init)

            startShortQueryIndexBuildIfNeeded()

            if shortQueryIndex == nil, let task = shortQueryIndexBuildTask {
                let waitTimeout = shortQueryIndexWaitTimeout(tokenLower: tokenLower)
                if waitTimeout > 0 {
                    if let perf {
                        try await perf.measureAsync("short_query_index_wait") {
                            try await waitForShortQueryIndexBuild(task: task, timeout: waitTimeout)
                        }
                    } else {
                        try await waitForShortQueryIndexBuild(task: task, timeout: waitTimeout)
                    }
                }
            }

            if var shortIndex = shortQueryIndex {
                if tokenLower.canBeConverted(to: .ascii) {
                    let candidates = shortIndex.candidateIDStrings(for: tokenLower)
                    shortQueryIndex = shortIndex
                    if candidates.isEmpty {
                        return SearchResult(items: [], total: 0, hasMore: false, isPrefilter: false, searchTimeMs: 0)
                    }

                    if let itemCount = corpusMetrics?.itemCount,
                       itemCount > 0,
                       candidates.count > 4096,
                       Double(candidates.count) / Double(itemCount) > 0.85
                    {
                        // Extremely broad short query: candidate filtering no longer helps and building a huge
                        // candidates payload may cost more than a direct SQL scan. Fall back to SQL scan below.
                    } else {
                        perf?.addCounter("short_query_path_short_index", value: 1)
                        perf?.addCounter("short_query_short_index_candidates", value: candidates.count)
                        let page: (items: [ClipboardStoredItem], total: Int, hasMore: Bool)
                        if let perf {
                            page = try perf.measure("short_query_short_index_fetch") {
                                try searchWithShortQuerySubstringCandidates(
                                    tokenLower: tokenLower,
                                    candidateIDStrings: candidates,
                                    sortMode: request.sortMode,
                                    appFilter: request.appFilter,
                                    typeFilter: request.typeFilter,
                                    typeFilters: typeFilters,
                                    limit: request.limit,
                                    offset: request.offset
                                )
                            }
                        } else {
                            page = try searchWithShortQuerySubstringCandidates(
                                tokenLower: tokenLower,
                                candidateIDStrings: candidates,
                                sortMode: request.sortMode,
                                appFilter: request.appFilter,
                                typeFilter: request.typeFilter,
                                typeFilters: typeFilters,
                                limit: request.limit,
                                offset: request.offset
                            )
                        }
                        return SearchResult(items: page.items, total: page.total, hasMore: page.hasMore, isPrefilter: false, searchTimeMs: 0)
                    }
                } else if let candidates = shortIndex.candidateIDStringsForNonASCIIBigram(tokenLower: tokenLower) {
                    shortQueryIndex = shortIndex
                    if candidates.isEmpty {
                        return SearchResult(items: [], total: 0, hasMore: false, isPrefilter: false, searchTimeMs: 0)
                    }

                    if let itemCount = corpusMetrics?.itemCount,
                       itemCount > 0,
                       candidates.count > 4096,
                       Double(candidates.count) / Double(itemCount) > 0.85
                    {
                        // Extremely broad short query: candidate filtering no longer helps. Fall back to SQL scan below.
                    } else {
                        perf?.addCounter("short_query_path_short_index", value: 1)
                        perf?.addCounter("short_query_short_index_candidates", value: candidates.count)
                        let page: (items: [ClipboardStoredItem], total: Int, hasMore: Bool)
                        if let perf {
                            page = try perf.measure("short_query_short_index_sql_fetch") {
                                try searchWithShortQuerySubstringCandidatesSQL(
                                    tokenLower: tokenLower,
                                    candidateIDStrings: candidates,
                                    sortMode: request.sortMode,
                                    appFilter: request.appFilter,
                                    typeFilter: request.typeFilter,
                                    typeFilters: typeFilters,
                                    limit: request.limit,
                                    offset: request.offset
                                )
                            }
                        } else {
                            page = try searchWithShortQuerySubstringCandidatesSQL(
                                tokenLower: tokenLower,
                                candidateIDStrings: candidates,
                                sortMode: request.sortMode,
                                appFilter: request.appFilter,
                                typeFilter: request.typeFilter,
                                typeFilters: typeFilters,
                                limit: request.limit,
                                offset: request.offset
                            )
                        }
                        return SearchResult(items: page.items, total: page.total, hasMore: page.hasMore, isPrefilter: false, searchTimeMs: 0)
                    }
                }
            }

            perf?.addCounter("short_query_path_sql_scan", value: 1)
            let page: (items: [ClipboardStoredItem], total: Int, hasMore: Bool)
            if let perf {
                page = try perf.measure("sql_short_query_scan") {
                    try searchWithShortQuerySubstring(
                        tokenLower: tokenLower,
                        sortMode: request.sortMode,
                        appFilter: request.appFilter,
                        typeFilter: request.typeFilter,
                        typeFilters: typeFilters,
                        limit: request.limit,
                        offset: request.offset
                    )
                }
            } else {
                page = try searchWithShortQuerySubstring(
                    tokenLower: tokenLower,
                    sortMode: request.sortMode,
                    appFilter: request.appFilter,
                    typeFilter: request.typeFilter,
                    typeFilters: typeFilters,
                    limit: request.limit,
                    offset: request.offset
                )
            }
            return SearchResult(items: page.items, total: page.total, hasMore: page.hasMore, isPrefilter: false, searchTimeMs: 0)
        }

        let normalizedRequest = SearchRequest(
            query: trimmedQuery,
            mode: mode,
            sortMode: request.sortMode,
            appFilter: request.appFilter,
            typeFilter: request.typeFilter,
            typeFilters: request.typeFilters,
            forceFullFuzzy: request.forceFullFuzzy,
            limit: request.limit,
            offset: request.offset
        )

        if let task = fullIndexBuildTask {
            if let perf {
                _ = await perf.measureAsync("full_index_build_wait") { await task.value }
            } else {
                await task.value
            }
        }

        let index = try getOrBuildFullIndex(perf: perf)
        let result = try searchInFullIndex(index: index, request: normalizedRequest, mode: mode, perf: perf)
        return SearchResult(
            items: result.items,
            total: result.total,
            hasMore: result.hasMore,
            isPrefilter: result.isPrefilter,
            searchTimeMs: 0
        )
    }

    private func getOrBuildFullIndex(perf: PerfContext?) throws -> FullFuzzyIndex {
        if let index = fullIndex, !fullIndexStale {
            perf?.addCounter("full_index_source_memory", value: 1)
            return index
        }

        let loaded: FullFuzzyIndex?
        if let perf {
            loaded = perf.measure("full_index_disk_cache_load") {
                Self.loadFullIndexFromDiskCache(dbPath: dbPath)
            }
        } else {
            loaded = Self.loadFullIndexFromDiskCache(dbPath: dbPath)
        }

        if let loaded {
            if shouldMarkFullIndexStaleDueToTombstones(index: loaded) {
                // A heavily tombstoned disk snapshot can significantly degrade candidate intersections.
                // Treat it as unusable and rebuild from DB to keep refine latency stable.
                fullIndexStale = true
            } else {
                fullIndex = loaded
                fullIndexStale = false
                markIndexChanged()
                perf?.addCounter("full_index_source_disk_cache", value: 1)
                perf?.addCounter("full_index_items", value: loaded.items.count)
#if DEBUG
                debugFullIndexLastSnapshotSourceValue = .diskCache
#endif
                return loaded
            }
        }

        let newIndex: FullFuzzyIndex
        if let perf {
            newIndex = try perf.measure("full_index_build_from_db") {
                try buildFullIndex(perf: perf)
            }
        } else {
            newIndex = try buildFullIndex(perf: nil)
        }
        fullIndex = newIndex
        fullIndexStale = false
        markIndexChanged()
        perf?.addCounter("full_index_source_database", value: 1)
        perf?.addCounter("full_index_items", value: newIndex.items.count)
#if DEBUG
        debugFullIndexLastSnapshotSourceValue = .database
#endif
        scheduleFullIndexDiskCachePersistIfPossible()
        return newIndex
    }

    private func buildFullIndex(perf: PerfContext?) throws -> FullFuzzyIndex {
        let estimatedCount = corpusMetrics?.itemCount ?? 0

        let sql = """
            SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref, file_size_bytes
            FROM clipboard_items
        """
        let stmt = try prepare(sql)
        defer { stmt.reset() }

        var items: [IndexedItem?] = []
        if estimatedCount > 0 {
            items.reserveCapacity(estimatedCount)
        }

        var idToSlot: [UUID: Int] = [:]
        if estimatedCount > 0 {
            idToSlot.reserveCapacity(estimatedCount)
        }

        var asciiCharPostings: [[Int]] = Array(repeating: [], count: 128)
        var nonASCIICharPostings: [Character: [Int]] = [:]
        var seenASCII = Array(repeating: false, count: 128)
        var seenNonASCII = Set<Character>()
        seenNonASCII.reserveCapacity(16)

        var row = 0
        while try stmt.step() {
            if row % 512 == 0 {
                try Task.checkCancellation()
            }
            row += 1

            let stored = try parseStoredItemSummary(from: stmt)
            let indexed = IndexedItem(from: stored)
            let slot = items.count
            items.append(indexed)
            idToSlot[indexed.id] = slot

            Self.appendSlotToCharPostings(
                text: indexed.plainTextLower,
                slot: slot,
                asciiCharPostings: &asciiCharPostings,
                nonASCIICharPostings: &nonASCIICharPostings,
                seenASCII: &seenASCII,
                seenNonASCII: &seenNonASCII
            )
        }

        return FullFuzzyIndex(
            items: items,
            idToSlot: idToSlot,
            asciiCharPostings: asciiCharPostings,
            nonASCIICharPostings: nonASCIICharPostings,
            tombstoneCount: 0
        )
    }

    private func shouldMarkFullIndexStaleDueToTombstones(index: FullFuzzyIndex) -> Bool {
        guard index.items.count >= fullIndexTombstoneMinSlotsForStale else { return false }
        guard index.tombstoneCount >= fullIndexTombstoneMinCountForStale else { return false }

        let ratio = Double(index.tombstoneCount) / Double(index.items.count)
        return ratio >= fullIndexTombstoneRatioStaleThreshold
    }

    private func computeCandidateSlots(
        index: FullFuzzyIndex,
        queryChars: (asciiCodes: [UInt8], nonASCIIChars: [Character])
    ) -> [Int] {
        if queryChars.asciiCodes.isEmpty, queryChars.nonASCIIChars.isEmpty {
            return Array(index.items.indices)
        }

        var lists: [[Int]] = []
        lists.reserveCapacity(queryChars.asciiCodes.count + queryChars.nonASCIIChars.count)

        for ascii in queryChars.asciiCodes {
            let list = index.asciiCharPostings[Int(ascii)]
            if list.isEmpty {
                return []
            }
            lists.append(list)
        }

        for ch in queryChars.nonASCIIChars {
            guard let list = index.nonASCIICharPostings[ch], !list.isEmpty else {
                return []
            }
            lists.append(list)
        }

        lists.sort { $0.count < $1.count }

        var candidates = lists[0]
        for list in lists.dropFirst() {
            candidates = intersectSorted(candidates, list)
            if candidates.isEmpty { break }
        }
        return candidates
    }

    private func searchInFullIndex(index: FullFuzzyIndex, request: SearchRequest, mode: SearchMode, perf: PerfContext?) throws -> SearchResult {
        let queryLower = request.query.lowercased()
        let queryChars = uniqueNonWhitespaceQueryCharacters(queryLower)

        var candidateSlots: [Int]
        if let perf {
            candidateSlots = perf.measure("full_index_candidate_intersection") {
                computeCandidateSlots(index: index, queryChars: queryChars)
            }
        } else {
            candidateSlots = computeCandidateSlots(index: index, queryChars: queryChars)
        }

        if candidateSlots.isEmpty {
            return SearchResult(items: [], total: 0, hasMore: false, isPrefilter: false, searchTimeMs: 0)
        }
        perf?.addCounter("full_index_candidate_slots", value: candidateSlots.count)

        let queryLowerIsASCII = queryLower.canBeConverted(to: .ascii)
        let preparedQuery = prepareFuzzyQuery(queryLower: queryLower, queryLowerIsASCII: queryLowerIsASCII)
        let plusWords: [(word: String, isASCII: Bool)]
        if mode == .fuzzyPlus {
            plusWords = queryLower
                .split(separator: " ")
                .map(String.init)
                .filter { !$0.isEmpty }
                .map { (word: $0, isASCII: $0.canBeConverted(to: .ascii)) }
        } else {
            plusWords = []
        }

        let plusTokens: [(word: String, isASCII: Bool, prepared: PreparedFuzzyQuery?)] = plusWords.map { wordInfo in
            if wordInfo.isASCII, wordInfo.word.count >= 3 {
                return (word: wordInfo.word, isASCII: wordInfo.isASCII, prepared: nil)
            }
            return (
                word: wordInfo.word,
                isASCII: wordInfo.isASCII,
                prepared: prepareFuzzyQuery(queryLower: wordInfo.word, queryLowerIsASCII: wordInfo.isASCII)
            )
        }

        func computeScore(for item: IndexedItem) -> Int? {
            switch mode {
            case .fuzzy:
                return fuzzyMatchScore(textLower: item.plainTextLower, query: preparedQuery)
            case .fuzzyPlus:
                var totalScore = 0
                var ok = true
                for token in plusTokens {
                    if token.isASCII, token.word.count >= 3 {
                        guard let range = item.plainTextLower.range(of: token.word) else {
                            ok = false
                            break
                        }
                        let pos = range.lowerBound.utf16Offset(in: item.plainTextLower)
                        let m = token.word.utf16.count
                        totalScore += m * 10 - (m - 1) - pos
                        continue
                    }

                    guard let prepared = token.prepared,
                          let s = fuzzyMatchScore(textLower: item.plainTextLower, query: prepared) else {
                        ok = false
                        break
                    }
                    totalScore += s
                }
                return ok ? totalScore : nil
            default:
                return nil
            }
        }

        var totalIsUnknown = false
        if (mode == .fuzzy || mode == .fuzzyPlus),
           !request.forceFullFuzzy,
            request.offset == 0,
           queryLower.count >= 4,
           queryLowerIsASCII,
           candidateSlots.count >= 6_000 {
            let desiredTopCount = max(0, request.offset + request.limit + 1)
            let prefilterLimit = min(20_000, max(5_000, desiredTopCount * 40))
            if let ftsQuery = FTSQueryBuilder.build(userQuery: queryLower) {
                let ftsSlots: [Int]?
                if let perf {
                    ftsSlots = try? perf.measure("full_index_fts_prefilter_slots") {
                        try ftsPrefilterSlots(index: index, ftsQuery: ftsQuery, limit: prefilterLimit)
                    }
                } else {
                    ftsSlots = try? ftsPrefilterSlots(index: index, ftsQuery: ftsQuery, limit: prefilterLimit)
                }

                if let ftsSlots, !ftsSlots.isEmpty {
                    let pinnedSlots = candidateSlots.filter { slot in
                        guard slot < index.items.count, let item = index.items[slot] else { return false }
                        return item.isPinned
                    }
                    var merged = Set(ftsSlots)
                    for s in pinnedSlots { merged.insert(s) }
                    candidateSlots = Array(merged)
                    perf?.addCounter("full_index_fts_prefilter_candidate_slots", value: candidateSlots.count)
                    totalIsUnknown = true
                }
            }
        }

        let desiredTopCount = max(0, request.offset + request.limit + 1)
        let sortMode = request.sortMode
        func isBetterSlot(_ lhs: ScoredSlot, than rhs: ScoredSlot) -> Bool {
            guard let lhsItem = index.items[lhs.slot] else { return false }
            guard let rhsItem = index.items[rhs.slot] else { return true }

            if lhsItem.isPinned != rhsItem.isPinned {
                return lhsItem.isPinned && !rhsItem.isPinned
            }
            switch sortMode {
            case .recent:
                if lhsItem.lastUsedAt != rhsItem.lastUsedAt {
                    return lhsItem.lastUsedAt > rhsItem.lastUsedAt
                }
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
            case .relevance:
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if lhsItem.lastUsedAt != rhsItem.lastUsedAt {
                    return lhsItem.lastUsedAt > rhsItem.lastUsedAt
                }
            }
            return lhsItem.id.uuidString < rhsItem.id.uuidString
        }

        func isWorseSlot(_ lhs: ScoredSlot, than rhs: ScoredSlot) -> Bool {
            isBetterSlot(rhs, than: lhs)
        }

        if totalIsUnknown {
            if sortMode == .recent {
                if perf == nil {
                    candidateSlots.sort { lhsSlot, rhsSlot in
                        guard lhsSlot < index.items.count, rhsSlot < index.items.count else { return lhsSlot < rhsSlot }
                        let lhsItem = index.items[lhsSlot]
                        let rhsItem = index.items[rhsSlot]
                        if lhsItem == nil { return false }
                        if rhsItem == nil { return true }
                        guard let lhsItem, let rhsItem else { return false }

                        if lhsItem.isPinned != rhsItem.isPinned {
                            return lhsItem.isPinned && !rhsItem.isPinned
                        }
                        if lhsItem.lastUsedAt != rhsItem.lastUsedAt {
                            return lhsItem.lastUsedAt > rhsItem.lastUsedAt
                        }
                        return lhsItem.id.uuidString < rhsItem.id.uuidString
                    }
                } else {
                    let sortStart = CFAbsoluteTimeGetCurrent()
                    candidateSlots.sort { lhsSlot, rhsSlot in
                        guard lhsSlot < index.items.count, rhsSlot < index.items.count else { return lhsSlot < rhsSlot }
                        let lhsItem = index.items[lhsSlot]
                        let rhsItem = index.items[rhsSlot]
                        if lhsItem == nil { return false }
                        if rhsItem == nil { return true }
                        guard let lhsItem, let rhsItem else { return false }

                        if lhsItem.isPinned != rhsItem.isPinned {
                            return lhsItem.isPinned && !rhsItem.isPinned
                        }
                        if lhsItem.lastUsedAt != rhsItem.lastUsedAt {
                            return lhsItem.lastUsedAt > rhsItem.lastUsedAt
                        }
                        return lhsItem.id.uuidString < rhsItem.id.uuidString
                    }
                    perf?.addPhase("full_index_prefilter_recent_candidate_sort", ms: (CFAbsoluteTimeGetCurrent() - sortStart) * 1000)
                }

                var pageSlots: [Int] = []
                pageSlots.reserveCapacity(request.limit + 1)
                var matchesSeen = 0

                let scanStart = CFAbsoluteTimeGetCurrent()
                for (i, slot) in candidateSlots.enumerated() {
                    if i % 1024 == 0 {
                        try Task.checkCancellation()
                    }

                    guard slot < index.items.count, let item = index.items[slot] else { continue }

                    if let appFilter = request.appFilter, item.appBundleID != appFilter { continue }
                    if let typeFilters = request.typeFilters, !typeFilters.isEmpty {
                        if !typeFilters.contains(item.type) { continue }
                    } else if let typeFilter = request.typeFilter, item.type != typeFilter {
                        continue
                    }

                    guard computeScore(for: item) != nil else { continue }

                    if matchesSeen >= request.offset {
                        pageSlots.append(slot)
                        if pageSlots.count >= request.limit + 1 {
                            break
                        }
                    }
                    matchesSeen += 1
                }
                perf?.addPhase("full_index_prefilter_recent_scan", ms: (CFAbsoluteTimeGetCurrent() - scanStart) * 1000)
                perf?.addCounter("full_index_prefilter_total_matches", value: matchesSeen)

                let hasMore = pageSlots.count > request.limit
                if hasMore {
                    pageSlots.removeLast()
                }
                let pageIDs = pageSlots.compactMap { index.items[$0]?.id }
                let resultItems: [ClipboardStoredItem]
                if let perf {
                    resultItems = try perf.measure("full_index_prefilter_fetch_items") {
                        try fetchItemsByIDs(ids: pageIDs)
                    }
                } else {
                    resultItems = try fetchItemsByIDs(ids: pageIDs)
                }
                return SearchResult(items: resultItems, total: -1, hasMore: hasMore, isPrefilter: true, searchTimeMs: 0)
            }

            var topHeap = BinaryHeap<ScoredSlot>(areSorted: isWorseSlot)
            topHeap.reserveCapacity(desiredTopCount)
            var totalMatches = 0

            let scoreStart = CFAbsoluteTimeGetCurrent()
            for (i, slot) in candidateSlots.enumerated() {
                if i % 1024 == 0 {
                    try Task.checkCancellation()
                }

                guard slot < index.items.count, let item = index.items[slot] else { continue }

                if let appFilter = request.appFilter, item.appBundleID != appFilter { continue }
                if let typeFilters = request.typeFilters, !typeFilters.isEmpty {
                    if !typeFilters.contains(item.type) { continue }
                } else if let typeFilter = request.typeFilter, item.type != typeFilter {
                    continue
                }

                guard let score = computeScore(for: item) else { continue }
                totalMatches += 1

                guard desiredTopCount > 0 else { continue }
                let scoredItem = ScoredSlot(slot: slot, score: score)

                if topHeap.count < desiredTopCount {
                    topHeap.insert(scoredItem)
                } else if let worst = topHeap.peek, isBetterSlot(scoredItem, than: worst) {
                    topHeap.replaceRoot(with: scoredItem)
                }
            }
            perf?.addPhase("full_index_prefilter_scoring", ms: (CFAbsoluteTimeGetCurrent() - scoreStart) * 1000)
            perf?.addCounter("full_index_prefilter_total_matches", value: totalMatches)

            var topItems = topHeap.elements
            let sortStart = CFAbsoluteTimeGetCurrent()
            topItems.sort { isBetterSlot($0, than: $1) }
            perf?.addPhase("full_index_prefilter_sort", ms: (CFAbsoluteTimeGetCurrent() - sortStart) * 1000)

            let start = min(request.offset, topItems.count)
            let end = min(start + request.limit, topItems.count)
            let page: [ScoredSlot] = (start < end) ? Array(topItems[start..<end]) : []

            let hasMore = totalMatches > request.offset + request.limit
            let pageIDs = page.compactMap { index.items[$0.slot]?.id }
            let resultItems: [ClipboardStoredItem]
            if let perf {
                resultItems = try perf.measure("full_index_prefilter_fetch_items") {
                    try fetchItemsByIDs(ids: pageIDs)
                }
            } else {
                resultItems = try fetchItemsByIDs(ids: pageIDs)
            }
            return SearchResult(items: resultItems, total: -1, hasMore: hasMore, isPrefilter: true, searchTimeMs: 0)
        }

        func typeFiltersKey(_ set: Set<ClipboardItemType>?) -> String? {
            guard let set, !set.isEmpty else { return nil }
            return set.map(\.rawValue).sorted().joined(separator: ",")
        }

        let sortedCacheKey = FuzzySortedMatchesCacheKey(
            mode: mode,
            sortMode: request.sortMode,
            queryLower: queryLower,
            appFilter: request.appFilter,
            typeFilter: request.typeFilter,
            typeFiltersKey: typeFiltersKey(request.typeFilters),
            forceFullFuzzy: request.forceFullFuzzy,
            indexGeneration: fullIndexGeneration
        )

        func pageFromSortedMatches(_ sortedTop: [ScoredSlot], totalMatches: Int) throws -> SearchResult {
            let start = min(request.offset, sortedTop.count)
            let end = min(start + request.limit, sortedTop.count)
            let page: [ScoredSlot] = (start < end) ? Array(sortedTop[start..<end]) : []
            let hasMore = totalMatches > request.offset + request.limit
            let pageIDs = page.compactMap { index.items[$0.slot]?.id }
            let resultItems = try fetchItemsByIDs(ids: pageIDs)
            return SearchResult(items: resultItems, total: totalMatches, hasMore: hasMore, isPrefilter: false, searchTimeMs: 0)
        }

        // Deep paging: cache a bounded "top-K" prefix to avoid repeated rescans without pinning a huge array in memory.
        if request.offset > 0 {
            let maxDeepPagingCacheTopMatches = 50_000
            let deepPagingCachePrefetchExtra = 2_000
            let cacheTopCount = min(maxDeepPagingCacheTopMatches, desiredTopCount + deepPagingCachePrefetchExtra)

            if let cached = fuzzySortedMatchesCache,
               cached.key == sortedCacheKey,
               cached.topMatches.count >= desiredTopCount {
                return try pageFromSortedMatches(cached.topMatches, totalMatches: cached.totalMatches)
            }

            var topHeap = BinaryHeap<ScoredSlot>(areSorted: isWorseSlot)
            topHeap.reserveCapacity(min(cacheTopCount, 8192))
            var totalMatches = 0

            for (i, slot) in candidateSlots.enumerated() {
                if i % 1024 == 0 {
                    try Task.checkCancellation()
                }

                guard slot < index.items.count, let item = index.items[slot] else { continue }

                if let appFilter = request.appFilter, item.appBundleID != appFilter { continue }
                if let typeFilters = request.typeFilters, !typeFilters.isEmpty {
                    if !typeFilters.contains(item.type) { continue }
                } else if let typeFilter = request.typeFilter, item.type != typeFilter {
                    continue
                }

                guard let score = computeScore(for: item) else { continue }
                totalMatches += 1

                guard cacheTopCount > 0 else { continue }
                let scoredItem = ScoredSlot(slot: slot, score: score)

                if topHeap.count < cacheTopCount {
                    topHeap.insert(scoredItem)
                } else if let worst = topHeap.peek, isBetterSlot(scoredItem, than: worst) {
                    topHeap.replaceRoot(with: scoredItem)
                }
            }

            var topItems = topHeap.elements
            topItems.sort { isBetterSlot($0, than: $1) }

            if topItems.count <= maxDeepPagingCacheTopMatches {
                fuzzySortedMatchesCache = FuzzySortedMatchesCacheValue(
                    key: sortedCacheKey,
                    totalMatches: totalMatches,
                    topMatches: topItems
                )
            } else {
                fuzzySortedMatchesCache = nil
            }

            return try pageFromSortedMatches(topItems, totalMatches: totalMatches)
        }

        var topHeap = BinaryHeap<ScoredSlot>(areSorted: isWorseSlot)
        topHeap.reserveCapacity(desiredTopCount)

        var totalMatches = 0

        for (i, slot) in candidateSlots.enumerated() {
            if i % 1024 == 0 {
                try Task.checkCancellation()
            }

            guard slot < index.items.count, let item = index.items[slot] else { continue }

            if let appFilter = request.appFilter, item.appBundleID != appFilter { continue }
            if let typeFilters = request.typeFilters, !typeFilters.isEmpty {
                if !typeFilters.contains(item.type) { continue }
            } else if let typeFilter = request.typeFilter, item.type != typeFilter {
                continue
            }

            guard let score = computeScore(for: item) else { continue }
            totalMatches += 1

            guard desiredTopCount > 0 else { continue }
            let scoredItem = ScoredSlot(slot: slot, score: score)

            if topHeap.count < desiredTopCount {
                topHeap.insert(scoredItem)
            } else if let worst = topHeap.peek, isBetterSlot(scoredItem, than: worst) {
                topHeap.replaceRoot(with: scoredItem)
            }
        }

        var topItems = topHeap.elements
        topItems.sort { isBetterSlot($0, than: $1) }

        let start = min(request.offset, topItems.count)
        let end = min(start + request.limit, topItems.count)
        let page: [ScoredSlot] = (start < end) ? Array(topItems[start..<end]) : []

        let hasMore = totalIsUnknown ? (totalMatches >= request.limit) : (totalMatches > request.offset + request.limit)
        let total = totalIsUnknown ? -1 : totalMatches

        let pageIDs = page.compactMap { index.items[$0.slot]?.id }
        let resultItems = try fetchItemsByIDs(ids: pageIDs)
        return SearchResult(items: resultItems, total: total, hasMore: hasMore, isPrefilter: totalIsUnknown, searchTimeMs: 0)
    }

    private func shouldPreferFTSForFuzzy(query: String) -> Bool {
        guard let corpusMetrics else { return false }
        guard !query.isEmpty else { return false }
        return corpusMetrics.isHeavyPlainTextCorpus
    }

    private func searchFuzzyInRecentCache(request: SearchRequest, mode: SearchMode, query: String) throws -> SearchResult {
        try refreshCacheIfNeeded()

        let queryLower = query.lowercased()
        let queryLowerIsASCII = queryLower.canBeConverted(to: .ascii)
        let preparedQuery = prepareFuzzyQuery(queryLower: queryLower, queryLowerIsASCII: queryLowerIsASCII)

        let plusWords: [(word: String, isASCII: Bool)]
        if mode == .fuzzyPlus {
            plusWords = queryLower
                .split(separator: " ")
                .map(String.init)
                .filter { !$0.isEmpty }
                .map { (word: $0, isASCII: $0.canBeConverted(to: .ascii)) }
        } else {
            plusWords = []
        }

        let plusTokens: [(word: String, isASCII: Bool, prepared: PreparedFuzzyQuery?)] = plusWords.map { wordInfo in
            if wordInfo.isASCII, wordInfo.word.count >= 3 {
                return (word: wordInfo.word, isASCII: wordInfo.isASCII, prepared: nil)
            }
            return (
                word: wordInfo.word,
                isASCII: wordInfo.isASCII,
                prepared: prepareFuzzyQuery(queryLower: wordInfo.word, queryLowerIsASCII: wordInfo.isASCII)
            )
        }

        func score(for cached: CachedRecentItem) -> Int? {
            let textLower = cached.combinedLower

            switch mode {
            case .fuzzy:
                return fuzzyMatchScore(textLower: textLower, query: preparedQuery)
            case .fuzzyPlus:
                var totalScore = 0
                var ok = true
                for token in plusTokens {
                    if token.isASCII, token.word.count >= 3 {
                        guard let range = textLower.range(of: token.word) else {
                            ok = false
                            break
                        }
                        let pos = range.lowerBound.utf16Offset(in: textLower)
                        let m = token.word.utf16.count
                        totalScore += m * 10 - (m - 1) - pos
                        continue
                    }

                    guard let prepared = token.prepared,
                          let s = fuzzyMatchScore(textLower: textLower, query: prepared) else {
                        ok = false
                        break
                    }
                    totalScore += s
                }
                return ok ? totalScore : nil
            default:
                return nil
            }
        }

        struct ScoredCachedItem {
            let item: ClipboardStoredItem
            let score: Int
        }

        var scored: [ScoredCachedItem] = []
        scored.reserveCapacity(min(recentItemsCache.count, shortQueryCacheSize))

        for cached in recentItemsCache {
            let item = cached.item
            if let appFilter = request.appFilter, item.appBundleID != appFilter { continue }
            if let typeFilters = request.typeFilters, !typeFilters.isEmpty {
                if !typeFilters.contains(item.type) { continue }
            } else if let typeFilter = request.typeFilter {
                if item.type != typeFilter { continue }
            }

            guard let s = score(for: cached) else { continue }
            scored.append(ScoredCachedItem(item: item, score: s))
        }

        scored.sort { lhs, rhs in
            if lhs.item.isPinned != rhs.item.isPinned {
                return lhs.item.isPinned && !rhs.item.isPinned
            }
            switch request.sortMode {
            case .recent:
                if lhs.item.lastUsedAt != rhs.item.lastUsedAt {
                    return lhs.item.lastUsedAt > rhs.item.lastUsedAt
                }
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
            case .relevance:
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if lhs.item.lastUsedAt != rhs.item.lastUsedAt {
                    return lhs.item.lastUsedAt > rhs.item.lastUsedAt
                }
            }
            return lhs.item.id.uuidString < rhs.item.id.uuidString
        }

        let totalMatches = scored.count
        let start = min(request.offset, totalMatches)
        let end = min(start + request.limit + 1, totalMatches)
        var page = (start < end) ? Array(scored[start..<end]) : []

        let hasMore = page.count > request.limit
        if hasMore {
            page.removeLast()
        }

        let items = page.map(\.item)
        return SearchResult(items: items, total: -1, hasMore: hasMore, isPrefilter: true, searchTimeMs: 0)
    }

    private func ftsPrefilterSlots(index: FullFuzzyIndex, ftsQuery: String, limit: Int) throws -> [Int] {
        let ids = try ftsPrefilterIDs(ftsQuery: ftsQuery, limit: limit)
        return ids.compactMap { index.idToSlot[$0] }
    }

    private func intersectSorted(_ a: [Int], _ b: [Int]) -> [Int] {
        var i = 0
        var j = 0
        var result: [Int] = []
        result.reserveCapacity(min(a.count, b.count))

        while i < a.count && j < b.count {
            let va = a[i]
            let vb = b[j]
            if va == vb {
                result.append(va)
                i += 1
                j += 1
            } else if va < vb {
                i += 1
            } else {
                j += 1
            }
        }

        return result
    }

    @discardableResult
    private func upsertItemIntoIndex(_ item: ClipboardStoredItem, index: inout FullFuzzyIndex) -> Bool {
        let indexed = IndexedItem(from: item)

        if let slot = index.idToSlot[item.id],
           slot < index.items.count,
           let existing = index.items[slot] {
            // Fast path: metadata-only update (text/note unchanged).
            if existing.plainTextLower == indexed.plainTextLower {
                index.items[slot] = indexed
                return false
            }

            // Text/note changed: keep correctness by tombstoning the old slot and appending a new one.
            // This avoids costly postings removals while still keeping full-history fuzzy results complete.
            index.items[slot] = nil
            index.tombstoneCount += 1
        }

        let newSlot = index.items.count
        index.items.append(indexed)
        index.idToSlot[indexed.id] = newSlot

        Self.appendSlotToCharPostings(
            text: indexed.plainTextLower,
            slot: newSlot,
            asciiCharPostings: &index.asciiCharPostings,
            nonASCIICharPostings: &index.nonASCIICharPostings,
            seenASCII: &charPostingsScratchASCII,
            seenNonASCII: &charPostingsScratchNonASCII
        )
        return true
    }

    private static func appendSlotToCharPostings(
        text: String,
        slot: Int,
        asciiCharPostings: inout [[Int]],
        nonASCIICharPostings: inout [Character: [Int]],
        seenASCII: inout [Bool],
        seenNonASCII: inout Set<Character>
    ) {
        for i in 0..<seenASCII.count {
            seenASCII[i] = false
        }
        seenNonASCII.removeAll(keepingCapacity: true)

        for ch in text {
            if ch.isWhitespace { continue }
            if let ascii = ch.asciiValue {
                let idx = Int(ascii)
                if !seenASCII[idx] {
                    seenASCII[idx] = true
                    asciiCharPostings[idx].append(slot)
                }
                continue
            }

            if seenNonASCII.insert(ch).inserted {
                nonASCIICharPostings[ch, default: []].append(slot)
            }
        }
    }

    private func uniqueNonWhitespaceQueryCharacters(_ text: String) -> (asciiCodes: [UInt8], nonASCIIChars: [Character]) {
        var asciiCodes: [UInt8] = []
        var nonASCIIChars: [Character] = []
        asciiCodes.reserveCapacity(min(text.count, 64))
        nonASCIIChars.reserveCapacity(min(text.count, 64))

        var seenASCII0: UInt64 = 0
        var seenASCII1: UInt64 = 0
        var seenNonASCII = Set<Character>()
        seenNonASCII.reserveCapacity(min(text.count, 64))

        for ch in text {
            if ch.isWhitespace { continue }

            if let ascii = ch.asciiValue {
                if ascii < 64 {
                    let bit = UInt64(1) << UInt64(ascii)
                    if (seenASCII0 & bit) == 0 {
                        seenASCII0 |= bit
                        asciiCodes.append(ascii)
                    }
                } else {
                    let bit = UInt64(1) << UInt64(ascii - 64)
                    if (seenASCII1 & bit) == 0 {
                        seenASCII1 |= bit
                        asciiCodes.append(ascii)
                    }
                }
                continue
            }

            if seenNonASCII.insert(ch).inserted {
                nonASCIIChars.append(ch)
            }
        }

        return (asciiCodes: asciiCodes, nonASCIIChars: nonASCIIChars)
    }

    private struct PreparedFuzzyQuery {
        let lower: String
        let isASCII: Bool
        let characterCount: Int
        let utf16Count: Int
        let safeFastUTF16: Bool
        let utf16Units: [UInt16]?
    }

    private func prepareFuzzyQuery(queryLower: String, queryLowerIsASCII: Bool) -> PreparedFuzzyQuery {
        let characterCount = queryLower.count
        if characterCount <= 2 {
            let safeFastUTF16 = queryLowerIsASCII || isSafeForFastUTF16Search(queryLower)
            if safeFastUTF16 {
                let units = Array(queryLower.utf16)
                return PreparedFuzzyQuery(
                    lower: queryLower,
                    isASCII: queryLowerIsASCII,
                    characterCount: characterCount,
                    utf16Count: units.count,
                    safeFastUTF16: true,
                    utf16Units: units
                )
            }

            return PreparedFuzzyQuery(
                lower: queryLower,
                isASCII: queryLowerIsASCII,
                characterCount: characterCount,
                utf16Count: queryLower.utf16.count,
                safeFastUTF16: false,
                utf16Units: nil
            )
        }

        if queryLowerIsASCII {
            let units = Array(queryLower.utf16)
            return PreparedFuzzyQuery(
                lower: queryLower,
                isASCII: true,
                characterCount: characterCount,
                utf16Count: units.count,
                safeFastUTF16: true,
                utf16Units: units
            )
        }

        return PreparedFuzzyQuery(
            lower: queryLower,
            isASCII: false,
            characterCount: characterCount,
            utf16Count: queryLower.utf16.count,
            safeFastUTF16: false,
            utf16Units: nil
        )
    }

    private func fuzzyMatchScore(textLower: String, query: PreparedFuzzyQuery) -> Int? {
        guard !query.lower.isEmpty else { return 0 }

        if query.characterCount <= 2 {
            guard let pos = findNeedleUTF16Offset(haystack: textLower, needle: query) else { return nil }
            let m = query.utf16Count
            return m * 10 - (m - 1) - pos
        }

        if query.isASCII, let queryUnits = query.utf16Units {
            return fuzzyMatchScoreASCIIUTF16(textLower: textLower, queryUnits: queryUnits)
        }

        // Fuzzy subsequence matching (non-contiguous). Implemented as a single pass to avoid
        // repeated `String.Index` distance computations on large/unicode-heavy texts.
        var queryIterator = query.lower.makeIterator()
        guard var queryChar = queryIterator.next() else { return 0 }

        var firstPos: Int?
        var lastPos = 0
        var gapPenalty = 0
        var matchedCount = 0
        var searchStartPos = 0

        var pos = 0
        for ch in textLower {
            if ch == queryChar {
                if firstPos == nil { firstPos = pos }
                gapPenalty += pos - searchStartPos
                matchedCount += 1
                lastPos = pos
                if let next = queryIterator.next() {
                    queryChar = next
                    searchStartPos = pos + 1
                } else {
                    break
                }
            }
            pos += 1
        }

        guard matchedCount == query.characterCount else { return nil }
        let span = firstPos.map { lastPos - $0 } ?? 0
        return matchedCount * 10 - span - gapPenalty
    }

    private func fuzzyMatchScoreASCIIUTF16(textLower: String, queryUnits: [UInt16]) -> Int? {
        // ASCII-only query: run a single-pass subsequence match on UTF16 code units.
        //
        // Rationale:
        // - Avoids `Character` iteration overhead on very large texts.
        // - Keeps score semantics aligned with the existing gap/span model, and naturally
        //   ranks contiguous matches higher (because span/gapPenalty become smaller).
        guard !queryUnits.isEmpty else { return 0 }

        var queryIndex = 0
        let queryCount = queryUnits.count
        var firstPos: Int?
        var lastPos = 0
        var gapPenalty = 0
        var matchedCount = 0
        var searchStartPos = 0

        var pos = 0
        for cu in textLower.utf16 {
            if cu == queryUnits[queryIndex] {
                if firstPos == nil { firstPos = pos }
                gapPenalty += pos - searchStartPos
                matchedCount += 1
                lastPos = pos
                queryIndex += 1
                if queryIndex >= queryCount { break }
                searchStartPos = pos + 1
            }
            pos += 1
        }

        guard matchedCount == queryCount else { return nil }
        let span = firstPos.map { lastPos - $0 } ?? 0
        return matchedCount * 10 - span - gapPenalty
    }

    private func findNeedleUTF16Offset(haystack: String, needle: PreparedFuzzyQuery) -> Int? {
        guard !needle.lower.isEmpty else { return 0 }

        if needle.safeFastUTF16, let needleUnits = needle.utf16Units {
            if needleUnits.count <= 4 {
                return findNeedleUTF16OffsetFast(haystack: haystack, needleUnits: needleUnits)
            }
        }

        guard let range = haystack.range(of: needle.lower) else { return nil }
        return range.lowerBound.utf16Offset(in: haystack)
    }

    private func findNeedleUTF16OffsetFast(haystack: String, needleUnits: [UInt16]) -> Int? {
        guard let first = needleUnits.first else { return 0 }

        // Hot path: short needles (≤ 4 UTF16 units).
        switch needleUnits.count {
        case 1:
            var pos = 0
            for cu in haystack.utf16 {
                if cu == first { return pos }
                pos += 1
            }
            return nil
        case 2:
            let second = needleUnits[1]
            var pos = 0
            var prev: UInt16? = nil
            for cu in haystack.utf16 {
                if prev == first, cu == second {
                    return pos - 1
                }
                prev = cu
                pos += 1
            }
            return nil
        case 3:
            let second = needleUnits[1]
            let third = needleUnits[2]
            var pos = 0
            var prev1: UInt16? = nil
            var prev2: UInt16? = nil
            for cu in haystack.utf16 {
                if prev2 == first, prev1 == second, cu == third {
                    return pos - 2
                }
                prev2 = prev1
                prev1 = cu
                pos += 1
            }
            return nil
        case 4:
            let second = needleUnits[1]
            let third = needleUnits[2]
            let fourth = needleUnits[3]
            var pos = 0
            var prev1: UInt16? = nil
            var prev2: UInt16? = nil
            var prev3: UInt16? = nil
            for cu in haystack.utf16 {
                if prev3 == first, prev2 == second, prev1 == third, cu == fourth {
                    return pos - 3
                }
                prev3 = prev2
                prev2 = prev1
                prev1 = cu
                pos += 1
            }
            return nil
        default:
            return nil
        }
    }

    private func isSafeForFastUTF16Search(_ needle: String) -> Bool {
        // If canonical mapping changes, Swift `String` search may match canonically-equivalent sequences.
        // Keep the fast UTF16 scan only when the needle is stable under canonical compose/decompose.
        let ns = needle as NSString
        if ns.precomposedStringWithCanonicalMapping != needle { return false }
        if ns.decomposedStringWithCanonicalMapping != needle { return false }
        return true
    }

    // MARK: - Timeout

    private func withTimeout<T: Sendable>(
        timeout: TimeInterval,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await work()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SearchError.timeout
            }

            do {
                guard let value = try await group.next() else {
                    group.cancelAll()
                    throw SearchError.timeout
                }
                group.cancelAll()
                return value
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    // MARK: - DB Access

    private func openIfNeeded() throws {
        guard connection == nil else { return }

        let flags = SQLiteConnection.openFlags(for: dbPath, readOnly: true)
        let conn: SQLiteConnection
        do {
            conn = try SQLiteConnection(path: dbPath, flags: flags)
        } catch {
            throw SearchError.searchFailed(error.localizedDescription)
        }

        do {
            try conn.execute("PRAGMA query_only = 1")
            try conn.execute("PRAGMA busy_timeout = 500")
            try conn.execute("PRAGMA cache_size = -64000")
            try conn.execute("PRAGMA temp_store = MEMORY")
            try conn.execute("PRAGMA mmap_size = 268435456")
            try verifySchema(conn)
            supportsTrigramFTS = (try? conn.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='clipboard_fts_trigram'").step()) == true
            usesMutationSeq = (try? conn.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='scopy_meta'").step()) == true
        } catch {
            conn.close()
            throw SearchError.searchFailed(error.localizedDescription)
        }

        connection = conn
        statementCache = [:]
        statementCacheLRU = []
        fuzzySortedMatchesCache = nil
        refreshCorpusMetricsIfNeeded(force: true)
        refreshKnownDBChangeTokenIfPossible()
        startShortQueryIndexBuildIfNeeded()
    }

    private func markCorpusMetricsStale() {
        corpusMetricsUpdatedAt = .distantPast
    }

    private func refreshCorpusMetricsIfNeeded(force: Bool = false) {
        if !force,
           corpusMetrics != nil,
           corpusMetricsUpdatedAt != .distantPast {
            return
        }

        if let metrics = try? computeCorpusMetrics() {
            corpusMetrics = metrics
        }
        corpusMetricsUpdatedAt = Date()
    }

    private func computeCorpusMetrics() throws -> CorpusMetrics {
        let sql = """
            SELECT COUNT(*), AVG(LENGTH(CAST(plain_text AS BLOB))), MAX(LENGTH(CAST(plain_text AS BLOB)))
            FROM clipboard_items
        """
        let stmt = try prepare(sql)
        defer { stmt.reset() }

        guard try stmt.step() else {
            return CorpusMetrics(itemCount: 0, avgPlainTextLength: 0, maxPlainTextLength: 0)
        }

        let itemCount = stmt.columnInt(0)
        let avgLength = stmt.columnDouble(1)
        let maxLength = stmt.columnInt(2)

        return CorpusMetrics(
            itemCount: itemCount,
            avgPlainTextLength: avgLength,
            maxPlainTextLength: maxLength
        )
    }

    private func verifySchema(_ connection: SQLiteConnection) throws {
        let mainStmt = try connection.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='clipboard_items'")
        guard try mainStmt.step() else {
            throw SearchError.searchFailed("Main table 'clipboard_items' not found")
        }

        let ftsStmt = try connection.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='clipboard_fts'")
        guard try ftsStmt.step() else {
            throw SearchError.searchFailed("FTS table 'clipboard_fts' not found")
        }
    }

    private func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let connection else { throw SearchError.databaseNotOpen }

        if let cached = statementCache[sql] {
            cached.statement.reset()
            if let idx = statementCacheLRU.firstIndex(of: sql) {
                statementCacheLRU.remove(at: idx)
            }
            statementCacheLRU.append(sql)
            return cached.statement
        }

        do {
            let stmt = try connection.prepare(sql)
            if statementCache.count >= statementCacheLimit {
                while statementCache.count >= statementCacheLimit, let evictSQL = statementCacheLRU.first {
                    statementCacheLRU.removeFirst()
                    statementCache.removeValue(forKey: evictSQL)
                }

                if statementCache.count >= statementCacheLimit {
                    statementCache.removeAll(keepingCapacity: true)
                    statementCacheLRU.removeAll(keepingCapacity: true)
                }
            }

            statementCache[sql] = CachedStatement(sql: sql, statement: stmt)
            if let idx = statementCacheLRU.firstIndex(of: sql) {
                statementCacheLRU.remove(at: idx)
            }
            statementCacheLRU.append(sql)
            return stmt
        } catch {
            statementCache.removeValue(forKey: sql)
            if let idx = statementCacheLRU.firstIndex(of: sql) {
                statementCacheLRU.remove(at: idx)
            }
            throw SearchError.searchFailed(error.localizedDescription)
        }
    }

    private func fetchRecentSummaries(limit: Int, offset: Int) throws -> [ClipboardStoredItem] {
        let sql = """
            SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref, file_size_bytes
            FROM clipboard_items
            ORDER BY is_pinned DESC, last_used_at DESC, id ASC
            LIMIT ? OFFSET ?
        """
        let stmt = try prepare(sql)
        defer { stmt.reset() }
        try stmt.bindInt(limit, at: 1)
        try stmt.bindInt(offset, at: 2)

        var items: [ClipboardStoredItem] = []
        items.reserveCapacity(limit)
        var row = 0
        while try stmt.step() {
            if row % 512 == 0 { try Task.checkCancellation() }
            row += 1
            items.append(try parseStoredItemSummary(from: stmt))
        }
        return items
    }

    private func fetchAllSummaries() throws -> [ClipboardStoredItem] {
        let sql = """
            SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref, file_size_bytes
            FROM clipboard_items
        """
        let stmt = try prepare(sql)
        defer { stmt.reset() }

        var items: [ClipboardStoredItem] = []
        var row = 0
        while try stmt.step() {
            if row % 512 == 0 { try Task.checkCancellation() }
            row += 1
            items.append(try parseStoredItemSummary(from: stmt))
        }
        return items
    }

    private func fetchItemsByIDs(ids: [UUID]) throws -> [ClipboardStoredItem] {
        guard !ids.isEmpty else { return [] }

        // Use a fixed SQL shape to improve statement cache hit rate and keep results ordered.
        var json = "["
        json.reserveCapacity(2 + ids.count * 39)
        for (i, id) in ids.enumerated() {
            if i > 0 { json.append(",") }
            json.append("\"")
            json.append(id.uuidString)
            json.append("\"")
        }
        json.append("]")

        let sql = """
            WITH ids(id, ord) AS (
                SELECT value, CAST(key AS INT)
                FROM json_each(?)
            )
            SELECT clipboard_items.id, clipboard_items.type, clipboard_items.content_hash, clipboard_items.plain_text,
                   clipboard_items.note, clipboard_items.app_bundle_id, clipboard_items.created_at, clipboard_items.last_used_at,
                   clipboard_items.use_count, clipboard_items.is_pinned, clipboard_items.size_bytes, clipboard_items.storage_ref,
                   clipboard_items.file_size_bytes
            FROM ids
            JOIN clipboard_items ON clipboard_items.id = ids.id
            ORDER BY ids.ord
        """
        let stmt = try prepare(sql)
        defer { stmt.reset() }

        try stmt.bindText(json, at: 1)

        var fetched: [ClipboardStoredItem] = []
        fetched.reserveCapacity(ids.count)
        while try stmt.step() {
            fetched.append(try parseStoredItemSummary(from: stmt))
        }

        return fetched
    }

    private func searchAllWithFilters(request: SearchRequest) throws -> SearchResult {
        let typeFilters = request.typeFilters.map(Array.init)
        let page = try searchAllWithFilters(
            appFilter: request.appFilter,
            typeFilter: request.typeFilter,
            typeFilters: typeFilters,
            limit: request.limit,
            offset: request.offset
        )
        return SearchResult(items: page.items, total: page.total, hasMore: page.hasMore, isPrefilter: false, searchTimeMs: 0)
    }

    private func searchAllWithFilters(
        appFilter: String?,
        typeFilter: ClipboardItemType?,
        typeFilters: [ClipboardItemType]?,
        limit: Int,
        offset: Int
    ) throws -> (items: [ClipboardStoredItem], total: Int, hasMore: Bool) {
        var sql = """
            SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref, file_size_bytes
            FROM clipboard_items
            WHERE 1 = 1
        """
        var params: [String] = []

        if let appFilter {
            sql += " AND app_bundle_id = ?"
            params.append(appFilter)
        }

        if let typeFilters, !typeFilters.isEmpty {
            let placeholders = typeFilters.map { _ in "?" }.joined(separator: ",")
            sql += " AND type IN (\(placeholders))"
            params.append(contentsOf: typeFilters.map(\.rawValue))
        } else if let typeFilter {
            sql += " AND type = ?"
            params.append(typeFilter.rawValue)
        }

        sql += " ORDER BY is_pinned DESC, last_used_at DESC, id ASC"
        sql += " LIMIT ? OFFSET ?"

        let stmt = try prepare(sql)
        defer { stmt.reset() }
        var bindIndex: Int32 = 1
        for param in params {
            try stmt.bindText(param, at: bindIndex)
            bindIndex += 1
        }
        try stmt.bindInt(limit + 1, at: bindIndex)
        try stmt.bindInt(offset, at: bindIndex + 1)

        var items: [ClipboardStoredItem] = []
        items.reserveCapacity(limit + 1)
        while try stmt.step() {
            items.append(try parseStoredItemSummary(from: stmt))
        }

        let hasMore = items.count > limit
        if hasMore {
            items = Array(items.prefix(limit))
        }

        let total = hasMore ? -1 : offset + items.count
        return (items, total, hasMore)
    }

    private func searchWithFTS(
        ftsQuery: String,
        sortMode: SearchSortMode,
        appFilter: String?,
        typeFilter: ClipboardItemType?,
        typeFilters: [ClipboardItemType]?,
        limit: Int,
        offset: Int
    ) throws -> (items: [ClipboardStoredItem], total: Int, hasMore: Bool) {
        let sql: String
        switch sortMode {
        case .relevance:
            sql = """
                SELECT clipboard_items.id, clipboard_items.type, clipboard_items.content_hash, clipboard_items.plain_text,
                       clipboard_items.note, clipboard_items.app_bundle_id, clipboard_items.created_at, clipboard_items.last_used_at,
                       clipboard_items.use_count, clipboard_items.is_pinned, clipboard_items.size_bytes, clipboard_items.storage_ref,
                       clipboard_items.file_size_bytes
                FROM clipboard_fts
                JOIN clipboard_items ON clipboard_items.rowid = clipboard_fts.rowid
                WHERE clipboard_fts MATCH ?
            """
        case .recent:
            sql = """
                SELECT clipboard_items.id, clipboard_items.type, clipboard_items.content_hash, clipboard_items.plain_text,
                       clipboard_items.note, clipboard_items.app_bundle_id, clipboard_items.created_at, clipboard_items.last_used_at,
                       clipboard_items.use_count, clipboard_items.is_pinned, clipboard_items.size_bytes, clipboard_items.storage_ref,
                       clipboard_items.file_size_bytes
                FROM clipboard_fts
                JOIN clipboard_items ON clipboard_items.rowid = clipboard_fts.rowid
                WHERE clipboard_fts MATCH ?
            """
        }

        var sqlWithFilters = sql
        var params: [String] = [ftsQuery]

        if let appFilter {
            sqlWithFilters += " AND clipboard_items.app_bundle_id = ?"
            params.append(appFilter)
        }

        if let typeFilters, !typeFilters.isEmpty {
            let placeholders = typeFilters.map { _ in "?" }.joined(separator: ",")
            sqlWithFilters += " AND clipboard_items.type IN (\(placeholders))"
            params.append(contentsOf: typeFilters.map(\.rawValue))
        } else if let typeFilter {
            sqlWithFilters += " AND clipboard_items.type = ?"
            params.append(typeFilter.rawValue)
        }

        switch sortMode {
        case .relevance:
            sqlWithFilters += " ORDER BY clipboard_items.is_pinned DESC, bm25(clipboard_fts) ASC, clipboard_items.last_used_at DESC, clipboard_items.id ASC"
        case .recent:
            sqlWithFilters += " ORDER BY clipboard_items.is_pinned DESC, clipboard_items.last_used_at DESC, clipboard_items.id ASC"
        }
        sqlWithFilters += " LIMIT ? OFFSET ?"

        let stmt = try prepare(sqlWithFilters)
        defer { stmt.reset() }
        var bindIndex: Int32 = 1
        for param in params {
            try stmt.bindText(param, at: bindIndex)
            bindIndex += 1
        }
        try stmt.bindInt(limit + 1, at: bindIndex)
        try stmt.bindInt(offset, at: bindIndex + 1)

        var items: [ClipboardStoredItem] = []
        items.reserveCapacity(limit + 1)
        while try stmt.step() {
            items.append(try parseStoredItemSummary(from: stmt))
        }

        let hasMore = items.count > limit
        if hasMore {
            items.removeLast()
        }
        let total = hasMore ? -1 : offset + items.count
        return (items, total, hasMore)
    }

    private func searchWithTrigramFTS(
        ftsQuery: String,
        primaryTokenLower: String,
        sortMode: SearchSortMode,
        appFilter: String?,
        typeFilter: ClipboardItemType?,
        typeFilters: [ClipboardItemType]?,
        limit: Int,
        offset: Int
    ) throws -> (items: [ClipboardStoredItem], total: Int, hasMore: Bool) {
        let sql: String
        var params: [String] = []

        switch sortMode {
        case .recent:
            sql = """
                SELECT clipboard_items.id, clipboard_items.type, clipboard_items.content_hash, clipboard_items.plain_text,
                       clipboard_items.note, clipboard_items.app_bundle_id, clipboard_items.created_at, clipboard_items.last_used_at,
                       clipboard_items.use_count, clipboard_items.is_pinned, clipboard_items.size_bytes, clipboard_items.storage_ref,
                       clipboard_items.file_size_bytes
                FROM clipboard_fts_trigram
                JOIN clipboard_items ON clipboard_items.rowid = clipboard_fts_trigram.rowid
                WHERE clipboard_fts_trigram MATCH ?
            """
            params.append(ftsQuery)
        case .relevance:
            sql = """
                SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                       use_count, is_pinned, size_bytes, storage_ref, file_size_bytes
                FROM (
                    SELECT clipboard_items.id, clipboard_items.type, clipboard_items.content_hash, clipboard_items.plain_text,
                           clipboard_items.note, clipboard_items.app_bundle_id, clipboard_items.created_at, clipboard_items.last_used_at,
                           clipboard_items.use_count, clipboard_items.is_pinned, clipboard_items.size_bytes, clipboard_items.storage_ref,
                           clipboard_items.file_size_bytes,
                           instr(lower(clipboard_items.plain_text), ?) AS plainPos,
                           instr(lower(coalesce(clipboard_items.note, '')), ?) AS notePos
                    FROM clipboard_fts_trigram
                    JOIN clipboard_items ON clipboard_items.rowid = clipboard_fts_trigram.rowid
                    WHERE clipboard_fts_trigram MATCH ?
            """
            params.append(primaryTokenLower)
            params.append(primaryTokenLower)
            params.append(ftsQuery)
        }

        var sqlWithFilters = sql

        if let appFilter {
            sqlWithFilters += " AND app_bundle_id = ?"
            params.append(appFilter)
        }

        if let typeFilters, !typeFilters.isEmpty {
            let placeholders = typeFilters.map { _ in "?" }.joined(separator: ",")
            sqlWithFilters += " AND type IN (\(placeholders))"
            params.append(contentsOf: typeFilters.map(\.rawValue))
        } else if let typeFilter {
            sqlWithFilters += " AND type = ?"
            params.append(typeFilter.rawValue)
        }

        switch sortMode {
        case .recent:
            sqlWithFilters += " ORDER BY is_pinned DESC, last_used_at DESC, id ASC"
            sqlWithFilters += " LIMIT ? OFFSET ?"
        case .relevance:
            sqlWithFilters += """
                    ) t
                WHERE plainPos > 0 OR notePos > 0
                ORDER BY is_pinned DESC,
                         CASE
                           WHEN plainPos > 0 AND notePos > 0 THEN CASE WHEN plainPos < notePos THEN plainPos ELSE notePos END
                           WHEN plainPos > 0 THEN plainPos
                           ELSE notePos
                         END ASC,
                         last_used_at DESC,
                         id ASC
                LIMIT ? OFFSET ?
            """
        }

        let stmt = try prepare(sqlWithFilters)
        defer { stmt.reset() }
        var bindIndex: Int32 = 1
        for param in params {
            try stmt.bindText(param, at: bindIndex)
            bindIndex += 1
        }
        try stmt.bindInt(limit + 1, at: bindIndex)
        try stmt.bindInt(offset, at: bindIndex + 1)

        var items: [ClipboardStoredItem] = []
        items.reserveCapacity(limit + 1)
        while try stmt.step() {
            items.append(try parseStoredItemSummary(from: stmt))
        }

        let hasMore = items.count > limit
        if hasMore {
            items.removeLast()
        }
        let total = hasMore ? -1 : offset + items.count
        return (items, total, hasMore)
    }

    private func searchWithSubstring(
        tokens: [String],
        sortMode: SearchSortMode,
        appFilter: String?,
        typeFilter: ClipboardItemType?,
        typeFilters: [ClipboardItemType]?,
        limit: Int,
        offset: Int
    ) throws -> (items: [ClipboardStoredItem], total: Int, hasMore: Bool) {
        let tokens = tokens.filter { !$0.isEmpty }
        guard let primary = tokens.first else { return ([], 0, false) }
        let extraTokens = Array(tokens.dropFirst())

        if shouldUseTrigramFTS(tokens: tokens),
           let ftsQuery = buildTrigramFTSQuery(tokens: tokens)
        {
            return try searchWithTrigramFTS(
                ftsQuery: ftsQuery,
                primaryTokenLower: primary.lowercased(),
                sortMode: sortMode,
                appFilter: appFilter,
                typeFilter: typeFilter,
                typeFilters: typeFilters,
                limit: limit,
                offset: offset
            )
        }

        var params: [String] = []
        var sql: String

        switch sortMode {
        case .recent:
            sql = """
                SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                       use_count, is_pinned, size_bytes, storage_ref, file_size_bytes
                FROM clipboard_items INDEXED BY idx_pinned
                WHERE 1 = 1
            """

            if let appFilter {
                sql += " AND app_bundle_id = ?"
                params.append(appFilter)
            }

            if let typeFilters, !typeFilters.isEmpty {
                let placeholders = typeFilters.map { _ in "?" }.joined(separator: ",")
                sql += " AND type IN (\(placeholders))"
                params.append(contentsOf: typeFilters.map(\.rawValue))
            } else if let typeFilter {
                sql += " AND type = ?"
                params.append(typeFilter.rawValue)
            }

            func appendTokenFilter(_ token: String) {
                sql += " AND (instr(plain_text, ?) > 0 OR instr(coalesce(note, ''), ?) > 0)"
                params.append(token)
                params.append(token)
            }

            appendTokenFilter(primary)
            for token in extraTokens {
                appendTokenFilter(token)
            }

            sql += " ORDER BY is_pinned DESC, last_used_at DESC, id ASC"
            sql += " LIMIT ? OFFSET ?"
        case .relevance:
            sql = """
                SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                       use_count, is_pinned, size_bytes, storage_ref, file_size_bytes
                FROM (
                    SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                           use_count, is_pinned, size_bytes, storage_ref, file_size_bytes,
                           instr(plain_text, ?) AS plainPos,
                           instr(coalesce(note, ''), ?) AS notePos
                    FROM clipboard_items INDEXED BY idx_pinned
                    WHERE 1 = 1
            """
            params.append(primary)
            params.append(primary)

            if let appFilter {
                sql += " AND app_bundle_id = ?"
                params.append(appFilter)
            }

            if let typeFilters, !typeFilters.isEmpty {
                let placeholders = typeFilters.map { _ in "?" }.joined(separator: ",")
                sql += " AND type IN (\(placeholders))"
                params.append(contentsOf: typeFilters.map(\.rawValue))
            } else if let typeFilter {
                sql += " AND type = ?"
                params.append(typeFilter.rawValue)
            }

            for token in extraTokens {
                sql += " AND (instr(plain_text, ?) > 0 OR instr(coalesce(note, ''), ?) > 0)"
                params.append(token)
                params.append(token)
            }

            sql += """
                    ) t
                WHERE plainPos > 0 OR notePos > 0
                ORDER BY is_pinned DESC,
                         CASE
                           WHEN plainPos > 0 AND notePos > 0 THEN CASE WHEN plainPos < notePos THEN plainPos ELSE notePos END
                           WHEN plainPos > 0 THEN plainPos
                           ELSE notePos
                         END ASC,
                         last_used_at DESC,
                         id ASC
                LIMIT ? OFFSET ?
            """
        }

        let stmt = try prepare(sql)
        defer { stmt.reset() }

        var bindIndex: Int32 = 1
        for param in params {
            try stmt.bindText(param, at: bindIndex)
            bindIndex += 1
        }
        try stmt.bindInt(limit + 1, at: bindIndex)
        try stmt.bindInt(offset, at: bindIndex + 1)

        var items: [ClipboardStoredItem] = []
        items.reserveCapacity(limit + 1)
        while try stmt.step() {
            items.append(try parseStoredItemSummary(from: stmt))
        }

        let hasMore = items.count > limit
        if hasMore {
            items.removeLast()
        }
        let total = hasMore ? -1 : offset + items.count
        return (items, total, hasMore)
    }

    private func buildCandidateIDsJSON(_ ids: [String]) -> String {
        var json = "["
        json.reserveCapacity(ids.count * 40 + 2)
        for (i, id) in ids.enumerated() {
            if i > 0 { json.append(",") }
            json.append("\"")
            json.append(id)
            json.append("\"")
        }
        json.append("]")
        return json
    }

    private func searchWithShortQuerySubstringCandidates(
        tokenLower: String,
        candidateIDStrings: [String],
        sortMode: SearchSortMode,
        appFilter: String?,
        typeFilter: ClipboardItemType?,
        typeFilters: [ClipboardItemType]?,
        limit: Int,
        offset: Int
    ) throws -> (items: [ClipboardStoredItem], total: Int, hasMore: Bool) {
        let tokenLower = tokenLower.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tokenLower.isEmpty else { return ([], 0, false) }
        guard !candidateIDStrings.isEmpty else { return ([], 0, false) }

        let needleLowerBytes = Array(tokenLower.utf8)
        guard (needleLowerBytes.count == 1 || needleLowerBytes.count == 2),
              needleLowerBytes.allSatisfy({ $0 < 128 }) else {
            return try searchWithShortQuerySubstring(
                tokenLower: tokenLower,
                sortMode: sortMode,
                appFilter: appFilter,
                typeFilter: typeFilter,
                typeFilters: typeFilters,
                limit: limit,
                offset: offset
            )
        }

        let candidatesJSON = buildCandidateIDsJSON(candidateIDStrings)

        var sql = """
            WITH candidates(id) AS (SELECT value FROM json_each(?))
            SELECT clipboard_items.id,
                   clipboard_items.last_used_at,
                   clipboard_items.is_pinned,
                   clipboard_items.plain_text,
                   clipboard_items.note
            FROM clipboard_items
            JOIN candidates ON clipboard_items.id = candidates.id
            WHERE 1 = 1
        """

        var params: [String] = []
        params.append(candidatesJSON)

        if let appFilter {
            sql += " AND app_bundle_id = ?"
            params.append(appFilter)
        }

        if let typeFilters, !typeFilters.isEmpty {
            let placeholders = typeFilters.map { _ in "?" }.joined(separator: ",")
            sql += " AND type IN (\(placeholders))"
            params.append(contentsOf: typeFilters.map(\.rawValue))
        } else if let typeFilter {
            sql += " AND type = ?"
            params.append(typeFilter.rawValue)
        }

        let stmt = try prepare(sql)
        defer { stmt.reset() }

        var bindIndex: Int32 = 1
        for param in params {
            try stmt.bindText(param, at: bindIndex)
            bindIndex += 1
        }

        @inline(__always)
        func lowerASCII(_ b: UInt8) -> UInt8 {
            if b >= 65 && b <= 90 { return b | 0x20 }
            return b
        }

        func instrASCIIInsensitiveUTF8(
            haystack: (ptr: UnsafePointer<UInt8>, length: Int)?,
            needleLower: [UInt8]
        ) -> (pos: Int, lengthIfNoMatch: Int) {
            guard let haystack else { return (pos: 0, lengthIfNoMatch: 0) }
            guard !needleLower.isEmpty else { return (pos: 1, lengthIfNoMatch: 0) }

            let n0 = needleLower[0]
            let n1 = (needleLower.count >= 2) ? needleLower[1] : 0

            var i = 0
            var codepointPos = 1
            var prevLower: UInt8? = nil
            var prevPos = 0

            while i < haystack.length {
                let byte = haystack.ptr[i]
                if byte < 128 {
                    let lower = lowerASCII(byte)

                    if needleLower.count == 1 {
                        if lower == n0 { return (pos: codepointPos, lengthIfNoMatch: 0) }
                    } else if let prevLower, prevLower == n0, lower == n1 {
                        return (pos: prevPos, lengthIfNoMatch: 0)
                    }

                    prevLower = lower
                    prevPos = codepointPos

                    i += 1
                    codepointPos += 1
                    continue
                }

                prevLower = nil

                let adv: Int
                switch byte {
                case 0xC0...0xDF: adv = 2
                case 0xE0...0xEF: adv = 3
                case 0xF0...0xF7: adv = 4
                default: adv = 1
                }

                i += adv
                codepointPos += 1
            }

            return (pos: 0, lengthIfNoMatch: codepointPos - 1)
        }

        struct CandidateHit {
            let idString: String
            let lastUsedAt: Double
            let isPinned: Bool
            let matchPos: Int
        }

        let keepCount = offset + limit + 1

        @inline(__always)
        func isBetter(_ lhs: CandidateHit, _ rhs: CandidateHit) -> Bool {
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }

            switch sortMode {
            case .recent:
                if lhs.lastUsedAt != rhs.lastUsedAt {
                    return lhs.lastUsedAt > rhs.lastUsedAt
                }
                if lhs.matchPos != rhs.matchPos {
                    return lhs.matchPos < rhs.matchPos
                }
            case .relevance:
                if lhs.matchPos != rhs.matchPos {
                    return lhs.matchPos < rhs.matchPos
                }
                if lhs.lastUsedAt != rhs.lastUsedAt {
                    return lhs.lastUsedAt > rhs.lastUsedAt
                }
            }

            return lhs.idString < rhs.idString
        }

        @inline(__always)
        func isWorse(_ lhs: CandidateHit, _ rhs: CandidateHit) -> Bool {
            isBetter(rhs, lhs)
        }

        var heap: [CandidateHit] = []
        heap.reserveCapacity(min(keepCount, 8192))

        @inline(__always)
        func heapSiftUp(_ startIndex: Int) {
            var childIndex = startIndex
            while childIndex > 0 {
                let parentIndex = (childIndex - 1) / 2
                if !isWorse(heap[childIndex], heap[parentIndex]) {
                    break
                }
                heap.swapAt(childIndex, parentIndex)
                childIndex = parentIndex
            }
        }

        @inline(__always)
        func heapSiftDown(_ startIndex: Int) {
            var parentIndex = startIndex
            while true {
                let leftIndex = parentIndex * 2 + 1
                if leftIndex >= heap.count { break }
                let rightIndex = leftIndex + 1

                var worstIndex = leftIndex
                if rightIndex < heap.count, isWorse(heap[rightIndex], heap[leftIndex]) {
                    worstIndex = rightIndex
                }

                if !isWorse(heap[worstIndex], heap[parentIndex]) {
                    break
                }
                heap.swapAt(parentIndex, worstIndex)
                parentIndex = worstIndex
            }
        }

        @inline(__always)
        func heapInsertKeepingTopK(_ hit: CandidateHit) {
            if keepCount <= 0 { return }

            if heap.count < keepCount {
                heap.append(hit)
                heapSiftUp(heap.count - 1)
                return
            }

            guard !heap.isEmpty else { return }
            if isBetter(hit, heap[0]) {
                heap[0] = hit
                heapSiftDown(0)
            }
        }

        while try stmt.step() {
            guard let idString = stmt.columnText(0) else { continue }

            let lastUsedAt = stmt.columnDouble(1)
            let isPinned = stmt.columnInt(2) != 0

            let plainRes = instrASCIIInsensitiveUTF8(
                haystack: stmt.columnTextBytes(3),
                needleLower: needleLowerBytes
            )
            if plainRes.pos > 0 {
                heapInsertKeepingTopK(CandidateHit(idString: idString, lastUsedAt: lastUsedAt, isPinned: isPinned, matchPos: plainRes.pos))
                continue
            }

            let noteRes = instrASCIIInsensitiveUTF8(
                haystack: stmt.columnTextBytes(4),
                needleLower: needleLowerBytes
            )
            guard noteRes.pos > 0 else { continue }

            let matchPos = plainRes.lengthIfNoMatch + 1 + noteRes.pos
            heapInsertKeepingTopK(CandidateHit(idString: idString, lastUsedAt: lastUsedAt, isPinned: isPinned, matchPos: matchPos))
        }

        heap.sort(by: isBetter)

        let start = min(offset, heap.count)
        let end = min(offset + limit + 1, heap.count)
        let pageHits: [CandidateHit] = (start < end) ? Array(heap[start..<end]) : []

        var pageIDs: [UUID] = []
        pageIDs.reserveCapacity(min(pageHits.count, limit + 1))
        for hit in pageHits {
            if let id = UUID(uuidString: hit.idString) {
                pageIDs.append(id)
            }
        }

        let hasMore = heap.count == keepCount
        if hasMore {
            pageIDs.removeLast()
        }

        let items = try fetchItemsByIDs(ids: pageIDs)
        let total = hasMore ? -1 : offset + items.count
        return (items, total, hasMore)
    }

    private func searchWithShortQuerySubstringCandidatesSQL(
        tokenLower: String,
        candidateIDStrings: [String],
        sortMode: SearchSortMode,
        appFilter: String?,
        typeFilter: ClipboardItemType?,
        typeFilters: [ClipboardItemType]?,
        limit: Int,
        offset: Int
    ) throws -> (items: [ClipboardStoredItem], total: Int, hasMore: Bool) {
        let tokenLower = tokenLower.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tokenLower.isEmpty else { return ([], 0, false) }
        guard !candidateIDStrings.isEmpty else { return ([], 0, false) }

        let useLower = tokenLower.canBeConverted(to: .ascii)
        let plainSearchExpr = useLower ? "lower(plain_text)" : "plain_text"
        let noteSearchExpr = useLower ? "lower(coalesce(note, ''))" : "coalesce(note, '')"

        var params: [String] = []
        params.append(buildCandidateIDsJSON(candidateIDStrings))
        params.append(tokenLower)
        params.append(tokenLower)

        var sql = """
            WITH candidates(id) AS (SELECT value FROM json_each(?))
            SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref, file_size_bytes
            FROM (
                SELECT clipboard_items.id, clipboard_items.type, clipboard_items.content_hash, clipboard_items.plain_text, clipboard_items.note, clipboard_items.app_bundle_id, clipboard_items.created_at, clipboard_items.last_used_at,
                       clipboard_items.use_count, clipboard_items.is_pinned, clipboard_items.size_bytes, clipboard_items.storage_ref, clipboard_items.file_size_bytes,
                       instr(\(plainSearchExpr), ?) AS plainPos,
                       instr(\(noteSearchExpr), ?) AS notePos,
                       length(coalesce(plain_text, '')) AS plainLen
                FROM clipboard_items
                JOIN candidates ON clipboard_items.id = candidates.id
                WHERE 1 = 1
        """

        if let appFilter {
            sql += " AND app_bundle_id = ?"
            params.append(appFilter)
        }

        if let typeFilters, !typeFilters.isEmpty {
            let placeholders = typeFilters.map { _ in "?" }.joined(separator: ",")
            sql += " AND type IN (\(placeholders))"
            params.append(contentsOf: typeFilters.map(\.rawValue))
        } else if let typeFilter {
            sql += " AND type = ?"
            params.append(typeFilter.rawValue)
        }

        sql += """
                ) t
            WHERE plainPos > 0 OR notePos > 0
            ORDER BY is_pinned DESC,
        """

        switch sortMode {
        case .recent:
            sql += " last_used_at DESC,"
        case .relevance:
            break
        }

        sql += """
                     CASE
                       WHEN plainPos > 0 THEN plainPos
                       ELSE plainLen + 1 + notePos
                     END ASC,
        """

        if sortMode == .relevance {
            sql += " last_used_at DESC,"
        }

        sql += """
                     id ASC
            LIMIT ? OFFSET ?
        """

        let stmt = try prepare(sql)
        defer { stmt.reset() }

        var bindIndex: Int32 = 1
        for param in params {
            try stmt.bindText(param, at: bindIndex)
            bindIndex += 1
        }
        try stmt.bindInt(limit + 1, at: bindIndex)
        try stmt.bindInt(offset, at: bindIndex + 1)

        var items: [ClipboardStoredItem] = []
        items.reserveCapacity(limit + 1)
        while try stmt.step() {
            items.append(try parseStoredItemSummary(from: stmt))
        }

        let hasMore = items.count > limit
        if hasMore {
            items.removeLast()
        }
        let total = hasMore ? -1 : offset + items.count
        return (items, total, hasMore)
    }

    private func searchWithShortQuerySubstring(
        tokenLower: String,
        sortMode: SearchSortMode,
        appFilter: String?,
        typeFilter: ClipboardItemType?,
        typeFilters: [ClipboardItemType]?,
        limit: Int,
        offset: Int
    ) throws -> (items: [ClipboardStoredItem], total: Int, hasMore: Bool) {
        let tokenLower = tokenLower.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tokenLower.isEmpty else { return ([], 0, false) }
        let useLower = tokenLower.canBeConverted(to: .ascii)
        let plainSearchExpr = useLower ? "lower(plain_text)" : "plain_text"
        let noteSearchExpr = useLower ? "lower(coalesce(note, ''))" : "coalesce(note, '')"

        var params: [String] = []
        var sql = """
            SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref, file_size_bytes
            FROM (
                SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                       use_count, is_pinned, size_bytes, storage_ref, file_size_bytes,
                       instr(\(plainSearchExpr), ?) AS plainPos,
                       instr(\(noteSearchExpr), ?) AS notePos,
                       length(coalesce(plain_text, '')) AS plainLen
                FROM clipboard_items INDEXED BY idx_pinned
                WHERE 1 = 1
        """

        params.append(tokenLower)
        params.append(tokenLower)

        if let appFilter {
            sql += " AND app_bundle_id = ?"
            params.append(appFilter)
        }

        if let typeFilters, !typeFilters.isEmpty {
            let placeholders = typeFilters.map { _ in "?" }.joined(separator: ",")
            sql += " AND type IN (\(placeholders))"
            params.append(contentsOf: typeFilters.map(\.rawValue))
        } else if let typeFilter {
            sql += " AND type = ?"
            params.append(typeFilter.rawValue)
        }

        sql += """
                ) t
            WHERE plainPos > 0 OR notePos > 0
            ORDER BY is_pinned DESC,
        """

        switch sortMode {
        case .recent:
            sql += " last_used_at DESC,"
        case .relevance:
            break
        }

        // Match scoring semantics for short queries:
        // - If match is in note, treat it as occurring after plain_text (plainLen + '\n' + notePos).
        // This preserves the "plain text matches outrank note-only matches" behavior.
        sql += """
                     CASE
                       WHEN plainPos > 0 THEN plainPos
                       ELSE plainLen + 1 + notePos
                     END ASC,
        """

        if sortMode == .relevance {
            sql += " last_used_at DESC,"
        }

        sql += """
                     id ASC
            LIMIT ? OFFSET ?
        """

        let stmt = try prepare(sql)
        defer { stmt.reset() }

        var bindIndex: Int32 = 1
        for param in params {
            try stmt.bindText(param, at: bindIndex)
            bindIndex += 1
        }
        try stmt.bindInt(limit + 1, at: bindIndex)
        try stmt.bindInt(offset, at: bindIndex + 1)

        var items: [ClipboardStoredItem] = []
        items.reserveCapacity(limit + 1)
        while try stmt.step() {
            items.append(try parseStoredItemSummary(from: stmt))
        }

        let hasMore = items.count > limit
        if hasMore {
            items.removeLast()
        }
        let total = hasMore ? -1 : offset + items.count
        return (items, total, hasMore)
    }

    private func escapeForLike(_ token: String) -> String {
        guard !token.isEmpty else { return token }
        var result = ""
        result.reserveCapacity(token.count)
        for ch in token {
            if ch == "\\" || ch == "%" || ch == "_" {
                result.append("\\")
            }
            result.append(ch)
        }
        return result
    }

    private func searchWithSubstringLike(
        tokens: [String],
        sortMode: SearchSortMode,
        appFilter: String?,
        typeFilter: ClipboardItemType?,
        typeFilters: [ClipboardItemType]?,
        limit: Int,
        offset: Int
    ) throws -> (items: [ClipboardStoredItem], total: Int, hasMore: Bool) {
        let tokens = tokens.filter { !$0.isEmpty }
        guard let primary = tokens.first else { return ([], 0, false) }
        let extraTokens = Array(tokens.dropFirst())

        if shouldUseTrigramFTS(tokens: tokens),
           let ftsQuery = buildTrigramFTSQuery(tokens: tokens)
        {
            return try searchWithTrigramFTS(
                ftsQuery: ftsQuery,
                primaryTokenLower: primary,
                sortMode: sortMode,
                appFilter: appFilter,
                typeFilter: typeFilter,
                typeFilters: typeFilters,
                limit: limit,
                offset: offset
            )
        }

        func likePattern(for token: String) -> String {
            "%" + escapeForLike(token) + "%"
        }

        var params: [String] = []
        var sql: String

        switch sortMode {
        case .recent:
            sql = """
                SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                       use_count, is_pinned, size_bytes, storage_ref, file_size_bytes
                FROM clipboard_items INDEXED BY idx_pinned
                WHERE 1 = 1
            """

            if let appFilter {
                sql += " AND app_bundle_id = ?"
                params.append(appFilter)
            }

            if let typeFilters, !typeFilters.isEmpty {
                let placeholders = typeFilters.map { _ in "?" }.joined(separator: ",")
                sql += " AND type IN (\(placeholders))"
                params.append(contentsOf: typeFilters.map(\.rawValue))
            } else if let typeFilter {
                sql += " AND type = ?"
                params.append(typeFilter.rawValue)
            }

            func appendTokenFilter(_ token: String) {
                sql += " AND (plain_text LIKE ? ESCAPE '\\' OR coalesce(note, '') LIKE ? ESCAPE '\\')"
                let pattern = likePattern(for: token)
                params.append(pattern)
                params.append(pattern)
            }

            appendTokenFilter(primary)
            for token in extraTokens {
                appendTokenFilter(token)
            }

            sql += " ORDER BY is_pinned DESC, last_used_at DESC, id ASC"
            sql += " LIMIT ? OFFSET ?"
        case .relevance:
            sql = """
                SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                       use_count, is_pinned, size_bytes, storage_ref, file_size_bytes
                FROM (
                    SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                           use_count, is_pinned, size_bytes, storage_ref, file_size_bytes,
                           instr(lower(plain_text), ?) AS plainPos,
                           instr(lower(coalesce(note, '')), ?) AS notePos
                    FROM clipboard_items INDEXED BY idx_pinned
                    WHERE 1 = 1
            """
            params.append(primary)
            params.append(primary)

            if let appFilter {
                sql += " AND app_bundle_id = ?"
                params.append(appFilter)
            }

            if let typeFilters, !typeFilters.isEmpty {
                let placeholders = typeFilters.map { _ in "?" }.joined(separator: ",")
                sql += " AND type IN (\(placeholders))"
                params.append(contentsOf: typeFilters.map(\.rawValue))
            } else if let typeFilter {
                sql += " AND type = ?"
                params.append(typeFilter.rawValue)
            }

            func appendTokenFilter(_ token: String) {
                sql += " AND (plain_text LIKE ? ESCAPE '\\' OR coalesce(note, '') LIKE ? ESCAPE '\\')"
                let pattern = likePattern(for: token)
                params.append(pattern)
                params.append(pattern)
            }

            appendTokenFilter(primary)
            for token in extraTokens {
                appendTokenFilter(token)
            }

            sql += """
                    ) t
                WHERE plainPos > 0 OR notePos > 0
                ORDER BY is_pinned DESC,
                         CASE
                           WHEN plainPos > 0 AND notePos > 0 THEN CASE WHEN plainPos < notePos THEN plainPos ELSE notePos END
                           WHEN plainPos > 0 THEN plainPos
                           ELSE notePos
                         END ASC,
                         last_used_at DESC,
                         id ASC
                LIMIT ? OFFSET ?
            """
        }

        let stmt = try prepare(sql)
        defer { stmt.reset() }

        var bindIndex: Int32 = 1
        for param in params {
            try stmt.bindText(param, at: bindIndex)
            bindIndex += 1
        }
        try stmt.bindInt(limit + 1, at: bindIndex)
        try stmt.bindInt(offset, at: bindIndex + 1)

        var items: [ClipboardStoredItem] = []
        items.reserveCapacity(limit + 1)
        while try stmt.step() {
            items.append(try parseStoredItemSummary(from: stmt))
        }

        let hasMore = items.count > limit
        if hasMore {
            items.removeLast()
        }
        let total = hasMore ? -1 : offset + items.count
        return (items, total, hasMore)
    }

    private func ftsPrefilterIDs(ftsQuery: String, limit: Int) throws -> [UUID] {
        let sql = """
            SELECT clipboard_items.id
            FROM clipboard_fts
            JOIN clipboard_items ON clipboard_items.rowid = clipboard_fts.rowid
            WHERE clipboard_fts MATCH ?
            ORDER BY clipboard_items.is_pinned DESC, clipboard_items.last_used_at DESC
            LIMIT ?
        """
        let stmt = try prepare(sql)
        defer { stmt.reset() }
        try stmt.bindText(ftsQuery, at: 1)
        try stmt.bindInt(limit, at: 2)

        var ids: [UUID] = []
        ids.reserveCapacity(limit)
        while try stmt.step() {
            guard let idString = stmt.columnText(0),
                  let id = UUID(uuidString: idString) else { continue }
            ids.append(id)
        }
        return ids
    }

    private func parseStoredItemSummary(from stmt: SQLiteStatement) throws -> ClipboardStoredItem {
        guard let idString = stmt.columnText(0),
              let id = UUID(uuidString: idString),
              let typeString = stmt.columnText(1),
              let type = ClipboardItemType(rawValue: typeString),
              let contentHash = stmt.columnText(2) else {
            throw SearchError.searchFailed("Failed to parse item")
        }

        let plainText = stmt.columnText(3) ?? ""
        let note = stmt.columnText(4)
        let appBundleID = stmt.columnText(5)
        let createdAt = Date(timeIntervalSince1970: stmt.columnDouble(6))
        let lastUsedAt = Date(timeIntervalSince1970: stmt.columnDouble(7))
        let useCount = stmt.columnInt(8)
        let isPinned = stmt.columnInt(9) != 0
        let sizeBytes = stmt.columnInt(10)
        let storageRef = stmt.columnText(11)
        let fileSizeBytes = stmt.columnIntOptional(12)

        return ClipboardStoredItem(
            id: id,
            type: type,
            contentHash: contentHash,
            plainText: plainText,
            note: note,
            appBundleID: appBundleID,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            useCount: useCount,
            isPinned: isPinned,
            sizeBytes: sizeBytes,
            fileSizeBytes: fileSizeBytes,
            storageRef: storageRef,
            rawData: nil
        )
    }

    // MARK: - Index Change Tracking

    private func markIndexChanged() {
        fullIndexGeneration &+= 1
        fuzzySortedMatchesCache = nil
    }

#if DEBUG
    func debugFullIndexHealth() -> (isBuilt: Bool, isStale: Bool, slots: Int, tombstones: Int) {
        guard let index = fullIndex else {
            return (false, fullIndexStale, 0, 0)
        }
        return (true, fullIndexStale, index.items.count, index.tombstoneCount)
    }

    func debugFullIndexLastSnapshotSource() -> String? {
        debugFullIndexLastSnapshotSourceValue?.rawValue
    }

    func debugFullIndexBuildHealth() -> (isBuilding: Bool, pendingEvents: Int) {
        let isBuilding = fullIndexBuildTask != nil
        return (isBuilding, fullIndexPendingEvents.count)
    }

    func debugCancelFullIndexBuild() {
        fullIndexBuildTask?.cancel()
    }

    func debugFullIndexDiskCachePaths() -> (cachePath: String, checksumPath: String) {
        (
            cachePath: Self.fullIndexDiskCachePath(dbPath: dbPath),
            checksumPath: Self.fullIndexDiskCacheChecksumPath(dbPath: dbPath)
        )
    }

    func debugShortQueryIndexDiskCachePaths() -> (cachePath: String, checksumPath: String) {
        (
            cachePath: Self.shortQueryIndexDiskCachePath(dbPath: dbPath),
            checksumPath: Self.shortQueryIndexDiskCacheChecksumPath(dbPath: dbPath)
        )
    }

    func debugStartFullIndexBuild(force: Bool = true) {
        startFullIndexBuildIfNeeded(force: force)
    }

    func debugAwaitFullIndexBuild() async {
        if let task = fullIndexBuildTask {
            await task.value
        }
    }

    func debugShortQueryIndexHealth() -> (isBuilt: Bool, isBuilding: Bool) {
        let isBuilt = shortQueryIndex != nil
        let isBuilding = shortQueryIndexBuildTask != nil
        return (isBuilt, isBuilding)
    }

    func debugShortQueryIndexStats() -> (isBuilt: Bool, isBuilding: Bool, slots: Int, live: Int, tombstones: Int) {
        let isBuilding = shortQueryIndexBuildTask != nil
        guard let index = shortQueryIndex else {
            return (false, isBuilding, 0, 0, 0)
        }
        let stats = index.healthStats()
        return (true, isBuilding, stats.slots, stats.live, stats.tombstones)
    }

    func debugShortQueryIndexLastSnapshotSource() -> String? {
        debugShortQueryIndexLastSnapshotSourceValue?.rawValue
    }

    func debugStartShortQueryIndexBuild(force: Bool = true) {
        startShortQueryIndexBuildIfNeeded(force: force)
    }

    func debugAwaitShortQueryIndexBuild() async {
        if let task = shortQueryIndexBuildTask {
            await task.value
        }
    }
    #endif
}
