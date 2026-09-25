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

    // MARK: - Properties

    private let dbPath: String
    private let readStore: SearchReadStore
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

    private var fuzzySortedMatchesCache: FullIndexRanker.SortedMatchesCache?

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

        fuzzySortedMatchesCache = nil
        corpusMetrics = nil
        corpusMetricsUpdatedAt = .distantPast
        knownDBChangeToken = nil
        usesMutationSeq = false
        readStore.close()
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
        guard readStore.isOpen else { return }
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
        guard let index = SearchReadStore.loadShortQueryIndex(dbPath: dbPath, reserveSlots: reserveSlots) else {
            return nil
        }
        return ShortQueryIndexSnapshot(index: index, source: .database)
    }

    private static func buildFullIndexSnapshot(dbPath: String, reserveSlots: Int) -> FullIndexSnapshot? {
        guard let scan = SearchReadStore.loadFullIndex(dbPath: dbPath, reserveSlots: reserveSlots) else {
            return nil
        }
        return FullIndexSnapshot(
            index: scan.index,
            startDataVersion: scan.startDataVersion,
            endDataVersion: scan.endDataVersion,
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

    private func fetchDBChangeToken() throws -> Int64 {
        if usesMutationSeq {
            return try readStore.fetchMutationSeq()
        }
        return try readStore.fetchDataVersion()
    }

    private func refreshKnownDBChangeTokenIfPossible() {
        guard readStore.isOpen else { return }
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
        readStore.trimMemory()

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

        let items = try readStore.fetchRecentSummaries(limit: shortQueryCacheSize, offset: 0)
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
        let page = try readStore.searchSubstringLike(
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
                try readStore.searchSubstringLike(
                    tokens: tokens,
                    sortMode: request.sortMode,
                    filters: .init(request),
                    window: .init(request)
                )
            }
        } else {
            page = try readStore.searchSubstringLike(
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

        let stmt = try readStore.prepare("SELECT \(ClipboardItemRow.summaryColumns) FROM clipboard_items")
        defer { stmt.reset() }

        var index = FullFuzzyIndex(reserveSlots: estimatedCount)
        var row = 0
        while try stmt.step() {
            if row % 512 == 0 {
                try Task.checkCancellation()
            }
            row += 1
            index.append(IndexedItem(from: try ClipboardItemRow.decodeSummary(stmt)))
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
        let ids = try readStore.ftsPrefilterIDs(ftsQuery: ftsQuery, limit: limit)
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
        guard !readStore.isOpen else { return }
        try readStore.open()
        usesMutationSeq = readStore.hasMetaTable
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

        if let metrics = try? readStore.corpusMetrics() {
            corpusMetrics = metrics
        }
        corpusMetricsUpdatedAt = Date()
    }

    private func searchAllWithFilters(request: SearchRequest) throws -> SearchResult {
        let page = try readStore.fetchAll(filters: .init(request), window: .init(request))
        return SearchResult(items: page.items, total: page.total, hasMore: page.hasMore, coverage: .complete, searchTimeMs: 0)
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
