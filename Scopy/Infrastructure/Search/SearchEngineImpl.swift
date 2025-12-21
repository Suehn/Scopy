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
        public let searchTimeMs: Double
    }

    private struct SQLiteInterruptHandle: @unchecked Sendable {
        let handle: OpaquePointer
    }

    private struct IndexedItem {
        let id: UUID
        let type: ClipboardItemType
        let contentHash: String
        let plainTextLower: String
        let plainTextLowerIsASCII: Bool
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
            let lower = item.plainText.lowercased()
            self.plainTextLower = lower
            self.plainTextLowerIsASCII = lower.canBeConverted(to: .ascii)
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

    private var recentItemsCache: [ClipboardStoredItem] = []
    private var cacheTimestamp: Date = .distantPast
    private let cacheDuration: TimeInterval = 30.0
    private let shortQueryCacheSize = 2000

    private var fullIndex: FullFuzzyIndex?
    private var fullIndexStale = true
    private var fullIndexGeneration: UInt64 = 0

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
        connection?.close()
        connection = nil
    }

    // MARK: - Cache / Index Updates

    public func invalidateCache() {
        resetRecentCache()
        resetFullIndex()
    }

    func handleUpsertedItem(_ item: ClipboardStoredItem) {
        resetQueryCaches()

        guard var index = fullIndex, !fullIndexStale else { return }
        upsertItemIntoIndex(item, index: &index)
        fullIndex = index
        markIndexChanged()
    }

    func handlePinnedChange(id: UUID, pinned: Bool) {
        resetQueryCaches()

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
            searchTimeMs: elapsedMs
        )
    }

    // MARK: - Search Internals

    private func searchInternal(request: SearchRequest) async throws -> SearchResult {
        try openIfNeeded()
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

        guard let ftsQuery = FTSQueryBuilder.build(userQuery: request.query) else {
            return try searchAllWithFilters(request: request)
        }
        return try searchWithFTS(query: ftsQuery, request: request)
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
        request: SearchRequest
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
        return SearchResult(items: page.items, total: page.total, hasMore: page.hasMore, searchTimeMs: 0)
    }

    // MARK: - Cache Search

    private func searchInCache(
        request: SearchRequest,
        filter: @escaping (ClipboardStoredItem) -> Bool
    ) throws -> SearchResult {
        try refreshCacheIfNeeded()

        var filtered = recentItemsCache.filter(filter)

        if let appFilter = request.appFilter {
            filtered = filtered.filter { $0.appBundleID == appFilter }
        }
        if let typeFilters = request.typeFilters, !typeFilters.isEmpty {
            filtered = filtered.filter { typeFilters.contains($0.type) }
        } else if let typeFilter = request.typeFilter {
            filtered = filtered.filter { $0.type == typeFilter }
        }

        filtered.sort {
            if $0.isPinned != $1.isPinned {
                return $0.isPinned && !$1.isPinned
            }
            return $0.lastUsedAt > $1.lastUsedAt
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
        return SearchResult(items: items, total: total, hasMore: hasMore, searchTimeMs: 0)
    }

    private func refreshCacheIfNeeded() throws {
        let now = Date()
        let needsRefresh = recentItemsCache.isEmpty || now.timeIntervalSince(cacheTimestamp) > cacheDuration
        guard needsRefresh else { return }

        let items = try fetchRecentSummaries(limit: shortQueryCacheSize, offset: 0)
        recentItemsCache = items
        cacheTimestamp = now
    }

    // MARK: - Full-History Fuzzy Search

    private func searchFullFuzzy(request: SearchRequest, mode: SearchMode) async throws -> SearchResult {
        let trimmedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return try searchAllWithFilters(request: request)
        }

        if trimmedQuery.count <= 2 {
            if request.forceFullFuzzy {
                let normalizedRequest = SearchRequest(
                    query: trimmedQuery,
                    mode: mode,
                    sortMode: request.sortMode,
                    appFilter: request.appFilter,
                    typeFilter: request.typeFilter,
                    typeFilters: request.typeFilters,
                    forceFullFuzzy: true,
                    limit: request.limit,
                    offset: request.offset
                )

                let index = try getOrBuildFullIndex()
                return try searchInFullIndex(index: index, request: normalizedRequest, mode: mode)
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

            if request.sortMode == .recent {
                let cached = try searchInCache(request: normalizedRequest) { item in
                    item.plainText.localizedCaseInsensitiveContains(trimmedQuery)
                }

                // Treat short-query cache result as prefilter: it may miss older matches.
                return SearchResult(items: cached.items, total: -1, hasMore: cached.hasMore, searchTimeMs: 0)
            }

            let fullCacheRequest = SearchRequest(
                query: trimmedQuery,
                mode: mode,
                sortMode: request.sortMode,
                appFilter: request.appFilter,
                typeFilter: request.typeFilter,
                typeFilters: request.typeFilters,
                forceFullFuzzy: request.forceFullFuzzy,
                limit: shortQueryCacheSize,
                offset: 0
            )
            let cachedAll = try searchInCache(request: fullCacheRequest) { item in
                item.plainText.localizedCaseInsensitiveContains(trimmedQuery)
            }

            let queryLower = trimmedQuery.lowercased()
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
                let textLower = item.plainText.lowercased()
                let textLowerIsASCII = textLower.canBeConverted(to: .ascii)

                switch mode {
                case .fuzzy:
                    return fuzzyMatchScore(
                        textLower: textLower,
                        textLowerIsASCII: textLowerIsASCII,
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
                            textLowerIsASCII: textLowerIsASCII,
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
            scored.reserveCapacity(cachedAll.items.count)
            for item in cachedAll.items {
                guard let score = score(for: item) else { continue }
                scored.append(ScoredCachedItem(item: item, score: score))
            }

            scored.sort { lhs, rhs in
                if lhs.item.isPinned != rhs.item.isPinned {
                    return lhs.item.isPinned && !rhs.item.isPinned
                }
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if lhs.item.lastUsedAt != rhs.item.lastUsedAt {
                    return lhs.item.lastUsedAt > rhs.item.lastUsedAt
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
            return SearchResult(items: items, total: -1, hasMore: hasMore, searchTimeMs: 0)
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
        return try searchInFullIndex(index: index, request: normalizedRequest, mode: mode)
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
        let storedItems = try fetchAllSummaries()

        var items: [IndexedItem?] = []
        items.reserveCapacity(storedItems.count)

        var idToSlot: [UUID: Int] = [:]
        idToSlot.reserveCapacity(storedItems.count)

        var charPostings: [Character: [Int]] = [:]

        for (idx, stored) in storedItems.enumerated() {
            if idx % 512 == 0 {
                try Task.checkCancellation()
            }

            let indexed = IndexedItem(from: stored)
            let slot = items.count
            items.append(indexed)
            idToSlot[indexed.id] = slot

            for ch in uniqueNonWhitespaceCharacters(indexed.plainTextLower) {
                charPostings[ch, default: []].append(slot)
            }
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
                    return SearchResult(items: [], total: 0, hasMore: false, searchTimeMs: 0)
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
                    textLowerIsASCII: item.plainTextLowerIsASCII,
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
                        textLowerIsASCII: item.plainTextLowerIsASCII,
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
                return SearchResult(items: resultItems, total: -1, hasMore: hasMore, searchTimeMs: 0)
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
            return SearchResult(items: resultItems, total: -1, hasMore: hasMore, searchTimeMs: 0)
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
            return SearchResult(items: resultItems, total: totalMatches, hasMore: hasMore, searchTimeMs: 0)
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
        return SearchResult(items: resultItems, total: total, hasMore: hasMore, searchTimeMs: 0)
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

        for ch in uniqueNonWhitespaceCharacters(indexed.plainTextLower) {
            index.charPostings[ch, default: []].append(slot)
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
        textLowerIsASCII: Bool,
        queryLower: String,
        queryLowerIsASCII: Bool
    ) -> Int? {
        guard !queryLower.isEmpty else { return 0 }

        if queryLower.count <= 2 {
            guard let range = textLower.range(of: queryLower) else { return nil }
            let pos = range.lowerBound.utf16Offset(in: textLower)
            let m = queryLower.utf16.count
            return m * 10 - (m - 1) - pos
        }

        if queryLowerIsASCII,
           textLowerIsASCII,
           let range = textLower.range(of: queryLower) {
            let pos = range.lowerBound.utf16Offset(in: textLower)
            let m = queryLower.utf16.count
            return m * 10 - (m - 1) - pos
        }

        var textIndex = textLower.startIndex
        var firstPos: Int?
        var lastPos = 0
        var gapPenalty = 0
        var matchedCount = 0

        for ch in queryLower {
            guard let found = textLower[textIndex...].firstIndex(of: ch) else { return nil }
            let pos = textLower.distance(from: textLower.startIndex, to: found)
            if firstPos == nil { firstPos = pos }
            gapPenalty += textLower.distance(from: textIndex, to: found)
            matchedCount += 1
            textIndex = textLower.index(after: found)
            lastPos = pos
        }

        let span = firstPos.map { lastPos - $0 } ?? 0
        return matchedCount * 10 - span - gapPenalty
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
        } catch {
            conn.close()
            throw SearchError.searchFailed(error.localizedDescription)
        }

        connection = conn
        statementCache = [:]
        fuzzySortedMatchesCache = nil
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
            SELECT id, type, content_hash, plain_text, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref
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
            SELECT id, type, content_hash, plain_text, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref
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
            SELECT id, type, content_hash, plain_text, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref
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
        return SearchResult(items: page.items, total: page.total, hasMore: page.hasMore, searchTimeMs: 0)
    }

    private func searchAllWithFilters(
        appFilter: String?,
        typeFilter: ClipboardItemType?,
        typeFilters: [ClipboardItemType]?,
        limit: Int,
        offset: Int
    ) throws -> (items: [ClipboardStoredItem], total: Int, hasMore: Bool) {
        var sql = """
            SELECT id, type, content_hash, plain_text, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref
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
                       clipboard_items.app_bundle_id, clipboard_items.created_at, clipboard_items.last_used_at,
                       clipboard_items.use_count, clipboard_items.is_pinned, clipboard_items.size_bytes, clipboard_items.storage_ref
                FROM clipboard_items INDEXED BY idx_pinned
                JOIN clipboard_fts ON clipboard_items.rowid = clipboard_fts.rowid
                WHERE clipboard_fts MATCH ?
            """
        case .recent:
            sql = """
                SELECT id, type, content_hash, plain_text, app_bundle_id, created_at, last_used_at,
                       use_count, is_pinned, size_bytes, storage_ref
                FROM clipboard_items INDEXED BY idx_pinned
                WHERE rowid IN (
                    SELECT rowid
                    FROM clipboard_fts
                    WHERE clipboard_fts MATCH ?
                )
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

    private func ftsPrefilterIDs(ftsQuery: String, limit: Int) throws -> [UUID] {
        let sql = """
            SELECT id
            FROM clipboard_items INDEXED BY idx_pinned
            WHERE rowid IN (
                SELECT rowid
                FROM clipboard_fts
                WHERE clipboard_fts MATCH ?
            )
            ORDER BY is_pinned DESC, last_used_at DESC
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
        let appBundleID = stmt.columnText(4)
        let createdAt = Date(timeIntervalSince1970: stmt.columnDouble(5))
        let lastUsedAt = Date(timeIntervalSince1970: stmt.columnDouble(6))
        let useCount = stmt.columnInt(7)
        let isPinned = stmt.columnInt(8) != 0
        let sizeBytes = stmt.columnInt(9)
        let storageRef = stmt.columnText(10)

        return ClipboardStoredItem(
            id: id,
            type: type,
            contentHash: contentHash,
            plainText: plainText,
            appBundleID: appBundleID,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            useCount: useCount,
            isPinned: isPinned,
            sizeBytes: sizeBytes,
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
