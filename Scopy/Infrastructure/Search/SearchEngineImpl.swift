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

        public struct Reason: Sendable {
            public let name: String

            public init(name: String) {
                self.name = name
            }
        }

        public let phases: [Phase]
        public let counters: [Counter]
        public let reasons: [Reason]

        public init(phases: [Phase], counters: [Counter], reasons: [Reason] = []) {
            self.phases = phases
            self.counters = counters
            self.reasons = reasons
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

    private enum FullIndexBuildTrigger: Equatable {
        case forced
        case interactive
    }

    private enum FullIndexBuilder {
        static func buildSnapshot(
            dbPath: String,
            reserveSlots: Int,
            metrics: inout SearchWarmLoadMetrics
        ) -> FullIndexSnapshot? {
            metrics.addReason(.databaseRebuild)
            let snapshot = metrics.measure("full_index_build_from_db") {
                SearchEngineImpl.buildFullIndexSnapshot(dbPath: dbPath, reserveSlots: reserveSlots)
            }
            return snapshot.map { snapshot in
                metrics.markSource(snapshot.source)
                return snapshot
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
    /// Committed storage changes to apply in order; nil when the engine only reads the database.
    private let commitJournal: StorageCommitJournal?

    /// Indexes and caches built for a search session are released once searching has been idle
    /// this long; the next session loads them back from the disk cache or the database.
    private static let sessionIdleTrimDelay: TimeInterval = 60
    private var activeSearchCount = 0
    private var lastSearchUptime: TimeInterval = 0
    private var idleTrimTask: Task<Void, Never>?
    /// `mutation_seq` stamped on the full index's disk cache while it still matches memory.
    private var fullIndexPersistedMutationSeq: Int64?

#if DEBUG
    private var debugFullIndexLastSnapshotSourceValue: FullIndexSnapshotSource?
    private var debugFullIndexLastDiskCacheLoadReasonValue: FullIndexDiskCacheLoadReason?
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
    private var fullIndexBuildTrigger: FullIndexBuildTrigger?
    private var lastFullIndexWarmLoadMetrics: SearchWarmLoadMetrics?

    private var shortQueryIndex: ShortQueryIndex?
    private var shortQueryIndexBuildTask: Task<Void, Never>?
    private var shortQueryIndexBuildGeneration: UInt64 = 0
    private var shortQueryIndexPendingUpserts: [ClipboardStoredItem] = []
    private var shortQueryIndexPendingDeletions: [UUID] = []
    private var shortQueryIndexDiskCachePersistTask: Task<Void, Never>?

    private static let fullIndexTombstoneRatioStaleThresholdDefault: Double = 0.25
    private static let fullIndexTombstoneMinSlotsForStaleDefault: Int = 64
    private static let fullIndexTombstoneMinCountForStaleDefault: Int = 16

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

    private var fuzzySortedMatchesCache: FullIndexRanker.SortedMatchesCache?

    private let searchTimeout: TimeInterval
    private let initialIndexBuildTimeout: TimeInterval

    private var corpusMetrics: CorpusMetrics?
    private var corpusMetricsUpdatedAt: Date = .distantPast

    private var supportsTrigramFTS: Bool = false

    // MARK: - Initialization

    public init(dbPath: String) {
        self.init(dbPath: dbPath, searchTimeout: 5.0, commitJournal: nil)
    }

    init(dbPath: String, commitJournal: StorageCommitJournal?) {
        self.init(dbPath: dbPath, searchTimeout: 5.0, commitJournal: commitJournal)
    }

    init(dbPath: String, searchTimeout: TimeInterval, commitJournal: StorageCommitJournal? = nil) {
        self.dbPath = dbPath
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
        if let task = shortQueryIndexBuildTask {
            await task.value
        }
        guard shortQueryIndex != nil else {
            throw SearchError.searchFailed("Failed to prepare short-query index")
        }
    }

    public func close() async {
        idleTrimTask?.cancel()
        idleTrimTask = nil
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
            _ = try? await withTimeout(timeout: 2.0) { await task.value }
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

    /// Drops every in-memory index and resynchronizes from the database; journaled commits up to
    /// that point are covered by the rebuild.
    public func invalidateCache() {
        _ = commitJournal?.drain()
        resetRecentCache()
        resetFullIndex()
        resetShortQueryIndex()
        markCorpusMetricsStale()
        refreshKnownDBChangeTokenIfPossible()
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
        guard connection != nil else { return }
        // Read the database position before draining: every in-process commit up to it has been
        // journaled by then, so a position beyond the journal means an unobserved commit.
        let current = try? fetchDBChangeToken()
        if let commitJournal {
            let drained = commitJournal.drain()
            if drained.overflowed {
                resetIndexesForUnobservedCommits()
                return
            }
            for entry in drained.entries {
                guard let known = knownDBChangeToken else {
                    refreshKnownDBChangeTokenIfPossible()
                    continue
                }
                if entry.mutationSeq <= known { continue }
                guard entry.mutationSeq == known + 1 else {
                    resetIndexesForUnobservedCommits()
                    return
                }
                knownDBChangeToken = entry.mutationSeq
                apply(entry.change)
            }
        }
        guard let current else { return }
        guard let known = knownDBChangeToken else {
            knownDBChangeToken = current
            return
        }
        if known < current {
            resetIndexesForUnobservedCommits()
        }
    }

    private func resetIndexesForUnobservedCommits() {
        resetQueryCaches()
        resetFullIndex()
        resetShortQueryIndex()
        markCorpusMetricsStale()
        refreshKnownDBChangeTokenIfPossible()
        startShortQueryIndexBuildIfNeeded()
    }

    private func apply(_ change: StorageCommittedChange) {
        switch change {
        case .upserted(let item):
            applyUpsert(item)
        case .pinChanged(let id, let isPinned):
            applyPinChange(id: id, pinned: isPinned)
        case .deleted(let ids):
            applyDeletions(ids)
        case .clearedUnpinned:
            resetRecentCache()
            resetFullIndex()
            resetShortQueryIndex()
            markCorpusMetricsStale()
            startShortQueryIndexBuildIfNeeded()
        case .unindexedFields:
            break
        }
    }

    private func applyUpsert(_ item: ClipboardStoredItem) {
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

        // Hand the storage over to the local copy before mutating it: while the property still
        // referenced the same buffers, every touched array and dictionary was copied first.
        fullIndex = nil

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

    private func applyPinChange(id: UUID, pinned: Bool) {
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

        fullIndex = nil
        var updated = existing
        updated.isPinned = pinned
        index.items[slot] = updated
        fullIndex = index
        markIndexChanged()
    }

    /// Tombstones one committed delete set in both indexes, checking the rebuild threshold once.
    private func applyDeletions(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        markCorpusMetricsStale()
        resetQueryCaches()
        handleShortQueryIndexDeletions(ids)

        if fullIndexBuildTask != nil {
            fullIndexPendingEvents.append(contentsOf: ids.map(FullIndexPendingEvent.delete))
            return
        }

        guard var index = fullIndex, !fullIndexStale else { return }
        fullIndex = nil
        for id in ids {
            guard let slot = index.idToSlot.removeValue(forKey: id),
                  slot < index.items.count,
                  index.items[slot] != nil else { continue }
            index.items[slot] = nil
            index.tombstoneCount += 1
        }
        fullIndex = index
        markIndexChanged()

        if shouldMarkFullIndexStaleDueToTombstones(index: index) {
            fullIndexStale = true
            startFullIndexBuildIfNeeded(force: true)
        }
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
        fullIndexBuildTrigger = nil
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
        // See `applyUpsert`: release the property's reference so the upsert mutates the
        // existing buffers instead of copying the whole index on every clipboard write.
        shortQueryIndex = nil
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

    private func handleShortQueryIndexDeletions(_ ids: [UUID]) {
        if shortQueryIndexBuildTask != nil {
            shortQueryIndexPendingDeletions.append(contentsOf: ids)
            return
        }

        guard var index = shortQueryIndex else { return }
        shortQueryIndex = nil
        for id in ids {
            index.markDeleted(id: id)
        }
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
            let loadStart = ProcessInfo.processInfo.systemUptime
            let cached = SearchIndexDiskCache.loadShortSnapshot(dbPath: dbPath)
            let loadMs = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
            ScopyLog.search.info("Short index disk cache load \(cached == nil ? "miss" : "hit", privacy: .public) in \(loadMs, format: .fixed(precision: 0), privacy: .public) ms")
            let snapshot = cached
                ?? Self.buildShortQueryIndexSnapshot(dbPath: dbPath, reserveSlots: reserveSlots)
            await self.finishShortQueryIndexBuild(generation: generation, snapshot: snapshot)
        }
    }

    /// The full index is independent of query and filters, so any interactive fuzzy request keeps
    /// one shared warm-up session alive; only leaving the fuzzy-search context ends it.
    private func isInteractiveFullIndexWarmupRequest(_ request: SearchRequest) -> Bool {
        guard request.mode == .fuzzy || request.mode == .fuzzyPlus else { return false }
        return !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func reconcileInteractiveFullIndexWarmup(for request: SearchRequest) {
        guard case .interactive? = fullIndexBuildTrigger else { return }
        guard !isInteractiveFullIndexWarmupRequest(request) else { return }
        cancelInteractiveFullIndexBuild()
    }

    private func cancelInteractiveFullIndexBuild() {
        guard case .interactive = fullIndexBuildTrigger else { return }
        fullIndexBuildTask?.cancel()
        fullIndexBuildTask = nil
        fullIndexBuildGeneration &+= 1
        fullIndexPendingEvents = []
        fullIndexBuildTrigger = nil
    }

    private func startInteractiveFullIndexBuildIfNeeded(for request: SearchRequest) {
        guard isInteractiveFullIndexWarmupRequest(request) else { return }
        startFullIndexBuildIfNeeded(force: false, trigger: .interactive)
    }

    private func startFullIndexBuildIfNeeded(force: Bool = false, trigger: FullIndexBuildTrigger = .forced) {
        guard fullIndexBuildTask == nil else { return }
        guard fullIndex == nil || fullIndexStale else { return }

        let estimatedCount = corpusMetrics?.itemCount ?? 0
        if !force {
            // Small corpora build quickly on demand; skip background warm-up to avoid extra work/memory.
            guard estimatedCount >= shortQueryCacheSize else { return }
        }

        fullIndexPendingEvents = []

        fullIndexBuildGeneration &+= 1
        let generation = fullIndexBuildGeneration
        let reserveSlots = estimatedCount
        fullIndexBuildTrigger = trigger

        fullIndexBuildTask = Task.detached(priority: .utility) { [dbPath] in
            var warmLoadMetrics = SearchWarmLoadMetrics()
            let loadStart = ProcessInfo.processInfo.systemUptime
            let cached = SearchIndexDiskCache.loadFullSnapshot(dbPath: dbPath, metrics: &warmLoadMetrics)
            let loadMs = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
            ScopyLog.search.info("Full index disk cache load \(cached == nil ? "miss" : "hit", privacy: .public) in \(loadMs, format: .fixed(precision: 0), privacy: .public) ms")
            let snapshot = cached
                ?? FullIndexBuilder.buildSnapshot(dbPath: dbPath, reserveSlots: reserveSlots, metrics: &warmLoadMetrics)
            await self.finishFullIndexBuild(
                generation: generation,
                snapshot: snapshot,
                warmLoadMetrics: warmLoadMetrics
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

        var index = FullFuzzyIndex(reserveSlots: reserveSlots)

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
                index.append(IndexedItem(from: stored))
            }
        } catch {
            return nil
        }

        guard let endDataVersion = readDataVersion() else { return nil }
        guard !Task.isCancelled else { return nil }

        return FullIndexSnapshot(
            index: index,
            startDataVersion: startDataVersion,
            endDataVersion: endDataVersion,
            source: .database
        )
    }

    private static func recordFullIndexDiskCacheMetadataCounters(
        _ metadata: FullIndexDiskCacheMetadataV2?,
        perf: SearchPerfContext
    ) {
        guard let metadata else { return }
        perf.addCounter("full_index_cache_metadata_item_count", value: metadata.itemCount)
        perf.addCounter("full_index_cache_metadata_tombstone_count", value: metadata.tombstoneCount)
        perf.addCounter("full_index_cache_metadata_tombstone_ratio_bps", value: Int((metadata.tombstoneRatio * 10_000).rounded()))
        perf.addCounter("full_index_cache_metadata_payload_bytes", value: Int(min(metadata.payloadByteSize, UInt64(Int.max))))
    }

    private func scheduleShortQueryIndexDiskCachePersistIfPossible() {
        guard shortQueryIndexDiskCachePersistTask == nil else { return }
        synchronizeWithCommittedChanges()
        guard let index = shortQueryIndex else { return }
        // `knownDBChangeToken` is the mutation_seq the in-memory index content corresponds to;
        // stamping the cache with it (rather than re-reading the DB) keeps the two atomic.
        guard usesMutationSeq, let mutationSeq = knownDBChangeToken else { return }
        guard let request = SearchIndexDiskCache.makeShortPersistRequest(
            index: index,
            dbPath: dbPath,
            mutationSeq: mutationSeq
        ) else { return }
        shortQueryIndexDiskCachePersistTask = Task.detached(priority: .utility) { [request] in
            do {
                try SearchIndexDiskCache.writeShortPersistRequest(request)
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
        synchronizeWithCommittedChanges()
        guard let index = fullIndex, !fullIndexStale else { return }
        guard usesMutationSeq, let mutationSeq = knownDBChangeToken else { return }
        guard fullIndexPersistedMutationSeq != mutationSeq else { return }
        guard let request = SearchIndexDiskCache.makeFullPersistRequest(
            index: index,
            dbPath: dbPath,
            mutationSeq: mutationSeq
        ) else { return }
        fullIndexDiskCachePersistTask = Task.detached(priority: .utility) { [request] in
            let persisted: Bool
            do {
                try SearchIndexDiskCache.writeFullPersistRequest(request)
                persisted = true
            } catch {
                // Best-effort cache: ignore failures.
                persisted = false
            }
            await self.finishFullIndexDiskCachePersist(mutationSeq: persisted ? mutationSeq : nil)
        }
    }

    private func finishFullIndexDiskCachePersist(mutationSeq: Int64?) {
        fullIndexDiskCachePersistTask = nil
        if let mutationSeq {
            fullIndexPersistedMutationSeq = mutationSeq
        }
    }

    private func finishShortQueryIndexBuild(generation: UInt64, snapshot: ShortQueryIndexSnapshot?) {
        guard shortQueryIndexBuildGeneration == generation else { return }
        synchronizeWithCommittedChanges()
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
        snapshot: FullIndexSnapshot?,
        warmLoadMetrics: SearchWarmLoadMetrics
    ) {
        guard fullIndexBuildGeneration == generation else { return }
        // Collect every commit made during the build as pending events; an unobserved commit
        // resets the indexes, which also supersedes this build.
        synchronizeWithCommittedChanges()
        guard fullIndexBuildGeneration == generation else { return }
        fullIndexBuildTask = nil
        fullIndexBuildTrigger = nil
        lastFullIndexWarmLoadMetrics = warmLoadMetrics
#if DEBUG
        if let lastReason = warmLoadMetrics.reasons.last {
            debugFullIndexLastDiskCacheLoadReasonValue = FullIndexDiskCacheLoadReason(rawValue: lastReason)
        }
#endif

        let pending = fullIndexPendingEvents
        fullIndexPendingEvents = []

        guard let snapshot else { return }
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

        if snapshot.source == .diskCache, pending.isEmpty {
            fullIndexPersistedMutationSeq = knownDBChangeToken
        }
        if fullIndexStale {
            startFullIndexBuildIfNeeded(force: true)
        } else if snapshot.source == .database {
            scheduleFullIndexDiskCachePersistIfPossible()
        }

        if !warmLoadMetrics.summary.isEmpty {
            ScopyLog.search.debug(
                "Full-index warm-load source=\(snapshot.source.rawValue, privacy: .public) metrics=\(warmLoadMetrics.summary, privacy: .public)"
            )
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
        statementCache = [:]
        statementCacheLRU = []
        connection?.releaseMemory()

        if fullIndexBuildTask != nil {
            resetFullIndex()
        } else if fullIndex != nil {
            if trim == .idle {
                scheduleFullIndexDiskCachePersistIfPossible()
            }
            fullIndex = nil
            fullIndexStale = true
            markIndexChanged()
        }
        if trim == .memoryCritical {
            resetShortQueryIndex()
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
            timeout = (fullIndex == nil || fullIndexStale) ? initialIndexBuildTimeout : searchTimeout
        case .exact, .regex:
            timeout = searchTimeout
        }

        try openIfNeeded()
        let interruptHandle = connection?.handle.map { SQLiteInterruptHandle(handle: $0) }

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
                        try Self.attachingMatchContexts(
                            to: rawResult,
                            request: request
                        )
                    }
                }
                return try Self.attachingMatchContexts(
                    to: rawResult,
                    request: request
                )
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

    private static func attachingMatchContexts(
        to result: SearchResult,
        request: SearchRequest
    ) throws -> SearchResult {
        guard request.hasSemanticQuery, !result.items.isEmpty else { return result }

        let matcher = try SearchMatchContextBuilder.prepare(
            request: request,
            coverage: result.coverage,
            cancellationCheck: { try Task.checkCancellation() }
        )
        var contexts: [UUID: SearchMatchContext] = [:]
        contexts.reserveCapacity(result.items.count)

        for item in result.items {
            try Task.checkCancellation()
            do {
                if let context = try matcher.makeContext(
                    plainText: item.plainText,
                    note: item.note,
                    cancellationCheck: { try Task.checkCancellation() }
                ) {
                    contexts[item.id] = context
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }

        return SearchResult(
            items: result.items,
            total: result.total,
            hasMore: result.hasMore,
            coverage: result.coverage,
            searchTimeMs: result.searchTimeMs,
            perf: result.perf,
            matchContexts: contexts
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
            return try searchInCache(request: request, coverage: .recentOnly(limit: shortQueryCacheSize)) { item in
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

        return try searchInCache(request: request, coverage: .recentOnly(limit: shortQueryCacheSize)) { item in
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
        page: (items: [ClipboardStoredItem], total: Int, hasMore: Bool),
        coverage: SearchCoverage = .complete
    ) -> SearchResult {
        makeZeroTimeSearchResult(items: page.items, total: page.total, hasMore: page.hasMore, coverage: coverage)
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

        await waitForFullIndexBuildIfNeeded(perf: perf)

        let index = try getOrBuildFullIndex(perf: perf)
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
        return makeZeroTimeSearchResult(page: page)
    }

    private func searchInteractiveNonASCIISubstringFallback(
        request: SearchRequest,
        trimmedQuery: String,
        perf: SearchPerfContext?
    ) throws -> SearchResult? {
        guard !trimmedQuery.canBeConverted(to: .ascii) else { return nil }

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
        let typeFilters = request.typeFilters.map(Array.init)

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
            typeFilters: typeFilters,
            perf: perf
        ) {
            return result
        }

        return try searchShortFuzzyWithSQLFallback(
            request: request,
            tokenLower: tokenLower,
            typeFilters: typeFilters,
            perf: perf
        )
    }

    private func searchShortFuzzyInFullIndexIfReady(
        request: SearchRequest,
        trimmedQuery: String,
        mode: SearchMode,
        perf: SearchPerfContext?
    ) throws -> SearchResult? {
        guard let index = fullIndex, !fullIndexStale else { return nil }

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
        typeFilters: [ClipboardItemType]?,
        perf: SearchPerfContext?
    ) throws -> SearchResult? {
        guard var shortIndex = shortQueryIndex else { return nil }

        if tokenLower.canBeConverted(to: .ascii) {
            let candidates = shortIndex.candidateIDStrings(for: tokenLower)
            shortQueryIndex = shortIndex
            return try searchShortFuzzyWithASCIICandidates(
                request: request,
                tokenLower: tokenLower,
                candidateIDStrings: candidates,
                typeFilters: typeFilters,
                perf: perf
            )
        }

        guard let candidates = shortIndex.candidateIDStringsForNonASCIIBigram(tokenLower: tokenLower) else {
            return nil
        }
        shortQueryIndex = shortIndex
        return try searchShortFuzzyWithNonASCIICandidates(
            request: request,
            tokenLower: tokenLower,
            candidateIDStrings: candidates,
            typeFilters: typeFilters,
            perf: perf
        )
    }

    private func searchShortFuzzyWithASCIICandidates(
        request: SearchRequest,
        tokenLower: String,
        candidateIDStrings: [String],
        typeFilters: [ClipboardItemType]?,
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
        let page: (items: [ClipboardStoredItem], total: Int, hasMore: Bool)
        if let perf {
            page = try perf.measure("short_query_short_index_fetch") {
                try searchWithShortQuerySubstringCandidates(
                    tokenLower: tokenLower,
                    candidateIDStrings: candidateIDStrings,
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
                candidateIDStrings: candidateIDStrings,
                sortMode: request.sortMode,
                appFilter: request.appFilter,
                typeFilter: request.typeFilter,
                typeFilters: typeFilters,
                limit: request.limit,
                offset: request.offset
            )
        }
        return makeZeroTimeSearchResult(page: page)
    }

    private func searchShortFuzzyWithNonASCIICandidates(
        request: SearchRequest,
        tokenLower: String,
        candidateIDStrings: [String],
        typeFilters: [ClipboardItemType]?,
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
        let page: (items: [ClipboardStoredItem], total: Int, hasMore: Bool)
        if let perf {
            page = try perf.measure("short_query_short_index_sql_fetch") {
                try searchWithShortQuerySubstringCandidatesSQL(
                    tokenLower: tokenLower,
                    candidateIDStrings: candidateIDStrings,
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
                candidateIDStrings: candidateIDStrings,
                sortMode: request.sortMode,
                appFilter: request.appFilter,
                typeFilter: request.typeFilter,
                typeFilters: typeFilters,
                limit: request.limit,
                offset: request.offset
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
        typeFilters: [ClipboardItemType]?,
        perf: SearchPerfContext?
    ) throws -> SearchResult {
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
        return makeZeroTimeSearchResult(page: page)
    }

    private func getOrBuildFullIndex(perf: SearchPerfContext?) throws -> FullFuzzyIndex {
        if let index = fullIndex, !fullIndexStale {
            perf?.addCounter("full_index_source_memory", value: 1)
            return index
        }

        let loadOutcome: FullIndexDiskCacheLoadOutcome
        if let perf {
            let preflight = perf.measure("full_index_disk_cache_preflight") {
                SearchIndexDiskCache.preflightFullIndex(dbPath: dbPath)
            }
            switch preflight {
            case .skip(let reason, let metadata):
                Self.recordFullIndexDiskCacheMetadataCounters(metadata, perf: perf)
                perf.addReason(reason.rawValue)
                loadOutcome = FullIndexDiskCacheLoadOutcome(snapshot: nil, reason: reason, metadata: metadata)
            case .candidate(let candidate):
                if let preflightReason = candidate.preflightReason {
                    perf.addReason(preflightReason.rawValue)
                }
                Self.recordFullIndexDiskCacheMetadataCounters(candidate.metadata, perf: perf)
                loadOutcome = perf.measure("full_index_disk_cache_load") {
                    SearchIndexDiskCache.loadFullSnapshot(from: candidate)
                }
                Self.recordFullIndexDiskCacheMetadataCounters(loadOutcome.metadata, perf: perf)
                perf.addReason(loadOutcome.reason.rawValue)
            }
        } else {
            let preflight = SearchIndexDiskCache.preflightFullIndex(dbPath: dbPath)
            switch preflight {
            case .skip(let reason, let metadata):
                loadOutcome = FullIndexDiskCacheLoadOutcome(snapshot: nil, reason: reason, metadata: metadata)
            case .candidate(let candidate):
                loadOutcome = SearchIndexDiskCache.loadFullSnapshot(from: candidate)
            }
        }

        #if DEBUG
        debugFullIndexLastDiskCacheLoadReasonValue = loadOutcome.reason
        #endif

        if let loaded = loadOutcome.snapshot?.index {
            if shouldMarkFullIndexStaleDueToTombstones(index: loaded) {
                // A heavily tombstoned disk snapshot can significantly degrade candidate intersections.
                // Treat it as unusable and rebuild from DB to keep refine latency stable.
                fullIndexStale = true
                perf?.addReason(FullIndexDiskCacheLoadReason.tombstoneStale.rawValue)
            } else {
                fullIndex = loaded
                fullIndexStale = false
                fullIndexPersistedMutationSeq = knownDBChangeToken
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
        perf?.addReason(FullIndexDiskCacheLoadReason.databaseRebuild.rawValue)
        if let perf {
            let phaseStart = CFAbsoluteTimeGetCurrent()
            newIndex = try buildFullIndex(perf: perf)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - phaseStart) * 1000
            perf.addPhase("full_index_build_from_db", ms: elapsedMs)
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

    private func waitForFullIndexBuildIfNeeded(perf: SearchPerfContext?) async {
        guard let task = fullIndexBuildTask else { return }
        if let perf {
            let phaseStart = CFAbsoluteTimeGetCurrent()
            _ = await task.value
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - phaseStart) * 1000
            perf.addPhase("full_index_build_wait", ms: elapsedMs)
        } else {
            await task.value
        }
    }

    private func buildFullIndex(perf: SearchPerfContext?) throws -> FullFuzzyIndex {
        let estimatedCount = corpusMetrics?.itemCount ?? 0

        let sql = """
            SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref, file_size_bytes
            FROM clipboard_items
        """
        let stmt = try prepare(sql)
        defer { stmt.reset() }

        var index = FullFuzzyIndex(reserveSlots: estimatedCount)
        var row = 0
        while try stmt.step() {
            if row % 512 == 0 {
                try Task.checkCancellation()
            }
            row += 1
            index.append(IndexedItem(from: try parseStoredItemSummary(from: stmt)))
        }
        return index
    }

    private func shouldMarkFullIndexStaleDueToTombstones(index: FullFuzzyIndex) -> Bool {
        Self.shouldMarkFullIndexStaleDueToTombstones(
            itemCount: index.items.count,
            tombstoneCount: index.tombstoneCount
        )
    }

    static func shouldMarkFullIndexStaleDueToTombstones(itemCount: Int, tombstoneCount: Int) -> Bool {
        guard itemCount >= fullIndexTombstoneMinSlotsForStaleDefault else { return false }
        guard tombstoneCount >= fullIndexTombstoneMinCountForStaleDefault else { return false }

        let ratio = Double(tombstoneCount) / Double(itemCount)
        return ratio >= fullIndexTombstoneRatioStaleThresholdDefault
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
                indexContentVersion: fullIndexGeneration,
                cache: &fuzzySortedMatchesCache,
                perf: perf
            )
        }

        let pageIDs = page.slots.compactMap { index.items[$0]?.id }
        let resultItems: [ClipboardStoredItem]
        if staged, let perf {
            resultItems = try perf.measure("full_index_prefilter_fetch_items") {
                try fetchItemsByIDs(ids: pageIDs)
            }
        } else {
            resultItems = try fetchItemsByIDs(ids: pageIDs)
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
        scored.reserveCapacity(min(recentItemsCache.count, shortQueryCacheSize))

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
        let ids = try ftsPrefilterIDs(ftsQuery: ftsQuery, limit: limit)
        return ids.compactMap { index.idToSlot[$0] }
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

        index.append(indexed)
        return true
    }

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
        SearchIndexDiskCache.removeStaleCacheFiles(dbPath: dbPath)
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
        // Served as an index-only scan by idx_plain_text_bytes (see SQLiteMigrations); the
        // aggregate expression must stay byte-identical to that index's expression.
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
        return SearchResult(items: page.items, total: page.total, hasMore: page.hasMore, coverage: .complete, searchTimeMs: 0)
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

        let keepCount = offset + limit + 1
        var selector = TopKSelector<SearchRankKey>(capacity: keepCount) { lhs, rhs in
            SearchRankKey.isBetter(lhs, than: rhs, sortMode: sortMode)
        }
        selector.reserveCapacity(min(keepCount, 8192))

        while try stmt.step() {
            guard let idString = stmt.columnText(0), let id = UUID(uuidString: idString) else { continue }

            let lastUsedAt = Date(timeIntervalSince1970: stmt.columnDouble(1))
            let isPinned = stmt.columnInt(2) != 0

            let plainRes = instrASCIIInsensitiveUTF8(
                haystack: stmt.columnTextBytes(3),
                needleLower: needleLowerBytes
            )
            let matchPos: Int
            if plainRes.pos > 0 {
                matchPos = plainRes.pos
            } else {
                let noteRes = instrASCIIInsensitiveUTF8(
                    haystack: stmt.columnTextBytes(4),
                    needleLower: needleLowerBytes
                )
                guard noteRes.pos > 0 else { continue }
                // A note match ranks as if it followed the plain text and one separator.
                matchPos = plainRes.lengthIfNoMatch + 1 + noteRes.pos
            }
            selector.offer(SearchRankKey(isPinned: isPinned, lastUsedAt: lastUsedAt, score: -matchPos, id: id))
        }

        let hits = selector.sortedElements()
        let start = min(offset, hits.count)
        let end = min(offset + limit + 1, hits.count)
        var pageIDs: [UUID] = (start < end) ? hits[start..<end].map(\.id) : []

        let hasMore = hits.count == keepCount
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

    func debugFullIndexLastDiskCacheLoadReason() -> String? {
        debugFullIndexLastDiskCacheLoadReasonValue?.rawValue
    }

    func debugFullIndexBuildHealth() -> (isBuilding: Bool, pendingEvents: Int) {
        let isBuilding = fullIndexBuildTask != nil
        return (isBuilding, fullIndexPendingEvents.count)
    }

    func debugCancelFullIndexBuild() {
        fullIndexBuildTask?.cancel()
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
        fullIndexBuildGeneration
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

    func debugInstallPendingShortQueryIndexBuild(_ task: Task<Void, Never>) {
        shortQueryIndexBuildTask?.cancel()
        shortQueryIndexBuildGeneration &+= 1
        shortQueryIndex = nil
        shortQueryIndexPendingUpserts = []
        shortQueryIndexPendingDeletions = []
        shortQueryIndexBuildTask = task
    }

    func debugAwaitShortQueryIndexBuild() async {
        if let task = shortQueryIndexBuildTask {
            await task.value
        }
    }
    #endif
}
