import Foundation
import SQLite3

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

    public struct SearchResult: Sendable {
        public let items: [ClipboardStoredItem]
        public let total: Int
        public let hasMore: Bool
        public let isPrefilter: Bool
        public let searchTimeMs: Double
    }

    private struct SQLiteInterruptHandle: @unchecked Sendable {
        let handle: OpaquePointer
    }

    private struct CachedRecentItem {
        let item: ClipboardStoredItem
        let plainTextLower: String
    }

    private struct IndexedItem {
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
    }

    private struct FullFuzzyIndex {
        var items: [IndexedItem?]
        var idToSlot: [UUID: Int]
        var charPostings: [Character: [Int]]
        var tombstoneCount: Int
    }

    private struct ShortQueryIndex: Sendable {
        // ASCII-only char index: 128
        private static let asciiCharCount = 128
        // ASCII-only bigram index: 128 * 128
        private static let asciiBigramCount = 128 * 128

        private var slotToIDString: [String?] = []
        private var slotToContentHash: [String] = []
        private var slotToType: [ClipboardItemType] = []
        private var idToSlot: [UUID: Int] = [:]

        private var asciiCharPostings: [[Int]] = Array(repeating: [], count: Self.asciiCharCount)
        // Key: (a << 7) | b
        private var asciiBigramPostings: [UInt16: [Int]] = [:]

        // Scratch stamps to keep postings unique per ingestion pass.
        private var ingestStamp: UInt32 = 1
        private var seenASCIICharStamp: [UInt32] = Array(repeating: 0, count: Self.asciiCharCount)
        private var seenASCIIBigramStamp: [UInt32] = Array(repeating: 0, count: Self.asciiBigramCount)

        // Scratch stamps to deduplicate candidate lists at query time.
        private var candidateStamp: UInt32 = 1
        private var slotCandidateStamp: [UInt32] = []

        init(reserveSlots: Int) {
            let reserve = max(0, reserveSlots)
            slotToIDString.reserveCapacity(reserve)
            slotToContentHash.reserveCapacity(reserve)
            slotToType.reserveCapacity(reserve)
            idToSlot.reserveCapacity(reserve)
            slotCandidateStamp.reserveCapacity(reserve)
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
            if let slot = idToSlot[id],
               slot < slotToIDString.count {
                // For text items, contentHash tracks plain_text changes well; avoid re-ingesting on metadata updates.
                // For non-text items, plain_text may change without affecting contentHash (e.g. "[Image: ...]"); ingest anyway.
                if type != .text || slotToContentHash[slot] != contentHash || slotToType[slot] != type {
                    slotToContentHash[slot] = contentHash
                    slotToType[slot] = type
                    ingestASCII(from: plainText, slot: slot)
                }

                // Note changes do not affect contentHash; always ingest note to avoid false negatives.
                if let note, !note.isEmpty {
                    ingestASCII(from: note, slot: slot)
                }
                return
            }

            let slot = slotToIDString.count
            let idString = id.uuidString
            slotToIDString.append(idString)
            slotToContentHash.append(contentHash)
            slotToType.append(type)
            idToSlot[id] = slot
            slotCandidateStamp.append(0)

            ingestASCII(from: plainText, slot: slot)
            if let note, !note.isEmpty {
                ingestASCII(from: note, slot: slot)
            }
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

        private mutating func ingestASCII(from text: String, slot: Int) {
            guard !text.isEmpty else { return }

            ingestStamp &+= 1
            if ingestStamp == 0 {
                ingestStamp = 1
                seenASCIICharStamp = Array(repeating: 0, count: seenASCIICharStamp.count)
                seenASCIIBigramStamp = Array(repeating: 0, count: seenASCIIBigramStamp.count)
            }

            func lowerASCII(_ b: UInt8) -> UInt8 {
                if b >= 65 && b <= 90 { return b | 0x20 }
                return b
            }

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
    private var knownDataVersion: Int64?

    private var recentItemsCache: [CachedRecentItem] = []
    private var cacheTimestamp: Date = .distantPast
    private let cacheDuration: TimeInterval = 30.0
    private let shortQueryCacheSize = 2000

    private var fullIndex: FullFuzzyIndex?
    private var fullIndexStale = true
    private var fullIndexGeneration: UInt64 = 0

    private var shortQueryIndex: ShortQueryIndex?
    private var shortQueryIndexBuildTask: Task<Void, Never>?
    private var shortQueryIndexBuildGeneration: UInt64 = 0
    private var shortQueryIndexPendingUpserts: [ClipboardStoredItem] = []
    private var shortQueryIndexPendingDeletions: [UUID] = []

    private let fullIndexTombstoneRatioStaleThreshold: Double = 0.25
    private let fullIndexTombstoneMinSlotsForStale: Int = 64
    private let fullIndexTombstoneMinCountForStale: Int = 16

    private struct CachedStatement {
        let sql: String
        let statement: SQLiteStatement
    }

    private var statementCache: [String: CachedStatement] = [:]
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
        let matches: [ScoredSlot] // Already sorted by isBetterSlot
    }

    private var fuzzySortedMatchesCache: FuzzySortedMatchesCacheValue?

    private let searchTimeout: TimeInterval = 5.0
    private let initialIndexBuildTimeout: TimeInterval = 30.0

    private var corpusMetrics: CorpusMetrics?
    private var corpusMetricsUpdatedAt: Date = .distantPast
    private let corpusMetricsRefreshInterval: TimeInterval = 30.0

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

    public func close() {
        statementCache = [:]
        fuzzySortedMatchesCache = nil
        corpusMetrics = nil
        corpusMetricsUpdatedAt = .distantPast
        supportsTrigramFTS = false
        shortQueryIndexBuildTask?.cancel()
        shortQueryIndexBuildTask = nil
        shortQueryIndex = nil
        shortQueryIndexPendingUpserts = []
        shortQueryIndexPendingDeletions = []
        knownDataVersion = nil
        connection?.close()
        connection = nil
    }

    // MARK: - Cache / Index Updates

    public func invalidateCache() {
        resetRecentCache()
        resetFullIndex()
        resetShortQueryIndex()
        markCorpusMetricsStale()
        refreshKnownDataVersionIfPossible()
        startShortQueryIndexBuildIfNeeded()
    }

    func handleUpsertedItem(_ item: ClipboardStoredItem) {
        resetQueryCaches()
        handleShortQueryIndexUpsert(item)
        refreshKnownDataVersionIfPossible()

        var shouldStaleCorpusMetrics = false

        guard var index = fullIndex, !fullIndexStale else {
            // Index not built yet; upserts may change corpus size/shape before first search.
            markCorpusMetricsStale()
            return
        }

        if let slot = index.idToSlot[item.id],
           slot < index.items.count,
           let existing = index.items[slot] {
            let updated = IndexedItem(from: item)
            if existing.plainTextLower != updated.plainTextLower {
                // Text/note changed: corpus length distribution may change.
                shouldStaleCorpusMetrics = true
                fullIndexStale = true
            } else {
                // Metadata-only update: keep index in sync without forcing a rebuild.
                index.items[slot] = updated
            }
        } else {
            // New item: corpus count changes.
            shouldStaleCorpusMetrics = true
            upsertItemIntoIndex(item, index: &index)
        }

        fullIndex = index
        markIndexChanged()

        if shouldStaleCorpusMetrics {
            markCorpusMetricsStale()
        }
    }

    func handlePinnedChange(id: UUID, pinned: Bool) {
        resetQueryCaches()
        refreshKnownDataVersionIfPossible()

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
        markCorpusMetricsStale()
        handleShortQueryIndexDeletion(id: id)
        refreshKnownDataVersionIfPossible()

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

            if shouldMarkFullIndexStaleAfterDeletion(index: index) {
                fullIndexStale = true
            }
        }

        resetQueryCaches()
    }

    func handleClearAll() {
        invalidateCache()
        refreshKnownDataVersionIfPossible()
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
        shortQueryIndex = index
    }

    private func handleShortQueryIndexDeletion(id: UUID) {
        if shortQueryIndexBuildTask != nil {
            shortQueryIndexPendingDeletions.append(id)
            return
        }

        guard var index = shortQueryIndex else { return }
        index.markDeleted(id: id)
        shortQueryIndex = index
    }

    private func startShortQueryIndexBuildIfNeeded() {
        guard shortQueryIndex == nil else { return }
        guard shortQueryIndexBuildTask == nil else { return }

        let estimatedCount = corpusMetrics?.itemCount ?? 0
        guard estimatedCount >= shortQueryCacheSize else { return }

        shortQueryIndexPendingUpserts = []
        shortQueryIndexPendingDeletions = []

        shortQueryIndexBuildGeneration &+= 1
        let generation = shortQueryIndexBuildGeneration
        let reserveSlots = estimatedCount

        shortQueryIndexBuildTask = Task.detached(priority: .utility) { [dbPath] in
            let index = Self.buildShortQueryIndexSnapshot(dbPath: dbPath, reserveSlots: reserveSlots)
            await self.finishShortQueryIndexBuild(generation: generation, index: index)
        }
    }

    private static func buildShortQueryIndexSnapshot(dbPath: String, reserveSlots: Int) -> ShortQueryIndex? {
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

        return Task.isCancelled ? nil : index
    }

    private func finishShortQueryIndexBuild(generation: UInt64, index: ShortQueryIndex?) {
        guard shortQueryIndexBuildGeneration == generation else { return }
        shortQueryIndexBuildTask = nil

        guard var index else { return }

        for id in shortQueryIndexPendingDeletions {
            index.markDeleted(id: id)
        }
        shortQueryIndexPendingDeletions = []

        for item in shortQueryIndexPendingUpserts {
            index.upsert(item)
        }
        shortQueryIndexPendingUpserts = []

        shortQueryIndex = index
    }

    private func fetchDataVersion() throws -> Int64 {
        let stmt = try prepare("PRAGMA data_version")
        defer { stmt.reset() }
        guard try stmt.step() else { return 0 }
        return stmt.columnInt64(0)
    }

    private func refreshKnownDataVersionIfPossible() {
        guard connection != nil else { return }
        if let v = try? fetchDataVersion() {
            knownDataVersion = v
        }
    }

    private func invalidateInMemoryIndexesIfDBChangedExternally() {
        guard connection != nil else { return }
        guard let known = knownDataVersion else {
            refreshKnownDataVersionIfPossible()
            return
        }
        guard let current = try? fetchDataVersion() else { return }
        guard current != known else { return }

        // DB has changed but we haven't observed it through our update callbacks yet.
        // To guarantee "full history" correctness, drop in-memory indexes/caches and fall back to SQL scans.
        resetQueryCaches()
        resetFullIndex()
        resetShortQueryIndex()
        markCorpusMetricsStale()
        knownDataVersion = current
        startShortQueryIndexBuildIfNeeded()
    }

    // MARK: - Search API

    public func search(request: SearchRequest) async throws -> SearchResult {
        let startTime = CFAbsoluteTimeGetCurrent()

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
                    try await self.searchInternal(request: request)
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
        return SearchResult(
            items: result.items,
            total: result.total,
            hasMore: result.hasMore,
            isPrefilter: result.isPrefilter,
            searchTimeMs: elapsedMs
        )
    }

    // MARK: - Search Internals

    private func searchInternal(request: SearchRequest) async throws -> SearchResult {
        try openIfNeeded()
        refreshCorpusMetricsIfNeeded()
        invalidateInMemoryIndexesIfDBChangedExternally()
        try Task.checkCancellation()

        switch request.mode {
        case .exact:
            return try await searchExact(request: request)
        case .fuzzy:
            return try await searchFuzzy(request: request)
        case .fuzzyPlus:
            return try await searchFuzzyPlus(request: request)
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

    private func searchFuzzy(request: SearchRequest) async throws -> SearchResult {
        if request.query.isEmpty {
            return try searchAllWithFilters(request: request)
        }
        return try await searchFullFuzzy(request: request, mode: .fuzzy)
    }

    private func searchFuzzyPlus(request: SearchRequest) async throws -> SearchResult {
        if request.query.isEmpty {
            return try searchAllWithFilters(request: request)
        }
        return try await searchFullFuzzy(request: request, mode: .fuzzyPlus)
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
            CachedRecentItem(item: item, plainTextLower: item.plainText.lowercased())
        }
        cacheTimestamp = now
    }

    // MARK: - Full-History Fuzzy Search

    private func searchFullFuzzy(request: SearchRequest, mode: SearchMode) async throws -> SearchResult {
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
            let fts = try searchWithFTS(query: ftsQuery, request: request, isPrefilter: true)
            if !fts.items.isEmpty { return fts }

            // For fuzzyPlus, long ASCII tokens (>= 3) are required to match contiguously.
            // If FTS yields no matches, use a SQL substring-only fallback to avoid full-history scans,
            // especially for "no result" cases that would otherwise cost O(n * text_length).
            if mode == .fuzzyPlus {
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

            if !trimmedQuery.canBeConverted(to: .ascii) {
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
                    return SearchResult(items: page.items, total: page.total, hasMore: page.hasMore, isPrefilter: true, searchTimeMs: 0)
                }
            }

            if trimmedQuery.count <= 6 {
                let fallback = try searchFuzzyInRecentCache(request: request, mode: mode, query: trimmedQuery)
                if !fallback.items.isEmpty {
                    return fallback
                }
            }

            // Keep the initial (non-forceFullFuzzy) stage fast: even if no prefilter match is found,
            // return an empty prefilter result quickly and allow UI to refine with a full scan.
            return SearchResult(items: [], total: 0, hasMore: false, isPrefilter: true, searchTimeMs: 0)
        }

        if trimmedQuery.count <= 2 {
            // Prefer the in-memory full index if it is already available; otherwise, fall back to a SQL substring scan.
            // This avoids the multi-second "first full scan" penalty on large DBs while keeping match/sort semantics stable.
            if let index = fullIndex, !fullIndexStale {
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
                let result = try searchInFullIndex(index: index, request: normalizedRequest, mode: mode)
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

            if tokenLower.canBeConverted(to: .ascii) {
                startShortQueryIndexBuildIfNeeded()
                if var shortIndex = shortQueryIndex {
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
                        let page = try searchWithShortQuerySubstringCandidates(
                            tokenLower: tokenLower,
                            candidateIDStrings: candidates,
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
            }

            let page = try searchWithShortQuerySubstring(
                tokenLower: tokenLower,
                sortMode: request.sortMode,
                appFilter: request.appFilter,
                typeFilter: request.typeFilter,
                typeFilters: typeFilters,
                limit: request.limit,
                offset: request.offset
            )
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

        let index = try getOrBuildFullIndex()
        let result = try searchInFullIndex(index: index, request: normalizedRequest, mode: mode)
        return SearchResult(
            items: result.items,
            total: result.total,
            hasMore: result.hasMore,
            isPrefilter: result.isPrefilter,
            searchTimeMs: 0
        )
    }

    private func getOrBuildFullIndex() throws -> FullFuzzyIndex {
        if let index = fullIndex, !fullIndexStale {
            return index
        }

        let newIndex = try buildFullIndex()
        fullIndex = newIndex
        fullIndexStale = false
        return newIndex
    }

    private func buildFullIndex() throws -> FullFuzzyIndex {
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

        var charPostings: [Character: [Int]] = [:]
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

            appendSlotToCharPostings(
                text: indexed.plainTextLower,
                slot: slot,
                charPostings: &charPostings,
                seenASCII: &seenASCII,
                seenNonASCII: &seenNonASCII
            )
        }

        return FullFuzzyIndex(items: items, idToSlot: idToSlot, charPostings: charPostings, tombstoneCount: 0)
    }

    private func shouldMarkFullIndexStaleAfterDeletion(index: FullFuzzyIndex) -> Bool {
        guard !fullIndexStale else { return false }
        guard index.items.count >= fullIndexTombstoneMinSlotsForStale else { return false }
        guard index.tombstoneCount >= fullIndexTombstoneMinCountForStale else { return false }

        let ratio = Double(index.tombstoneCount) / Double(index.items.count)
        return ratio >= fullIndexTombstoneRatioStaleThreshold
    }

    private func searchInFullIndex(index: FullFuzzyIndex, request: SearchRequest, mode: SearchMode) throws -> SearchResult {
        let queryLower = request.query.lowercased()
        let queryChars = uniqueNonWhitespaceCharacters(queryLower)

        var candidateSlots: [Int]
        if queryChars.isEmpty {
            candidateSlots = Array(index.items.indices)
        } else {
            var lists: [[Int]] = []
            lists.reserveCapacity(queryChars.count)
            for ch in queryChars {
                guard let list = index.charPostings[ch] else {
                    return SearchResult(items: [], total: 0, hasMore: false, isPrefilter: false, searchTimeMs: 0)
                }
                lists.append(list)
            }
            lists.sort { $0.count < $1.count }

            var candidates = lists[0]
            for list in lists.dropFirst() {
                candidates = intersectSorted(candidates, list)
                if candidates.isEmpty { break }
            }
            candidateSlots = candidates
        }

        let queryLowerIsASCII = queryLower.canBeConverted(to: .ascii)
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

        func computeScore(for item: IndexedItem) -> Int? {
            switch mode {
            case .fuzzy:
                return fuzzyMatchScore(
                    textLower: item.plainTextLower,
                    queryLower: queryLower,
                    queryLowerIsASCII: queryLowerIsASCII
                )
            case .fuzzyPlus:
                var totalScore = 0
                var ok = true
                for wordInfo in plusWords {
                    if wordInfo.isASCII, wordInfo.word.count >= 3 {
                        guard let range = item.plainTextLower.range(of: wordInfo.word) else {
                            ok = false
                            break
                        }
                        let pos = range.lowerBound.utf16Offset(in: item.plainTextLower)
                        let m = wordInfo.word.utf16.count
                        totalScore += m * 10 - (m - 1) - pos
                        continue
                    }

                    guard let s = fuzzyMatchScore(
                        textLower: item.plainTextLower,
                        queryLower: wordInfo.word,
                        queryLowerIsASCII: wordInfo.isASCII
                    ) else {
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
            if let ftsQuery = FTSQueryBuilder.build(userQuery: queryLower),
               let ftsSlots = try? ftsPrefilterSlots(index: index, ftsQuery: ftsQuery, limit: prefilterLimit),
               !ftsSlots.isEmpty {
                let pinnedSlots = candidateSlots.filter { slot in
                    guard slot < index.items.count, let item = index.items[slot] else { return false }
                    return item.isPinned
                }
                var merged = Set(ftsSlots)
                for s in pinnedSlots { merged.insert(s) }
                candidateSlots = Array(merged)
                totalIsUnknown = true
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

                var pageSlots: [Int] = []
                pageSlots.reserveCapacity(request.limit + 1)
                var matchesSeen = 0

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

                let hasMore = pageSlots.count > request.limit
                if hasMore {
                    pageSlots.removeLast()
                }
                let pageIDs = pageSlots.compactMap { index.items[$0]?.id }
                let resultItems = try fetchItemsByIDs(ids: pageIDs)
                return SearchResult(items: resultItems, total: -1, hasMore: hasMore, isPrefilter: true, searchTimeMs: 0)
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

            let hasMore = totalMatches > request.offset + request.limit
            let pageIDs = page.compactMap { index.items[$0.slot]?.id }
            let resultItems = try fetchItemsByIDs(ids: pageIDs)
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

        func pageFromSortedMatches(_ sorted: [ScoredSlot]) throws -> SearchResult {
            let totalMatches = sorted.count
            let start = min(request.offset, totalMatches)
            let end = min(start + request.limit + 1, totalMatches)
            var page: [ScoredSlot] = (start < end) ? Array(sorted[start..<end]) : []

            let hasMore = page.count > request.limit
            if hasMore {
                page.removeLast()
            }

            let pageIDs = page.compactMap { index.items[$0.slot]?.id }
            let resultItems = try fetchItemsByIDs(ids: pageIDs)
            return SearchResult(items: resultItems, total: totalMatches, hasMore: hasMore, isPrefilter: false, searchTimeMs: 0)
        }

        // P0: Stabilize deep paging cost without changing semantics.
        // For non-zero offsets, compute and cache the fully sorted matches once per query/index generation.
        if request.offset > 0 {
            if let cached = fuzzySortedMatchesCache, cached.key == sortedCacheKey {
                return try pageFromSortedMatches(cached.matches)
            }

            var matches: [ScoredSlot] = []
            matches.reserveCapacity(min(candidateSlots.count, 8192))

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
                matches.append(ScoredSlot(slot: slot, score: score))
            }

            matches.sort { isBetterSlot($0, than: $1) }
            fuzzySortedMatchesCache = FuzzySortedMatchesCacheValue(key: sortedCacheKey, matches: matches)
            return try pageFromSortedMatches(matches)
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

        func score(for item: ClipboardStoredItem) -> Int? {
            let combined: String = {
                if let note = item.note, !note.isEmpty {
                    return item.plainText + "\n" + note
                }
                return item.plainText
            }()

            let textLower = combined.lowercased()

            switch mode {
            case .fuzzy:
                return fuzzyMatchScore(
                    textLower: textLower,
                    queryLower: queryLower,
                    queryLowerIsASCII: queryLowerIsASCII
                )
            case .fuzzyPlus:
                var totalScore = 0
                var ok = true
                for wordInfo in plusWords {
                    if wordInfo.isASCII, wordInfo.word.count >= 3 {
                        guard let range = textLower.range(of: wordInfo.word) else {
                            ok = false
                            break
                        }
                        let pos = range.lowerBound.utf16Offset(in: textLower)
                        let m = wordInfo.word.utf16.count
                        totalScore += m * 10 - (m - 1) - pos
                        continue
                    }

                    guard let s = fuzzyMatchScore(
                        textLower: textLower,
                        queryLower: wordInfo.word,
                        queryLowerIsASCII: wordInfo.isASCII
                    ) else {
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

            guard let s = score(for: item) else { continue }
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

    private func upsertItemIntoIndex(_ item: ClipboardStoredItem, index: inout FullFuzzyIndex) {
        if let slot = index.idToSlot[item.id], slot < index.items.count {
            let existing = index.items[slot]
            let indexed = IndexedItem(from: item)
            if existing != nil {
                index.items[slot] = indexed
                return
            }
        }

        let indexed = IndexedItem(from: item)
        let slot = index.items.count
        index.items.append(indexed)
        index.idToSlot[indexed.id] = slot

        appendSlotToCharPostings(
            text: indexed.plainTextLower,
            slot: slot,
            charPostings: &index.charPostings,
            seenASCII: &charPostingsScratchASCII,
            seenNonASCII: &charPostingsScratchNonASCII
        )
    }

    private func appendSlotToCharPostings(
        text: String,
        slot: Int,
        charPostings: inout [Character: [Int]],
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
                    charPostings[ch, default: []].append(slot)
                }
                continue
            }

            if seenNonASCII.insert(ch).inserted {
                charPostings[ch, default: []].append(slot)
            }
        }
    }

    private func uniqueNonWhitespaceCharacters(_ text: String) -> [Character] {
        var seen = Set<Character>()
        var result: [Character] = []
        seen.reserveCapacity(min(text.count, 64))
        result.reserveCapacity(min(text.count, 64))

        for ch in text {
            if ch.isWhitespace { continue }
            if seen.insert(ch).inserted {
                result.append(ch)
            }
        }
        return result
    }

    private func fuzzyMatchScore(
        textLower: String,
        queryLower: String,
        queryLowerIsASCII: Bool
    ) -> Int? {
        guard !queryLower.isEmpty else { return 0 }

        if queryLower.count <= 2 {
            guard let pos = findNeedleUTF16Offset(haystack: textLower, needle: queryLower) else { return nil }
            let m = queryLower.utf16.count
            return m * 10 - (m - 1) - pos
        }

        if queryLowerIsASCII {
            return fuzzyMatchScoreASCIIUTF16(textLower: textLower, queryLower: queryLower)
        }

        // Fuzzy subsequence matching (non-contiguous). Implemented as a single pass to avoid
        // repeated `String.Index` distance computations on large/unicode-heavy texts.
        let queryCount = queryLower.count
        var queryIterator = queryLower.makeIterator()
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

        guard matchedCount == queryCount else { return nil }
        let span = firstPos.map { lastPos - $0 } ?? 0
        return matchedCount * 10 - span - gapPenalty
    }

    private func fuzzyMatchScoreASCIIUTF16(textLower: String, queryLower: String) -> Int? {
        // ASCII-only query: run a single-pass subsequence match on UTF16 code units.
        //
        // Rationale:
        // - Avoids `Character` iteration overhead on very large texts.
        // - Keeps score semantics aligned with the existing gap/span model, and naturally
        //   ranks contiguous matches higher (because span/gapPenalty become smaller).
        let queryUnits = Array(queryLower.utf16)
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

    private func findNeedleUTF16Offset(haystack: String, needle: String) -> Int? {
        guard !needle.isEmpty else { return 0 }

        if !isSafeForFastUTF16Search(needle) {
            guard let range = haystack.range(of: needle) else { return nil }
            return range.lowerBound.utf16Offset(in: haystack)
        }

        let needleUnits = Array(needle.utf16)
        guard let first = needleUnits.first else { return 0 }

        // Hot path: short queries (≤ 2 chars) => needle is tiny in UTF16 as well (most cases).
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
            guard let range = haystack.range(of: needle) else { return nil }
            return range.lowerBound.utf16Offset(in: haystack)
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
        } catch {
            conn.close()
            throw SearchError.searchFailed(error.localizedDescription)
        }

        connection = conn
        statementCache = [:]
        fuzzySortedMatchesCache = nil
        refreshCorpusMetricsIfNeeded(force: true)
        refreshKnownDataVersionIfPossible()
        startShortQueryIndexBuildIfNeeded()
    }

    private func markCorpusMetricsStale() {
        corpusMetricsUpdatedAt = .distantPast
    }

    private func refreshCorpusMetricsIfNeeded(force: Bool = false) {
        let now = Date()
        if !force,
           corpusMetrics != nil,
           now.timeIntervalSince(corpusMetricsUpdatedAt) < corpusMetricsRefreshInterval {
            return
        }

        if let metrics = try? computeCorpusMetrics() {
            corpusMetrics = metrics
        }
        corpusMetricsUpdatedAt = now
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
            return cached.statement
        }

        do {
            let stmt = try connection.prepare(sql)
            if statementCache.count >= statementCacheLimit {
                statementCache = [:]
            }
            statementCache[sql] = CachedStatement(sql: sql, statement: stmt)
            return stmt
        } catch {
            statementCache.removeValue(forKey: sql)
            throw SearchError.searchFailed(error.localizedDescription)
        }
    }

    private func fetchRecentSummaries(limit: Int, offset: Int) throws -> [ClipboardStoredItem] {
        let sql = """
            SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref, file_size_bytes
            FROM clipboard_items
            ORDER BY is_pinned DESC, last_used_at DESC
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

        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref, file_size_bytes
            FROM clipboard_items
            WHERE id IN (\(placeholders))
        """
        let stmt = try prepare(sql)
        defer { stmt.reset() }

        for (index, id) in ids.enumerated() {
            try stmt.bindText(id.uuidString, at: Int32(index + 1))
        }

        var fetched: [UUID: ClipboardStoredItem] = [:]
        fetched.reserveCapacity(ids.count)
        while try stmt.step() {
            let item = try parseStoredItemSummary(from: stmt)
            fetched[item.id] = item
        }

        return ids.compactMap { fetched[$0] }
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

        sql += " ORDER BY is_pinned DESC, last_used_at DESC"
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

        func buildCandidatesJSON(_ ids: [String]) -> String {
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

        let candidatesJSON = buildCandidatesJSON(candidateIDStrings)

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

        var hits: [CandidateHit] = []
        hits.reserveCapacity(min(candidateIDStrings.count, 8192))
        while try stmt.step() {
            guard let idString = stmt.columnText(0) else { continue }

            let lastUsedAt = stmt.columnDouble(1)
            let isPinned = stmt.columnInt(2) != 0

            let plainRes = instrASCIIInsensitiveUTF8(
                haystack: stmt.columnTextBytes(3),
                needleLower: needleLowerBytes
            )
            if plainRes.pos > 0 {
                hits.append(CandidateHit(idString: idString, lastUsedAt: lastUsedAt, isPinned: isPinned, matchPos: plainRes.pos))
                continue
            }

            let noteRes = instrASCIIInsensitiveUTF8(
                haystack: stmt.columnTextBytes(4),
                needleLower: needleLowerBytes
            )
            guard noteRes.pos > 0 else { continue }

            let matchPos = plainRes.lengthIfNoMatch + 1 + noteRes.pos
            hits.append(CandidateHit(idString: idString, lastUsedAt: lastUsedAt, isPinned: isPinned, matchPos: matchPos))
        }

        hits.sort { lhs, rhs in
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

        let start = min(offset, hits.count)
        let end = min(offset + limit + 1, hits.count)
        let pageHits: [CandidateHit] = (start < end) ? Array(hits[start..<end]) : []

        var pageIDs: [UUID] = []
        pageIDs.reserveCapacity(min(pageHits.count, limit + 1))
        for hit in pageHits {
            if let id = UUID(uuidString: hit.idString) {
                pageIDs.append(id)
            }
        }

        let hasMore = pageIDs.count > limit
        if hasMore {
            pageIDs.removeLast()
        }

        let items = try fetchItemsByIDs(ids: pageIDs)
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
    #endif
}
