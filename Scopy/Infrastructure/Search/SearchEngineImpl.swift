import Darwin
import Foundation
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

    public struct SearchResult: Sendable {
        public let items: [ClipboardStoredItem]
        public let total: Int
        public let hasMore: Bool
        public let coverage: SearchCoverage
        public let searchTimeMs: Double
        public let perf: SearchPerfMetrics?
        public let matchContexts: [UUID: SearchMatchContext]
        public let mutationSeq: Int64

        public init(
            items: [ClipboardStoredItem],
            total: Int,
            hasMore: Bool,
            coverage: SearchCoverage,
            searchTimeMs: Double,
            perf: SearchPerfMetrics? = nil,
            matchContexts: [UUID: SearchMatchContext] = [:],
            mutationSeq: Int64
        ) {
            self.items = items
            self.total = total
            self.hasMore = hasMore
            self.coverage = coverage
            self.searchTimeMs = searchTimeMs
            self.perf = perf
            self.matchContexts = matchContexts
            self.mutationSeq = mutationSeq
        }

    }

    /// Unversioned only while the synchronous query is inside its owning read transaction.
    struct QueryPage {
        let items: [ClipboardStoredItem]
        let total: Int
        let hasMore: Bool
        let coverage: SearchCoverage
    }

    private struct CachedRecentItem {
        let item: ClipboardStoredItem
        // Exact and regex searches use the original fields. Only the fuzzy fallback needs
        // a second, lowercased copy of each row, and only after its filters admit the row.
        lazy var combinedLower: String = {
            if let note = item.note, !note.isEmpty {
                return (item.plainText + "\n" + note).lowercased()
            }
            return item.plainText.lowercased()
        }()
    }

    // MARK: - Properties

    private let dbPath: String
    private let readStore: SearchReadStore
    private let fullIndexStore: FullIndexStore
    private let shortIndexStore: ShortIndexStore
    /// The read position used to invalidate row and corpus caches. Each index owns its cursor.
    private var knownMutationSeq: Int64?

    private var recentItemsCache: [CachedRecentItem] = []
    private var cacheTimestamp: Date = .distantPast
    private let cacheDuration: TimeInterval = 30.0
    private static let shortQueryCacheSize = 2000

    /// Committed storage changes to apply in order; nil when the engine only reads the database.
    private let commitJournal: StorageCommitJournal?

    /// Indexes and caches built for a search session are released once searching has been idle
    /// this long; the next session loads them back from the disk cache or the database.
    private static let sessionIdleTrimDelay: TimeInterval = 60
    private var activeSearches: [UUID: Task<SearchResult, Error>] = [:]
    private var closeTask: Task<Void, Never>?
    private var lastSearchUptime: TimeInterval = 0
    private var idleTrimTask: Task<Void, Never>?

    private let searchTimeout: TimeInterval
    private let initialIndexBuildTimeout: TimeInterval

    private var corpusMetrics: SearchReadStore.CorpusMetrics?
    private var corpusMetricsUpdatedAt: Date = .distantPast

    // MARK: - Initialization

    public init(dbPath: String) {
        self.init(dbPath: dbPath, searchTimeout: 5.0, commitJournal: nil)
    }

    init(dbPath: String, commitJournal: StorageCommitJournal?) {
        self.init(dbPath: dbPath, searchTimeout: 5.0, commitJournal: commitJournal)
    }

    init(dbPath: String, searchTimeout: TimeInterval, commitJournal: StorageCommitJournal? = nil) {
        self.dbPath = dbPath
        readStore = SearchReadStore(dbPath: dbPath)
        fullIndexStore = FullIndexStore(dbPath: dbPath, warmupMinimumItemCount: Self.shortQueryCacheSize)
        shortIndexStore = ShortIndexStore(dbPath: dbPath, minimumItemCount: Self.shortQueryCacheSize)
        self.searchTimeout = searchTimeout
        self.commitJournal = commitJournal
        initialIndexBuildTimeout = 30.0
    }

    // MARK: - Lifecycle

    public func open() throws {
        try openIfNeeded()
    }

    /// Explicitly prepares the complete one- and two-character search index for callers that
    /// require steady-state readiness before issuing latency-sensitive work.
    public func prepareShortQueryIndex() async throws {
        try openIfNeeded()
        try readStore.withReadSnapshot { mutationSeq in
            _ = synchronizeWithCommittedChanges(through: mutationSeq)
        }
        startShortQueryIndexBuildIfNeeded(force: true)
        if let task = shortIndexStore.buildTask {
            await task.value
        }
        guard shortIndexStore.index != nil else {
            throw SearchError.searchFailed("Failed to prepare short-query index")
        }
    }

    public func close() async {
        if let closeTask {
            await closeTask.value
            return
        }
        let task = Task { await self.finishClose() }
        closeTask = task
        await task.value
    }

    private func finishClose() async {
        defer { closeTask = nil }
        idleTrimTask?.cancel()
        idleTrimTask = nil
        let searches = Array(activeSearches.values)
        searches.forEach { $0.cancel() }
        for task in searches { _ = try? await task.value }
        let builds = fullIndexStore.takeBuildTasksForShutdown() + shortIndexStore.takeBuildTasksForShutdown()
        for task in builds { await task.value }

        scheduleShortQueryIndexDiskCachePersistIfPossible()
        if let task = shortIndexStore.persistTask {
            await task.value
        }
        shortIndexStore.reset()

        scheduleFullIndexDiskCachePersistIfPossible()
        if let task = fullIndexStore.persistTask {
            await task.value
        }

        resetRecentCache()
        fullIndexStore.reset()
        corpusMetrics = nil
        corpusMetricsUpdatedAt = .distantPast
        knownMutationSeq = nil
        readStore.close()
    }

    // MARK: - Cache / Index Updates

    /// Drops this engine's snapshots. Each journal reader keeps its own position.
    public func invalidateCache() {
        resetQueryCaches()
        fullIndexStore.reset()
        shortIndexStore.reset()
        markCorpusMetricsStale()
        knownMutationSeq = nil
    }

    /// Every installed index must reach the query's SQLite snapshot before it can contribute
    /// candidates. A gap discards only that derived index; builds retain their own read positions.
    @discardableResult
    private func synchronizeWithCommittedChanges(through mutationSeq: Int64) -> Bool {
        if knownMutationSeq != mutationSeq {
            resetRecentCache()
            if let knownMutationSeq,
               let changes = committedChanges(after: knownMutationSeq, through: mutationSeq) {
                for entry in changes {
                    switch entry.change {
                    case .upserted(_, let kind):
                        if kind == .inserted || kind == .content { markCorpusMetricsStale() }
                    case .deleted, .clearedUnpinned:
                        markCorpusMetricsStale()
                    case .storageSizesUpdated:
                        break
                    }
                }
            } else {
                markCorpusMetricsStale()
            }
            knownMutationSeq = mutationSeq
        }

        var fullSnapshotRequired = false
        if let cursor = fullIndexStore.mutationSeq, cursor != mutationSeq {
            if let changes = committedChanges(after: cursor, through: mutationSeq) {
                for entry in changes { fullIndexStore.apply(entry) }
            } else {
                fullIndexStore.reset()
                fullSnapshotRequired = true
            }
        }
        if let cursor = shortIndexStore.mutationSeq, cursor != mutationSeq {
            if let changes = committedChanges(after: cursor, through: mutationSeq) {
                for entry in changes { shortIndexStore.apply(entry) }
            } else {
                shortIndexStore.reset()
            }
        }
        if fullIndexStore.index != nil, fullIndexStore.isStale {
            startFullIndexBuildIfNeeded(force: true)
        }
        startShortQueryIndexBuildIfNeeded()
        return fullSnapshotRequired
    }

    private func committedChanges(after cursor: Int64, through mutationSeq: Int64) -> [StorageCommitJournal.Entry]? {
        if cursor == mutationSeq { return [] }
        guard let commitJournal else { return nil }
        switch commitJournal.read(after: cursor, through: mutationSeq) {
        case .changes(let entries, _): return entries
        case .resnapshotRequired: return nil
        }
    }

    private func resetRecentCache() {
        recentItemsCache = []
        cacheTimestamp = .distantPast
    }

    private func resetQueryCaches() {
        resetRecentCache()
        fullIndexStore.sortedMatchesCache = nil
    }

    // MARK: - Index Builds

    private func startShortQueryIndexBuildIfNeeded(force: Bool = false) {
        guard closeTask == nil else { return }
        shortIndexStore.startBuildIfNeeded(force: force, estimatedCount: corpusMetrics?.itemCount ?? 0) { generation, snapshot in
            await self.finishShortQueryIndexBuild(generation: generation, snapshot: snapshot)
        }
    }

    private func finishShortQueryIndexBuild(generation: UInt64, snapshot: ShortQueryIndexSnapshot?) {
        defer { shortIndexStore.buildFinished(generation: generation) }
        guard shortIndexStore.isCurrentBuild(generation) else { return }
        if shortIndexStore.finishBuild(snapshot: snapshot) {
            scheduleShortQueryIndexDiskCachePersistIfPossible()
        }
    }

    /// The full index is independent of query and filters, so any interactive fuzzy request keeps
    /// one shared warm-up session alive; only leaving the fuzzy-search context ends it.
    private func isInteractiveFullIndexWarmupRequest(_ request: SearchRequest) -> Bool {
        guard request.mode == .fuzzy || request.mode == .fuzzyPlus else { return false }
        return !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func reconcileInteractiveFullIndexWarmup(for request: SearchRequest) {
        guard !isInteractiveFullIndexWarmupRequest(request) else { return }
        fullIndexStore.cancelInteractiveBuild()
    }

    private func startInteractiveFullIndexBuildIfNeeded(for request: SearchRequest) {
        guard isInteractiveFullIndexWarmupRequest(request) else { return }
        startFullIndexBuildIfNeeded(force: false, trigger: .interactive)
    }

    private func startFullIndexBuildIfNeeded(force: Bool = false, trigger: FullIndexStore.BuildTrigger = .forced) {
        guard closeTask == nil else { return }
        fullIndexStore.startBuildIfNeeded(
            force: force,
            trigger: trigger,
            estimatedCount: corpusMetrics?.itemCount ?? 0
        ) { generation, snapshot, metrics in
            await self.finishFullIndexBuild(generation: generation, snapshot: snapshot, warmLoadMetrics: metrics)
        }
    }

    private func finishFullIndexBuild(
        generation: UInt64,
        snapshot: FullIndexSnapshot?,
        warmLoadMetrics: SearchWarmLoadMetrics
    ) {
        defer { fullIndexStore.buildFinished(generation: generation) }
        guard fullIndexStore.isCurrentBuild(generation) else { return }

        if fullIndexStore.finishBuild(snapshot: snapshot, warmLoadMetrics: warmLoadMetrics) {
            scheduleFullIndexDiskCachePersistIfPossible()
        }

        if let snapshot, !warmLoadMetrics.summary.isEmpty {
            ScopyLog.search.debug(
                "Full-index warm-load source=\(snapshot.source.rawValue, privacy: .public) metrics=\(warmLoadMetrics.summary, privacy: .public)"
            )
        }
    }

    // MARK: - Disk Cache Persists

    private func scheduleShortQueryIndexDiskCachePersistIfPossible() {
        shortIndexStore.startPersistIfNeeded {
            await self.finishShortQueryIndexDiskCachePersist()
        }
    }

    private func finishShortQueryIndexDiskCachePersist() {
        shortIndexStore.finishPersist()
    }

    private func scheduleFullIndexDiskCachePersistIfPossible() {
        fullIndexStore.startPersistIfNeeded { persisted in
            await self.finishFullIndexDiskCachePersist(mutationSeq: persisted)
        }
    }

    private func finishFullIndexDiskCachePersist(mutationSeq: Int64?) {
        fullIndexStore.finishPersist(mutationSeq: mutationSeq)
    }

    // MARK: - Session Memory

    enum SessionMemoryTrim: Sendable {
        /// Searching went idle: persist a changed full index, then release it.
        case idle
        /// Memory warning: release without spending memory on a persist.
        case memoryWarning
        /// Critical memory pressure: also drop the short-query index.
        case memoryCritical
    }

    /// Releases per-session search memory. Released indexes come back through the normal
    /// disk-cache load or database build on the next search that needs them.
    func trimSessionMemory(_ trim: SessionMemoryTrim) {
        guard closeTask == nil else { return }
        resetQueryCaches()
        readStore.trimMemory()

        if fullIndexStore.buildTask != nil {
            fullIndexStore.reset()
        } else if fullIndexStore.index != nil {
            if trim == .idle {
                scheduleFullIndexDiskCachePersistIfPossible()
            }
            fullIndexStore.release()
        }
        if trim == .memoryCritical {
            shortIndexStore.reset()
        }
        malloc_zone_pressure_relief(nil, 0)
    }

    /// At most one timer task per session; it trims after the last search has been idle for
    /// `sessionIdleTrimDelay` and no search is running.
    private func armIdleTrim() {
        guard idleTrimTask == nil, closeTask == nil, readStore.isOpen else { return }
        idleTrimTask = Task { [weak self] in
            var delay = Self.sessionIdleTrimDelay
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                guard let remaining = await self.trimIfSessionIdle() else { return }
                delay = remaining
            }
        }
    }

    /// Trims and returns nil once the session is idle; otherwise returns the seconds left to wait.
    private func trimIfSessionIdle() -> TimeInterval? {
        let idle = ProcessInfo.processInfo.systemUptime - lastSearchUptime
        guard activeSearches.isEmpty, idle >= Self.sessionIdleTrimDelay else {
            return max(1, Self.sessionIdleTrimDelay - idle)
        }
        idleTrimTask = nil
        trimSessionMemory(.idle)
        return nil
    }

    // MARK: - Search API

    public func search(request: SearchRequest) async throws -> SearchResult {
        try Task.checkCancellation()
        let startTime = CFAbsoluteTimeGetCurrent()
        let perfContext = SearchPerfContext.metricsEnabled ? SearchPerfContext() : nil
        let searchID = UUID()
        lastSearchUptime = ProcessInfo.processInfo.systemUptime
        defer {
            activeSearches.removeValue(forKey: searchID)
            lastSearchUptime = ProcessInfo.processInfo.systemUptime
            armIdleTrim()
        }

        reconcileInteractiveFullIndexWarmup(for: request)

        let timeout: TimeInterval
        switch request.mode {
        case .fuzzy, .fuzzyPlus:
            timeout = fullIndexStore.usableIndex == nil ? initialIndexBuildTimeout : searchTimeout
        case .exact, .regex:
            timeout = searchTimeout
        }

        try openIfNeeded()
        let task = Task {
            try await withTimeout(timeout: timeout) {
                let rawResult = try await self.searchInternal(request: request, perf: perfContext)
                if let perfContext {
                    return try perfContext.measure("match_evidence") {
                        try SearchMatchContextBuilder.attach(to: rawResult, request: request)
                    }
                }
                return try SearchMatchContextBuilder.attach(to: rawResult, request: request)
            }
        }
        activeSearches[searchID] = task
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        let missingEvidenceCount = request.hasSemanticQuery
            ? max(0, result.items.count - result.matchContexts.count)
            : 0
        perfContext?.addPhase("search_total", ms: elapsedMs)
        perfContext?.addCounter("returned_items", value: result.items.count)
        perfContext?.addCounter("match_evidence_items", value: result.matchContexts.count)
        perfContext?.addCounter("match_evidence_missing_items", value: missingEvidenceCount)
        if missingEvidenceCount > 0 {
            ScopyLog.search.warning(
                "Search retained \(missingEvidenceCount, privacy: .public) result(s) without renderable match evidence"
            )
        }
        return SearchResult(
            items: result.items,
            total: result.total,
            hasMore: result.hasMore,
            coverage: result.coverage,
            searchTimeMs: elapsedMs,
            perf: perfContext?.snapshot(),
            matchContexts: result.matchContexts,
            mutationSeq: result.mutationSeq
        )
    }

    // MARK: - Search Internals

    private func searchInternal(request: SearchRequest, perf: SearchPerfContext?) async throws -> SearchResult {
        try openIfNeeded()
        var awaitedBuild = false
        while true {
            guard closeTask == nil else { throw SearchError.databaseNotOpen }
            let attempt = try readStore.withReadSnapshot { mutationSeq -> (result: SearchResult?, requiresSnapshot: Bool) in
                let requiresSnapshot: Bool
                if let perf {
                    requiresSnapshot = perf.measure("invalidate_external_db_change") {
                        synchronizeWithCommittedChanges(through: mutationSeq)
                    }
                    perf.measure("refresh_corpus_metrics") { refreshCorpusMetricsIfNeeded() }
                } else {
                    requiresSnapshot = synchronizeWithCommittedChanges(through: mutationSeq)
                    refreshCorpusMetricsIfNeeded()
                }
                try Task.checkCancellation()
                let page: QueryPage?
                switch request.mode {
                case .exact: page = try searchExact(request: request)
                case .fuzzy: page = try searchFuzzy(request: request, perf: perf)
                case .fuzzyPlus: page = try searchFuzzyPlus(request: request, perf: perf)
                case .regex: page = try searchRegex(request: request)
                }
                let result = page.map {
                    SearchResult(items: $0.items, total: $0.total, hasMore: $0.hasMore,
                                 coverage: $0.coverage, searchTimeMs: 0, mutationSeq: mutationSeq)
                }
                return (result, requiresSnapshot)
            }
            if let result = attempt.result { return result }
            if attempt.requiresSnapshot || awaitedBuild {
                // A finite snapshot query makes progress even when writers outpace the bounded
                // journal. It uses the same ranker and hydration transaction as an indexed query.
                return try await FullIndexQuery.readSnapshot(dbPath: dbPath, request: request, perf: perf)
            }
            awaitedBuild = true
            try await prepareFullIndexForSearch(perf: perf)
        }
    }

    private func searchExact(request: SearchRequest) throws -> QueryPage {
        let normalizedQuery = SearchQueryNormalization.normalizedExactQuery(request.query)
        if normalizedQuery.isEmpty {
            return try searchAllWithFilters(request: request)
        }

        if normalizedQuery.count <= 2 {
            return try searchInCache(request: request, coverage: .recentOnly(limit: Self.shortQueryCacheSize)) { item in
                item.plainText.localizedCaseInsensitiveContains(normalizedQuery)
                    || item.note?.localizedCaseInsensitiveContains(normalizedQuery) == true
            }
        }

        guard let ftsQuery = FTSQueryBuilder.build(userQuery: normalizedQuery) else {
            return QueryPage(
                items: [],
                total: 0,
                hasMore: false,
                coverage: .complete
            )
        }

        let fts = try searchWithFTS(query: ftsQuery, request: request, coverage: .complete)
        if fts.items.isEmpty,
           !normalizedQuery.canBeConverted(to: .ascii) {
            let tokens = substringSearchTokens(normalizedQuery)
            if let page = try? readStore.searchSubstring(
                tokens: tokens,
                sortMode: request.sortMode,
                filters: .init(request),
                window: .init(request)
            ), !page.items.isEmpty {
                return QueryPage(items: page.items, total: page.total, hasMore: page.hasMore, coverage: .complete)
            }
        }

        return fts
    }

    private func searchFuzzy(request: SearchRequest, perf: SearchPerfContext?) throws -> QueryPage? {
        if request.query.isEmpty {
            return try searchAllWithFilters(request: request)
        }
        return try searchFullFuzzy(request: request, mode: .fuzzy, perf: perf)
    }

    private func searchFuzzyPlus(request: SearchRequest, perf: SearchPerfContext?) throws -> QueryPage? {
        if request.query.isEmpty {
            return try searchAllWithFilters(request: request)
        }
        return try searchFullFuzzy(request: request, mode: .fuzzyPlus, perf: perf)
    }

    private func searchRegex(request: SearchRequest) throws -> QueryPage {
        guard let regex = try? NSRegularExpression(pattern: request.query, options: [.caseInsensitive]) else {
            throw SearchError.invalidQuery("Invalid regex pattern")
        }

        return try searchInCache(request: request, coverage: .recentOnly(limit: Self.shortQueryCacheSize)) { item in
            if try Self.hasRegexMatch(regex, in: item.plainText) {
                return true
            }
            return try item.note.map { try Self.hasRegexMatch(regex, in: $0) } ?? false
        }
    }

    private static func hasRegexMatch(
        _ regex: NSRegularExpression,
        in text: String
    ) throws -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        var found = false
        var cancellationError: Error?

        regex.enumerateMatches(
            in: text,
            options: [.reportProgress],
            range: range
        ) { match, _, stop in
            do {
                try Task.checkCancellation()
            } catch {
                cancellationError = error
                stop.pointee = true
                return
            }
            if match != nil {
                found = true
                stop.pointee = true
            }
        }

        if let cancellationError { throw cancellationError }
        try Task.checkCancellation()
        return found
    }

    // MARK: - FTS

    private func searchWithFTS(
        query: String,
        request: SearchRequest,
        coverage: SearchCoverage
    ) throws -> QueryPage {
        let page = try readStore.searchFTS(
            ftsQuery: query,
            sortMode: request.sortMode,
            filters: .init(request),
            window: .init(request)
        )
        return QueryPage(items: page.items, total: page.total, hasMore: page.hasMore, coverage: coverage)
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
        SearchQueryNormalization.fuzzyPlusTokens(queryLower)
    }

    private func shouldUseSubstringOnlyFallbackForFuzzyPlus(tokens: [String]) -> Bool {
        SearchQueryNormalization.shouldUseSubstringOnlyFallbackForFuzzyPlus(tokens: tokens)
    }

    // MARK: - Cache Search

    private func searchInCache(
        request: SearchRequest,
        coverage: SearchCoverage,
        filter: @escaping (ClipboardStoredItem) throws -> Bool
    ) throws -> QueryPage {
        try refreshCacheIfNeeded()

        var filtered: [ClipboardStoredItem] = []
        filtered.reserveCapacity(min(recentItemsCache.count, request.limit + 1))

        for cached in recentItemsCache {
            try Task.checkCancellation()
            let item = cached.item
            if try !filter(item) { continue }

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
        return QueryPage(items: items, total: total, hasMore: hasMore, coverage: coverage)
    }

    private func makeQueryPage(
        items: [ClipboardStoredItem],
        total: Int,
        hasMore: Bool,
        coverage: SearchCoverage = .complete
    ) -> QueryPage {
        QueryPage(items: items, total: total, hasMore: hasMore, coverage: coverage)
    }

    private func makeQueryPage(
        page: SearchReadStore.Page,
        coverage: SearchCoverage = .complete
    ) -> QueryPage {
        makeQueryPage(items: page.items, total: page.total, hasMore: page.hasMore, coverage: coverage)
    }

    private func refreshCacheIfNeeded() throws {
        let now = Date()
        let needsRefresh = recentItemsCache.isEmpty || now.timeIntervalSince(cacheTimestamp) > cacheDuration
        guard needsRefresh else { return }

        let items = try readStore.fetchRecentSummaries(limit: Self.shortQueryCacheSize, offset: 0)
        recentItemsCache = items.map { CachedRecentItem(item: $0) }
        cacheTimestamp = now
    }

    // MARK: - Full-History Fuzzy Search

    private func searchFullFuzzy(request: SearchRequest, mode: SearchMode, perf: SearchPerfContext?) throws -> QueryPage? {
        let trimmedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return try searchAllWithFilters(request: request)
        }

        // If fuzzyPlus query consists of long ASCII tokens (>= 3), the match semantics are substring-only.
        // For the "full scan" stage, use SQL substring search directly to avoid expensive full-history scoring.
        if let forcedFallback = try searchForcedFuzzyPlusSubstringFallbackIfNeeded(
            request: request,
            trimmedQuery: trimmedQuery,
            mode: mode
        ) {
            return forcedFallback
        }

        if let prefilter = try searchInteractiveFuzzyPrefilterIfNeeded(
            request: request,
            trimmedQuery: trimmedQuery,
            mode: mode,
            perf: perf
        ) {
            return prefilter
        }

        if trimmedQuery.count <= 2 {
            return try searchShortFuzzyQuery(
                request: request,
                trimmedQuery: trimmedQuery,
                mode: mode,
                perf: perf
            )
        }

        let normalizedRequest = normalizedSearchRequest(for: request, trimmedQuery: trimmedQuery, mode: mode)

        guard let index = fullIndexStore.usableIndex else { return nil }
        perf?.addCounter("full_index_source_memory", value: 1)
        return try searchInFullIndex(index: index, request: normalizedRequest, mode: mode, perf: perf)
    }

    private func searchForcedFuzzyPlusSubstringFallbackIfNeeded(
        request: SearchRequest,
        trimmedQuery: String,
        mode: SearchMode
    ) throws -> QueryPage? {
        guard request.forceFullFuzzy, mode == .fuzzyPlus else { return nil }
        let tokens = fuzzyPlusTokens(trimmedQuery.lowercased())
        guard shouldUseSubstringOnlyFallbackForFuzzyPlus(tokens: tokens) else { return nil }
        let page = try readStore.searchTrigram(
            tokens: tokens,
            sortMode: request.sortMode,
            filters: .init(request),
            window: .init(request)
        )
        return QueryPage(items: page.items, total: page.total, hasMore: page.hasMore, coverage: .complete)
    }

    private func searchInteractiveFuzzyPrefilterIfNeeded(
        request: SearchRequest,
        trimmedQuery: String,
        mode: SearchMode,
        perf: SearchPerfContext?
    ) throws -> QueryPage? {
        guard !request.forceFullFuzzy,
              trimmedQuery.count >= 3,
              shouldPreferFTSForFuzzy(query: trimmedQuery),
              let ftsQuery = FTSQueryBuilder.build(userQuery: trimmedQuery)
        else {
            return nil
        }

        if let fts = try searchInteractiveFTSPrefilter(request: request, ftsQuery: ftsQuery, perf: perf) {
            return fts
        }

        if let substringFallback = try searchInteractiveFuzzyPlusSubstringFallback(
            request: request,
            trimmedQuery: trimmedQuery,
            mode: mode,
            perf: perf
        ) {
            return substringFallback
        }

        if let substringFallback = try searchInteractiveNonASCIISubstringFallback(
            request: request,
            trimmedQuery: trimmedQuery,
            perf: perf
        ) {
            return substringFallback
        }

        if let cacheFallback = try searchInteractiveRecentCacheFallback(
            request: request,
            trimmedQuery: trimmedQuery,
            mode: mode
        ) {
            return cacheFallback
        }

        // Keep the initial (non-forceFullFuzzy) stage fast: even if no prefilter match is found,
        // return an empty prefilter result quickly and allow UI to refine with a full scan.
        return QueryPage(items: [], total: 0, hasMore: false, coverage: .stagedRefine)
    }

    private func searchInteractiveFTSPrefilter(
        request: SearchRequest,
        ftsQuery: String,
        perf: SearchPerfContext?
    ) throws -> QueryPage? {
        let fts: QueryPage
        if let perf {
            fts = try perf.measure("fts_prefilter") {
                try searchWithFTS(query: ftsQuery, request: request, coverage: .stagedRefine)
            }
        } else {
            fts = try searchWithFTS(query: ftsQuery, request: request, coverage: .stagedRefine)
        }

        guard !fts.items.isEmpty else { return nil }
        startInteractiveFullIndexBuildIfNeeded(for: request)
        perf?.addCounter("fts_prefilter_items", value: fts.items.count)
        return fts
    }

    private func searchInteractiveFuzzyPlusSubstringFallback(
        request: SearchRequest,
        trimmedQuery: String,
        mode: SearchMode,
        perf: SearchPerfContext?
    ) throws -> QueryPage? {
        guard mode == .fuzzyPlus else { return nil }

        let tokens = fuzzyPlusTokens(trimmedQuery.lowercased())
        guard shouldUseSubstringOnlyFallbackForFuzzyPlus(tokens: tokens) else { return nil }

        let page: SearchReadStore.Page
        if let perf {
            page = try perf.measure("sql_substring_only_fallback") {
                try readStore.searchTrigram(
                    tokens: tokens,
                    sortMode: request.sortMode,
                    filters: .init(request),
                    window: .init(request)
                )
            }
        } else {
            page = try readStore.searchTrigram(
                tokens: tokens,
                sortMode: request.sortMode,
                filters: .init(request),
                window: .init(request)
            )
        }
        return makeQueryPage(page: page)
    }

    private func searchInteractiveNonASCIISubstringFallback(
        request: SearchRequest,
        trimmedQuery: String,
        perf: SearchPerfContext?
    ) throws -> QueryPage? {
        guard !trimmedQuery.canBeConverted(to: .ascii) else { return nil }

        let tokens = substringSearchTokens(trimmedQuery)
        let page: SearchReadStore.Page?
        if let perf {
            page = try? perf.measure("sql_substring_fallback_non_ascii") {
                try readStore.searchSubstring(
                    tokens: tokens,
                    sortMode: request.sortMode,
                    filters: .init(request),
                    window: .init(request)
                )
            }
        } else {
            page = try? readStore.searchSubstring(
                tokens: tokens,
                sortMode: request.sortMode,
                filters: .init(request),
                window: .init(request)
            )
        }

        guard let page, !page.items.isEmpty else { return nil }
        startInteractiveFullIndexBuildIfNeeded(for: request)
        perf?.addCounter("substring_fallback_items", value: page.items.count)
        return makeQueryPage(page: page, coverage: .stagedRefine)
    }

    private func searchInteractiveRecentCacheFallback(
        request: SearchRequest,
        trimmedQuery: String,
        mode: SearchMode
    ) throws -> QueryPage? {
        guard trimmedQuery.count <= 6 else { return nil }
        let fallback = try searchFuzzyInRecentCache(request: request, mode: mode, query: trimmedQuery)
        guard !fallback.items.isEmpty else { return nil }
        startInteractiveFullIndexBuildIfNeeded(for: request)
        return fallback
    }

    private func searchShortFuzzyQuery(
        request: SearchRequest,
        trimmedQuery: String,
        mode: SearchMode,
        perf: SearchPerfContext?
    ) throws -> QueryPage {
        let tokenLower = trimmedQuery.lowercased()

        if let result = try searchShortFuzzyInFullIndexIfReady(
            request: request,
            trimmedQuery: trimmedQuery,
            mode: mode,
            perf: perf
        ) {
            return result
        }

        startShortQueryIndexBuildIfNeeded()

        if let result = try searchShortFuzzyWithShortIndex(
            request: request,
            tokenLower: tokenLower,
            perf: perf
        ) {
            return result
        }

        return try searchShortFuzzyWithSQLFallback(
            request: request,
            tokenLower: tokenLower,
            perf: perf
        )
    }

    private func searchShortFuzzyInFullIndexIfReady(
        request: SearchRequest,
        trimmedQuery: String,
        mode: SearchMode,
        perf: SearchPerfContext?
    ) throws -> QueryPage? {
        guard let index = fullIndexStore.usableIndex else { return nil }

        perf?.addCounter("short_query_path_full_index", value: 1)
        let normalizedRequest = normalizedSearchRequest(for: request, trimmedQuery: trimmedQuery, mode: mode)
        return try searchInFullIndex(index: index, request: normalizedRequest, mode: mode, perf: perf)
    }

    private func searchShortFuzzyWithShortIndex(
        request: SearchRequest,
        tokenLower: String,
        perf: SearchPerfContext?
    ) throws -> QueryPage? {
        let isASCII = tokenLower.canBeConverted(to: .ascii)
        let candidates = isASCII
            ? shortIndexStore.candidateIDStrings(for: tokenLower)
            : shortIndexStore.candidateIDStringsForNonASCIIBigram(tokenLower: tokenLower)
        guard let candidates else { return nil }
        if candidates.isEmpty {
            return makeQueryPage(items: [], total: 0, hasMore: false)
        }
        guard !shouldFallbackFromShortQueryCandidates(candidates.count, sortMode: request.sortMode) else {
            return nil
        }

        perf?.addCounter("short_query_path_short_index", value: 1)
        perf?.addCounter("short_query_short_index_candidates", value: candidates.count)
        let page: SearchReadStore.Page
        if let perf {
            let phase = isASCII ? "short_query_short_index_fetch" : "short_query_short_index_sql_fetch"
            page = try perf.measure(phase) {
                try readStore.searchShortQuerySubstring(
                    tokenLower: tokenLower,
                    candidateIDStrings: candidates,
                    sortMode: request.sortMode,
                    filters: .init(request),
                    window: .init(request)
                )
            }
        } else {
            page = try readStore.searchShortQuerySubstring(
                tokenLower: tokenLower,
                candidateIDStrings: candidates,
                sortMode: request.sortMode,
                filters: .init(request),
                window: .init(request)
            )
        }
        return makeQueryPage(page: page)
    }

    /// Whether a scan of every row beats passing the candidates to SQL, whose id list costs about
    /// 5 ms per 12,000 ids. A recency scan reads only the rows before its page ends, and a
    /// relevance pass the first 4 KB of each row, so a large candidate set saves too little.
    private func shouldFallbackFromShortQueryCandidates(_ candidateCount: Int, sortMode: SearchSortMode) -> Bool {
        guard let itemCount = corpusMetrics?.itemCount, itemCount > 0 else { return false }
        guard candidateCount > 4096 else { return false }
        return Double(candidateCount) / Double(itemCount) > (sortMode == .recent ? 0.1 : 0.5)
    }

    private func searchShortFuzzyWithSQLFallback(
        request: SearchRequest,
        tokenLower: String,
        perf: SearchPerfContext?
    ) throws -> QueryPage {
        perf?.addCounter("short_query_path_sql_scan", value: 1)
        let page: SearchReadStore.Page
        if let perf {
            page = try perf.measure("sql_short_query_scan") {
                try readStore.searchShortQuerySubstring(
                    tokenLower: tokenLower,
                    sortMode: request.sortMode,
                    filters: .init(request),
                    window: .init(request)
                )
            }
        } else {
            page = try readStore.searchShortQuerySubstring(
                tokenLower: tokenLower,
                sortMode: request.sortMode,
                filters: .init(request),
                window: .init(request)
            )
        }
        return makeQueryPage(page: page)
    }

    /// Waits once for the shared cold build without holding a SQLite transaction. Failure,
    /// cancellation by another request, or a journal gap selects a complete snapshot query.
    private func prepareFullIndexForSearch(perf: SearchPerfContext?) async throws {
        try Task.checkCancellation()
        startFullIndexBuildIfNeeded(force: true)
        guard fullIndexStore.buildTask != nil else { return }
        let waitStart = CFAbsoluteTimeGetCurrent()
        try await waitForFullIndexBuild()
        try Task.checkCancellation()
        perf?.addPhase("full_index_build_wait", ms: (CFAbsoluteTimeGetCurrent() - waitStart) * 1000)
        if let perf, let index = fullIndexStore.usableIndex, let metrics = fullIndexStore.lastWarmLoadMetrics {
            perf.addFullIndexLoad(metrics, itemCount: index.items.count)
        }
    }

    /// Waits for the running full-index build to end. Cancellation (including the search
    /// timeout) resumes only this search; the build keeps running for everyone else.
    private func waitForFullIndexBuild() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    fullIndexStore.addBuildWaiter(id, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelFullIndexBuildWait(id) }
        }
    }

    private func cancelFullIndexBuildWait(_ id: UUID) {
        fullIndexStore.removeBuildWaiter(id)?.resume(throwing: CancellationError())
    }

    private func normalizedSearchRequest(for request: SearchRequest, trimmedQuery: String, mode: SearchMode) -> SearchRequest {
        SearchRequest(
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
    }

    private func searchInFullIndex(index: FullFuzzyIndex, request: SearchRequest, mode: SearchMode, perf: SearchPerfContext?) throws -> QueryPage {
        try FullIndexQuery.execute(
            index: index,
            shortIndex: shortIndexStore.index,
            readStore: readStore,
            request: request,
            mode: mode,
            contentGeneration: fullIndexStore.contentGeneration,
            cache: &fullIndexStore.sortedMatchesCache,
            perf: perf
        )
    }

    private func shouldPreferFTSForFuzzy(query: String) -> Bool {
        guard let corpusMetrics else { return false }
        guard !query.isEmpty else { return false }
        return corpusMetrics.isHeavyPlainTextCorpus
    }

    private func searchFuzzyInRecentCache(request: SearchRequest, mode: SearchMode, query: String) throws -> QueryPage {
        try refreshCacheIfNeeded()

        let scorer = FuzzyMatcher.Scorer(queryLower: query.lowercased(), mode: mode)

        var scored: [(item: ClipboardStoredItem, key: SearchRankKey)] = []
        scored.reserveCapacity(min(recentItemsCache.count, Self.shortQueryCacheSize))

        for index in recentItemsCache.indices {
            try Task.checkCancellation()
            let item = recentItemsCache[index].item
            if let appFilter = request.appFilter, item.appBundleID != appFilter { continue }
            if let typeFilters = request.typeFilters, !typeFilters.isEmpty {
                if !typeFilters.contains(item.type) { continue }
            } else if let typeFilter = request.typeFilter {
                if item.type != typeFilter { continue }
            }

            guard let score = scorer.score(textLower: recentItemsCache[index].combinedLower) else { continue }
            scored.append((item: item, key: SearchRankKey(item: item, score: score)))
        }

        scored.sort { SearchRankKey.isBetter($0.key, than: $1.key, sortMode: request.sortMode) }

        let totalMatches = scored.count
        let start = min(request.offset, totalMatches)
        let end = min(start + request.limit + 1, totalMatches)
        var page = (start < end) ? Array(scored[start..<end]) : []

        let hasMore = page.count > request.limit
        if hasMore {
            page.removeLast()
        }

        let items = page.map(\.item)
        return QueryPage(items: items, total: -1, hasMore: hasMore, coverage: .stagedRefine)
    }

    // MARK: - Timeout

    /// Deadline arbitration must run outside the engine actor: the work can hold that actor in
    /// sqlite3_step, whose progress callback exits when this group cancels its task.
    private nonisolated func withTimeout<T: Sendable>(
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
                try Task.checkCancellation()
                return value
            } catch {
                group.cancelAll()
                try Task.checkCancellation()
                throw error
            }
        }
    }

    // MARK: - DB Access

    private func openIfNeeded() throws {
        guard closeTask == nil else { throw SearchError.databaseNotOpen }
        guard !readStore.isOpen else { return }
        try readStore.open()
        fullIndexStore.sortedMatchesCache = nil
        SearchIndexDiskCache.removeStaleCacheFiles(dbPath: dbPath)
        refreshCorpusMetricsIfNeeded(force: true)
        knownMutationSeq = nil
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

        if let metrics = try? readStore.corpusMetrics() {
            corpusMetrics = metrics
        }
        corpusMetricsUpdatedAt = Date()
    }

    private func searchAllWithFilters(request: SearchRequest) throws -> QueryPage {
        let page = try readStore.fetchAll(filters: .init(request), window: .init(request))
        return QueryPage(items: page.items, total: page.total, hasMore: page.hasMore, coverage: .complete)
    }

