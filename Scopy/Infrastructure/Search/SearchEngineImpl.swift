import Darwin
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

    public struct SearchResult: Sendable {
        public let items: [ClipboardStoredItem]
        public let total: Int
        public let hasMore: Bool
        public let coverage: SearchCoverage
        public let searchTimeMs: Double
        public let perf: SearchPerfMetrics?
        public let matchContexts: [UUID: SearchMatchContext]

        public init(
            items: [ClipboardStoredItem],
            total: Int,
            hasMore: Bool,
            coverage: SearchCoverage,
            searchTimeMs: Double,
            perf: SearchPerfMetrics? = nil,
            matchContexts: [UUID: SearchMatchContext] = [:]
        ) {
            self.items = items
            self.total = total
            self.hasMore = hasMore
            self.coverage = coverage
            self.searchTimeMs = searchTimeMs
            self.perf = perf
            self.matchContexts = matchContexts
        }

    }

    private struct SQLiteInterruptHandle: @unchecked Sendable {
        let handle: OpaquePointer
    }

    private struct CachedRecentItem {
        let item: ClipboardStoredItem
        let combinedLower: String
    }

    // MARK: - Properties

    private let dbPath: String
    private let readStore: SearchReadStore
    private let fullIndexStore: FullIndexStore
    private let shortIndexStore: ShortIndexStore
    /// The `mutation_seq` the in-memory indexes correspond to.
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
    private var activeSearchCount = 0
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
        startShortQueryIndexBuildIfNeeded(force: true)
        if let task = shortIndexStore.buildTask {
            await task.value
        }
        guard shortIndexStore.index != nil else {
            throw SearchError.searchFailed("Failed to prepare short-query index")
        }
    }

    public func close() async {
        idleTrimTask?.cancel()
        idleTrimTask = nil
        fullIndexStore.cancelBuild()
        shortIndexStore.cancelBuild()

        scheduleShortQueryIndexDiskCachePersistIfPossible()
        if let task = shortIndexStore.persistTask {
            _ = try? await withTimeout(timeout: 0.25) { await task.value }
        }
        shortIndexStore.reset()

        scheduleFullIndexDiskCachePersistIfPossible()
        if let task = fullIndexStore.persistTask {
            _ = try? await withTimeout(timeout: 2.0) { await task.value }
        }

        fullIndexStore.sortedMatchesCache = nil
        corpusMetrics = nil
        corpusMetricsUpdatedAt = .distantPast
        knownMutationSeq = nil
        readStore.close()
    }

    // MARK: - Cache / Index Updates

    /// Drops every in-memory index and resynchronizes from the database; journaled commits up to
    /// that point are covered by the rebuild.
    public func invalidateCache() {
        _ = commitJournal?.drain()
        resetRecentCache()
        fullIndexStore.reset()
        shortIndexStore.reset()
        markCorpusMetricsStale()
        refreshKnownMutationSeqIfPossible()
        startShortQueryIndexBuildIfNeeded()
    }

    /// Applies every storage commit journaled since the last call, in commit order.
    func applyCommittedChanges() {
        synchronizeWithCommittedChanges()
    }

    /// Brings the indexes up to the database. Journaled commits are applied in `mutation_seq`
    /// order; a commit missing from the journal (another process, or an overflowed journal) is a
    /// gap that no in-memory index can reproduce, so every index is reset and rebuilt.
    private func synchronizeWithCommittedChanges() {
        guard readStore.isOpen else { return }
        // Read the database position before draining: every in-process commit up to it has been
        // journaled by then, so a position beyond the journal means an unobserved commit.
        let current = try? readStore.fetchMutationSeq()
        if let commitJournal {
            let drained = commitJournal.drain()
            if drained.overflowed {
                resetIndexesForUnobservedCommits()
                return
            }
            for entry in drained.entries {
                guard let known = knownMutationSeq else {
                    refreshKnownMutationSeqIfPossible()
                    continue
                }
                if entry.mutationSeq <= known { continue }
                guard entry.mutationSeq == known + 1 else {
                    resetIndexesForUnobservedCommits()
                    return
                }
                knownMutationSeq = entry.mutationSeq
                apply(entry.change)
            }
        }
        guard let current else { return }
        guard let known = knownMutationSeq else {
            knownMutationSeq = current
            return
        }
        if known < current {
            resetIndexesForUnobservedCommits()
        }
    }

    private func resetIndexesForUnobservedCommits() {
        resetQueryCaches()
        fullIndexStore.reset()
        shortIndexStore.reset()
        markCorpusMetricsStale()
        refreshKnownMutationSeqIfPossible()
        startShortQueryIndexBuildIfNeeded()
    }

    private func apply(_ change: StorageCommittedChange) {
        switch change {
        case .upserted(let item):
            applyUpsert(item)
        case .pinChanged(let id, let isPinned):
            resetQueryCaches()
            fullIndexStore.applyPinChange(id: id, pinned: isPinned)
        case .deleted(let ids):
            applyDeletions(ids)
        case .clearedUnpinned:
            resetRecentCache()
            fullIndexStore.reset()
            shortIndexStore.reset()
            markCorpusMetricsStale()
            startShortQueryIndexBuildIfNeeded()
        case .unindexedFields:
            break
        }
    }

    private func applyUpsert(_ item: ClipboardStoredItem) {
        resetQueryCaches()
        if shortIndexStore.applyUpsert(item) {
            startShortQueryIndexBuildIfNeeded()
        }
        let full = fullIndexStore.applyUpsert(item)
        if full.needsRebuild {
            startFullIndexBuildIfNeeded(force: true)
        }
        if full.corpusChanged {
            markCorpusMetricsStale()
        }
    }

    /// Tombstones one committed delete set in both indexes, checking the rebuild threshold once.
    private func applyDeletions(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        markCorpusMetricsStale()
        resetQueryCaches()
        if shortIndexStore.applyDeletions(ids) {
            startShortQueryIndexBuildIfNeeded()
        }
        if fullIndexStore.applyDeletions(ids) {
            startFullIndexBuildIfNeeded(force: true)
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
        shortIndexStore.startBuildIfNeeded(force: force, estimatedCount: corpusMetrics?.itemCount ?? 0) { generation, snapshot in
            await self.finishShortQueryIndexBuild(generation: generation, snapshot: snapshot)
        }
    }

    private func finishShortQueryIndexBuild(generation: UInt64, snapshot: ShortQueryIndexSnapshot?) {
        guard shortIndexStore.isCurrentBuild(generation) else { return }
        synchronizeWithCommittedChanges()
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
        guard fullIndexStore.isCurrentBuild(generation) else { return }
        // Collect every commit made during the build as pending events; an unobserved commit
        // resets the indexes, which also supersedes this build.
        synchronizeWithCommittedChanges()
        guard fullIndexStore.isCurrentBuild(generation) else { return }

        switch fullIndexStore.finishBuild(
            snapshot: snapshot,
            warmLoadMetrics: warmLoadMetrics,
            knownMutationSeq: knownMutationSeq
        ) {
        case .none:
            break
        case .persist:
            scheduleFullIndexDiskCachePersistIfPossible()
        case .rebuild:
            startFullIndexBuildIfNeeded(force: true)
        }

        if let snapshot, !warmLoadMetrics.summary.isEmpty {
            ScopyLog.search.debug(
                "Full-index warm-load source=\(snapshot.source.rawValue, privacy: .public) metrics=\(warmLoadMetrics.summary, privacy: .public)"
            )
        }
    }

    // MARK: - Disk Cache Persists

    private func scheduleShortQueryIndexDiskCachePersistIfPossible() {
        guard shortIndexStore.persistTask == nil else { return }
        synchronizeWithCommittedChanges()
        // `knownMutationSeq` is the mutation_seq the in-memory index content corresponds to;
        // stamping the cache with it (rather than re-reading the DB) keeps the two atomic.
        guard let mutationSeq = knownMutationSeq else { return }
        shortIndexStore.startPersistIfNeeded(mutationSeq: mutationSeq) {
            await self.finishShortQueryIndexDiskCachePersist()
        }
    }

    private func finishShortQueryIndexDiskCachePersist() {
        shortIndexStore.finishPersist()
    }

    private func scheduleFullIndexDiskCachePersistIfPossible() {
        guard fullIndexStore.persistTask == nil else { return }
        synchronizeWithCommittedChanges()
        guard let mutationSeq = knownMutationSeq else { return }
        fullIndexStore.startPersistIfNeeded(mutationSeq: mutationSeq) { persisted in
            await self.finishFullIndexDiskCachePersist(mutationSeq: persisted)
        }
    }

    private func finishFullIndexDiskCachePersist(mutationSeq: Int64?) {
        fullIndexStore.finishPersist(mutationSeq: mutationSeq)
    }

    private func refreshKnownMutationSeqIfPossible() {
        guard readStore.isOpen else { return }
        if let v = try? readStore.fetchMutationSeq() {
            knownMutationSeq = v
        }
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
        guard idleTrimTask == nil else { return }
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
        guard activeSearchCount == 0, idle >= Self.sessionIdleTrimDelay else {
            return max(1, Self.sessionIdleTrimDelay - idle)
        }
        idleTrimTask = nil
        trimSessionMemory(.idle)
        return nil
    }

    // MARK: - Search API

    public func search(request: SearchRequest) async throws -> SearchResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let perfContext = SearchPerfContext.metricsEnabled ? SearchPerfContext() : nil
        activeSearchCount += 1
        lastSearchUptime = ProcessInfo.processInfo.systemUptime
        defer {
            activeSearchCount -= 1
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
        let interruptHandle = readStore.connectionHandle.map { SQLiteInterruptHandle(handle: $0) }

        let result = try await withTaskCancellationHandler(operation: {
            try await withTimeout(
                timeout: timeout,
                onTimeout: {
                    if let interruptHandle {
                        sqlite3_interrupt(interruptHandle.handle)
                    }
                }
            ) {
                let rawResult = try await self.searchInternal(
                    request: request,
                    perf: perfContext
                )
                if let perfContext {
                    return try perfContext.measure("match_evidence") {
                        try SearchMatchContextBuilder.attach(to: rawResult, request: request)
                    }
                }
                return try SearchMatchContextBuilder.attach(to: rawResult, request: request)
            }
        }, onCancel: {
            if let interruptHandle {
                sqlite3_interrupt(interruptHandle.handle)
            }
        })

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
            matchContexts: result.matchContexts
        )
    }

    // MARK: - Search Internals

    private func searchInternal(request: SearchRequest, perf: SearchPerfContext?) async throws -> SearchResult {
        try openIfNeeded()
        if let perf {
            perf.measure("refresh_corpus_metrics") { refreshCorpusMetricsIfNeeded() }
        } else {
            refreshCorpusMetricsIfNeeded()
        }

        if let perf {
            perf.measure("invalidate_external_db_change") { synchronizeWithCommittedChanges() }
        } else {
            synchronizeWithCommittedChanges()
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
            return SearchResult(
                items: [],
                total: 0,
                hasMore: false,
                coverage: .complete,
                searchTimeMs: 0
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
                return SearchResult(items: page.items, total: page.total, hasMore: page.hasMore, coverage: .complete, searchTimeMs: 0)
            }
        }

        return fts
    }

    private func searchFuzzy(request: SearchRequest, perf: SearchPerfContext?) async throws -> SearchResult {
        if request.query.isEmpty {
            return try searchAllWithFilters(request: request)
        }
        return try await searchFullFuzzy(request: request, mode: .fuzzy, perf: perf)
    }

    private func searchFuzzyPlus(request: SearchRequest, perf: SearchPerfContext?) async throws -> SearchResult {
        if request.query.isEmpty {
            return try searchAllWithFilters(request: request)
        }
        return try await searchFullFuzzy(request: request, mode: .fuzzyPlus, perf: perf)
    }

    private func searchRegex(request: SearchRequest) async throws -> SearchResult {
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
    ) throws -> SearchResult {
        let page = try readStore.searchFTS(
            ftsQuery: query,
            sortMode: request.sortMode,
            filters: .init(request),
            window: .init(request)
        )
        return SearchResult(items: page.items, total: page.total, hasMore: page.hasMore, coverage: coverage, searchTimeMs: 0)
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
    ) throws -> SearchResult {
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
        return SearchResult(items: items, total: total, hasMore: hasMore, coverage: coverage, searchTimeMs: 0)
    }

    private func makeZeroTimeSearchResult(
        items: [ClipboardStoredItem],
        total: Int,
        hasMore: Bool,
        coverage: SearchCoverage = .complete
    ) -> SearchResult {
        SearchResult(items: items, total: total, hasMore: hasMore, coverage: coverage, searchTimeMs: 0)
    }

    private func makeZeroTimeSearchResult(
        page: SearchReadStore.Page,
        coverage: SearchCoverage = .complete
    ) -> SearchResult {
        makeZeroTimeSearchResult(items: page.items, total: page.total, hasMore: page.hasMore, coverage: coverage)
    }

    private func refreshCacheIfNeeded() throws {
        let now = Date()
        let needsRefresh = recentItemsCache.isEmpty || now.timeIntervalSince(cacheTimestamp) > cacheDuration
        guard needsRefresh else { return }

        let items = try readStore.fetchRecentSummaries(limit: Self.shortQueryCacheSize, offset: 0)
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

    private func searchFullFuzzy(request: SearchRequest, mode: SearchMode, perf: SearchPerfContext?) async throws -> SearchResult {
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

        let index = try await fullIndexForSearch(perf: perf)
        let result = try searchInFullIndex(index: index, request: normalizedRequest, mode: mode, perf: perf)
        return SearchResult(
            items: result.items,
            total: result.total,
            hasMore: result.hasMore,
            coverage: result.coverage,
            searchTimeMs: 0
        )
    }

    private func searchForcedFuzzyPlusSubstringFallbackIfNeeded(
        request: SearchRequest,
        trimmedQuery: String,
        mode: SearchMode
    ) throws -> SearchResult? {
        guard request.forceFullFuzzy, mode == .fuzzyPlus else { return nil }
        let tokens = fuzzyPlusTokens(trimmedQuery.lowercased())
        guard shouldUseSubstringOnlyFallbackForFuzzyPlus(tokens: tokens) else { return nil }
        let page = try readStore.searchTrigram(
            tokens: tokens,
            sortMode: request.sortMode,
            filters: .init(request),
            window: .init(request)
        )
        return SearchResult(items: page.items, total: page.total, hasMore: page.hasMore, coverage: .complete, searchTimeMs: 0)
    }

    private func searchInteractiveFuzzyPrefilterIfNeeded(
        request: SearchRequest,
        trimmedQuery: String,
        mode: SearchMode,
        perf: SearchPerfContext?
    ) throws -> SearchResult? {
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
        return SearchResult(items: [], total: 0, hasMore: false, coverage: .stagedRefine, searchTimeMs: 0)
    }

    private func searchInteractiveFTSPrefilter(
        request: SearchRequest,
        ftsQuery: String,
        perf: SearchPerfContext?
    ) throws -> SearchResult? {
        let fts: SearchResult
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
    ) throws -> SearchResult? {
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
        return makeZeroTimeSearchResult(page: page)
    }

    private func searchInteractiveNonASCIISubstringFallback(
        request: SearchRequest,
        trimmedQuery: String,
        perf: SearchPerfContext?
    ) throws -> SearchResult? {
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
        return makeZeroTimeSearchResult(page: page, coverage: .stagedRefine)
    }

    private func searchInteractiveRecentCacheFallback(
        request: SearchRequest,
        trimmedQuery: String,
        mode: SearchMode
    ) throws -> SearchResult? {
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
    ) throws -> SearchResult {
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
    ) throws -> SearchResult? {
        guard let index = fullIndexStore.usableIndex else { return nil }

        perf?.addCounter("short_query_path_full_index", value: 1)
        let normalizedRequest = normalizedSearchRequest(for: request, trimmedQuery: trimmedQuery, mode: mode)
        let result = try searchInFullIndex(index: index, request: normalizedRequest, mode: mode, perf: perf)
        return makeZeroTimeSearchResult(
            items: result.items,
            total: result.total,
            hasMore: result.hasMore,
            coverage: result.coverage
        )
    }

    private func searchShortFuzzyWithShortIndex(
        request: SearchRequest,
        tokenLower: String,
        perf: SearchPerfContext?
    ) throws -> SearchResult? {
        if tokenLower.canBeConverted(to: .ascii) {
            guard let candidates = shortIndexStore.candidateIDStrings(for: tokenLower) else { return nil }
            return try searchShortFuzzyWithASCIICandidates(
                request: request,
                tokenLower: tokenLower,
                candidateIDStrings: candidates,
                perf: perf
            )
        }

        guard let candidates = shortIndexStore.candidateIDStringsForNonASCIIBigram(tokenLower: tokenLower) else {
            return nil
        }
        return try searchShortFuzzyWithNonASCIICandidates(
            request: request,
            tokenLower: tokenLower,
            candidateIDStrings: candidates,
            perf: perf
        )
    }

    private func searchShortFuzzyWithASCIICandidates(
        request: SearchRequest,
        tokenLower: String,
        candidateIDStrings: [String],
        perf: SearchPerfContext?
    ) throws -> SearchResult? {
        if candidateIDStrings.isEmpty {
            return makeZeroTimeSearchResult(items: [], total: 0, hasMore: false)
        }

        guard !shouldFallbackFromShortQueryCandidates(candidateIDStrings.count) else {
            return nil
        }

        perf?.addCounter("short_query_path_short_index", value: 1)
        perf?.addCounter("short_query_short_index_candidates", value: candidateIDStrings.count)
        let page: SearchReadStore.Page
        if let perf {
            page = try perf.measure("short_query_short_index_fetch") {
                try readStore.searchShortQuerySubstringCandidates(
                    tokenLower: tokenLower,
                    candidateIDStrings: candidateIDStrings,
                    sortMode: request.sortMode,
                    filters: .init(request),
                    window: .init(request)
                )
            }
        } else {
            page = try readStore.searchShortQuerySubstringCandidates(
                tokenLower: tokenLower,
                candidateIDStrings: candidateIDStrings,
                sortMode: request.sortMode,
                filters: .init(request),
                window: .init(request)
            )
        }
        return makeZeroTimeSearchResult(page: page)
    }

    private func searchShortFuzzyWithNonASCIICandidates(
        request: SearchRequest,
        tokenLower: String,
        candidateIDStrings: [String],
        perf: SearchPerfContext?
    ) throws -> SearchResult? {
        if candidateIDStrings.isEmpty {
            return makeZeroTimeSearchResult(items: [], total: 0, hasMore: false)
        }

        guard !shouldFallbackFromShortQueryCandidates(candidateIDStrings.count) else {
            return nil
        }

        perf?.addCounter("short_query_path_short_index", value: 1)
        perf?.addCounter("short_query_short_index_candidates", value: candidateIDStrings.count)
        let page: SearchReadStore.Page
        if let perf {
            page = try perf.measure("short_query_short_index_sql_fetch") {
                try readStore.searchShortQuerySubstringCandidatesSQL(
                    tokenLower: tokenLower,
                    candidateIDStrings: candidateIDStrings,
                    sortMode: request.sortMode,
                    filters: .init(request),
                    window: .init(request)
                )
            }
        } else {
            page = try readStore.searchShortQuerySubstringCandidatesSQL(
                tokenLower: tokenLower,
                candidateIDStrings: candidateIDStrings,
                sortMode: request.sortMode,
                filters: .init(request),
                window: .init(request)
            )
        }
        return makeZeroTimeSearchResult(page: page)
    }

    private func shouldFallbackFromShortQueryCandidates(_ candidateCount: Int) -> Bool {
        guard let itemCount = corpusMetrics?.itemCount, itemCount > 0 else { return false }
        guard candidateCount > 4096 else { return false }
        return Double(candidateCount) / Double(itemCount) > 0.85
    }

    private func searchShortFuzzyWithSQLFallback(
        request: SearchRequest,
        tokenLower: String,
        perf: SearchPerfContext?
    ) throws -> SearchResult {
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
        return makeZeroTimeSearchResult(page: page)
    }

    /// The usable full index, awaiting a detached build (disk cache, then database) when there
    /// is none; the engine actor stays free for other searches while the build runs.
    private func fullIndexForSearch(perf: SearchPerfContext?) async throws -> FullFuzzyIndex {
        if let index = fullIndexStore.usableIndex {
            perf?.addCounter("full_index_source_memory", value: 1)
            return index
        }

        while true {
            try Task.checkCancellation()
            startFullIndexBuildIfNeeded(force: true)
            guard fullIndexStore.buildTask != nil else {
                throw SearchError.searchFailed("Failed to start the full index build")
            }
            let generation = fullIndexStore.buildGeneration
            let waitStart = CFAbsoluteTimeGetCurrent()
            try await waitForFullIndexBuild()
            perf?.addPhase("full_index_build_wait", ms: (CFAbsoluteTimeGetCurrent() - waitStart) * 1000)

            if let index = fullIndexStore.usableIndex {
                if let perf, let metrics = fullIndexStore.lastWarmLoadMetrics {
                    perf.addFullIndexLoad(metrics, itemCount: index.items.count)
                }
                return index
            }
            // A build that ran to completion without an index failed; a superseded one (a reset
            // or a tombstone rebuild moved the generation on) is retried.
            guard fullIndexStore.buildGeneration != generation else {
                throw SearchError.searchFailed("Failed to build the full index")
            }
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

    private func searchInFullIndex(index: FullFuzzyIndex, request: SearchRequest, mode: SearchMode, perf: SearchPerfContext?) throws -> SearchResult {
        let queryLower = request.query.lowercased()

        var candidateSlots: [Int]
        if let perf {
            candidateSlots = perf.measure("full_index_candidate_intersection") {
                FullIndexRanker.candidateSlots(index: index, queryLower: queryLower)
            }
        } else {
            candidateSlots = FullIndexRanker.candidateSlots(index: index, queryLower: queryLower)
        }

        if candidateSlots.isEmpty {
            return SearchResult(items: [], total: 0, hasMore: false, coverage: .complete, searchTimeMs: 0)
        }
        perf?.addCounter("full_index_candidate_slots", value: candidateSlots.count)

        let scorer = FuzzyMatcher.Scorer(queryLower: queryLower, mode: mode)

        // A large ASCII candidate set on the first interactive page is narrowed by FTS before
        // scoring; the page is then staged (total unknown) and the UI refines it later.
        var staged = false
        if let prefilterLimit = FullIndexRanker.adaptivePrefilterLimit(
            request: request,
            mode: mode,
            queryLower: queryLower,
            candidateCount: candidateSlots.count
        ) {
            perf?.addCounter("adaptive_prefilter_limit", value: prefilterLimit)
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
                    candidateSlots = FullIndexRanker.mergePrefilter(
                        candidateSlots: candidateSlots,
                        ftsSlots: ftsSlots,
                        index: index
                    )
                    perf?.addCounter("full_index_fts_prefilter_candidate_slots", value: candidateSlots.count)
                    staged = true
                }
            }
        }

        let page: FullIndexRanker.Page
        if staged {
            page = try FullIndexRanker.rankStaged(
                index: index,
                request: request,
                scorer: scorer,
                candidateSlots: candidateSlots,
                perf: perf
            )
        } else {
            page = try FullIndexRanker.rankComplete(
                index: index,
                request: request,
                mode: mode,
                queryLower: queryLower,
                scorer: scorer,
                candidateSlots: candidateSlots,
                indexContentVersion: fullIndexStore.contentGeneration,
                cache: &fullIndexStore.sortedMatchesCache,
                perf: perf
            )
        }

        let pageIDs = page.slots.compactMap { index.items[$0]?.id }
        let resultItems: [ClipboardStoredItem]
        if staged, let perf {
            resultItems = try perf.measure("full_index_prefilter_fetch_items") {
                try readStore.fetchItemsByIDs(pageIDs)
            }
        } else {
            resultItems = try readStore.fetchItemsByIDs(pageIDs)
        }
        return SearchResult(items: resultItems, total: page.total, hasMore: page.hasMore, coverage: page.coverage, searchTimeMs: 0)
    }

    private func shouldPreferFTSForFuzzy(query: String) -> Bool {
        guard let corpusMetrics else { return false }
        guard !query.isEmpty else { return false }
        return corpusMetrics.isHeavyPlainTextCorpus
    }

    private func searchFuzzyInRecentCache(request: SearchRequest, mode: SearchMode, query: String) throws -> SearchResult {
        try refreshCacheIfNeeded()

        let scorer = FuzzyMatcher.Scorer(queryLower: query.lowercased(), mode: mode)

        var scored: [(item: ClipboardStoredItem, key: SearchRankKey)] = []
        scored.reserveCapacity(min(recentItemsCache.count, Self.shortQueryCacheSize))

        for cached in recentItemsCache {
            let item = cached.item
            if let appFilter = request.appFilter, item.appBundleID != appFilter { continue }
            if let typeFilters = request.typeFilters, !typeFilters.isEmpty {
                if !typeFilters.contains(item.type) { continue }
            } else if let typeFilter = request.typeFilter {
                if item.type != typeFilter { continue }
            }

            guard let score = scorer.score(textLower: cached.combinedLower) else { continue }
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
        return SearchResult(items: items, total: -1, hasMore: hasMore, coverage: .stagedRefine, searchTimeMs: 0)
    }

    private func ftsPrefilterSlots(index: FullFuzzyIndex, ftsQuery: String, limit: Int) throws -> [Int] {
        let ids = try readStore.ftsPrefilterIDs(ftsQuery: ftsQuery, limit: limit)
        return ids.compactMap { index.idToSlot[$0] }
    }

    @discardableResult
    // MARK: - Timeout

    private func withTimeout<T: Sendable>(
        timeout: TimeInterval,
        onTimeout: @escaping @Sendable () -> Void = {},
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await work()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                onTimeout()
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
        guard !readStore.isOpen else { return }
        try readStore.open()
        fullIndexStore.sortedMatchesCache = nil
        SearchIndexDiskCache.removeStaleCacheFiles(dbPath: dbPath)
        refreshCorpusMetricsIfNeeded(force: true)
        refreshKnownMutationSeqIfPossible()
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

    private func searchAllWithFilters(request: SearchRequest) throws -> SearchResult {
        let page = try readStore.fetchAll(filters: .init(request), window: .init(request))
        return SearchResult(items: page.items, total: page.total, hasMore: page.hasMore, coverage: .complete, searchTimeMs: 0)
    }

#if DEBUG
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

    func debugFullIndexBuildHealth() -> (isBuilding: Bool, pendingEvents: Int) {
        (fullIndexStore.buildTask != nil, fullIndexStore.pendingEventCount)
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