#if DEBUG
    /// Installs completed database snapshots at a controlled point relative to committed writes.
    func installIndexSnapshotsForTesting(full: FullIndexSnapshot?, short: ShortQueryIndexSnapshot?) {
        fullIndexStore.reset()
        shortIndexStore.reset()
        if let full {
            _ = fullIndexStore.finishBuild(snapshot: full, warmLoadMetrics: SearchWarmLoadMetrics())
        }
        if let short { _ = shortIndexStore.finishBuild(snapshot: short) }
    }

    func debugFullIndexHealth() -> (isBuilt: Bool, isStale: Bool, slots: Int, tombstones: Int) {
        guard let index = fullIndexStore.index else {
            return (false, fullIndexStore.isStale, 0, 0)
        }
        return (true, fullIndexStore.isStale, index.items.count, index.tombstoneCount)
    }

    func debugFullIndexLastSnapshotSource() -> String? {
        fullIndexStore.lastSnapshotSource?.rawValue
    }

    func debugFullIndexLastDiskCacheLoadReason() -> String? {
        fullIndexStore.lastDiskCacheLoadReason?.rawValue
    }

    func debugFullIndexBuildHealth() -> Bool {
        fullIndexStore.buildTask != nil
    }

    /// Cancels the build task only; its completion still lands through the normal path.
    func debugCancelFullIndexBuild() {
        fullIndexStore.buildTask?.cancel()
    }

    func debugFullIndexDiskCachePaths() -> (cachePath: String, checksumPath: String, metadataPath: String) {
        let paths = SearchIndexDiskCache.fullPaths(dbPath: dbPath)
        return (cachePath: paths.cachePath, checksumPath: paths.checksumPath, metadataPath: paths.metadataPath)
    }

    func debugShortQueryIndexDiskCachePaths() -> (cachePath: String, checksumPath: String) {
        let paths = SearchIndexDiskCache.shortPaths(dbPath: dbPath)
        return (cachePath: paths.cachePath, checksumPath: paths.checksumPath)
    }

    func debugStartFullIndexBuild(force: Bool = true) {
        startFullIndexBuildIfNeeded(force: force)
    }

    func debugFullIndexBuildGeneration() -> UInt64 {
        fullIndexStore.buildGeneration
    }

    func debugAwaitFullIndexBuild() async {
        await fullIndexStore.buildTask?.value
    }

    func debugShortQueryIndexHealth() -> (isBuilt: Bool, isBuilding: Bool) {
        (shortIndexStore.index != nil, shortIndexStore.buildTask != nil)
    }

    func debugShortQueryIndexStats() -> (isBuilt: Bool, isBuilding: Bool, slots: Int, live: Int, tombstones: Int) {
        let isBuilding = shortIndexStore.buildTask != nil
        guard let index = shortIndexStore.index else {
            return (false, isBuilding, 0, 0, 0)
        }
        let stats = index.healthStats()
        return (true, isBuilding, stats.slots, stats.live, stats.tombstones)
    }

    func debugShortQueryIndexLastSnapshotSource() -> String? {
        shortIndexStore.lastSnapshotSource?.rawValue
    }

    func debugStartShortQueryIndexBuild(force: Bool = true) {
        startShortQueryIndexBuildIfNeeded(force: force)
    }

    func debugInstallPendingShortQueryIndexBuild(_ task: Task<Void, Never>) {
        shortIndexStore.installPendingBuild(task)
    }

    func debugAwaitShortQueryIndexBuild() async {
        await shortIndexStore.buildTask?.value
    }
#endif
}
