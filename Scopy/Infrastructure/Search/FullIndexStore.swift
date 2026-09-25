import Foundation
import os

/// The full-history fuzzy index's lifecycle: the installed index and whether it is stale, the
/// detached build and the commits that land while it runs, tombstone rebuilds, disk-cache
/// persists, and session release. Not Sendable: the search engine owns it, calls it only on its
/// actor, and routes each task's completion back through the actor.
final class FullIndexStore {
    enum BuildTrigger: Equatable {
        /// A search, a tombstone rebuild, or a test needs the index.
        case forced
        /// An interactive fuzzy query warms the index up; leaving fuzzy search cancels it.
        case interactive
    }

    /// What the engine must do after a build lands.
    enum BuildOutcome {
        case none
        /// Built from the database: write it to the disk cache.
        case persist
        /// Commits during the build tombstoned too much of it: build again.
        case rebuild
    }

    private enum PendingEvent {
        case upsert(ClipboardStoredItem)
        case delete(UUID)
        case pin(UUID, Bool)
    }

    private struct Build {
        let task: Task<Void, Never>
        let generation: UInt64
        let trigger: BuildTrigger
        var pendingEvents: [PendingEvent] = []
        /// Searches suspended until this build lands or is superseded.
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    }

    private static let tombstoneRatioStaleThreshold = 0.25
    private static let tombstoneMinSlotsForStale = 64
    private static let tombstoneMinCountForStale = 16

    private let dbPath: String
    /// Background warm-ups skip smaller corpora, which build quickly on demand.
    private let warmupMinimumItemCount: Int

    private(set) var index: FullFuzzyIndex?
    private(set) var isStale = true
    /// Advances on every content change; keys the ranker's sorted-matches cache.
    private(set) var contentGeneration: UInt64 = 0
    var sortedMatchesCache: FullIndexRanker.SortedMatchesCache?

    private var build: Build?
    private(set) var buildGeneration: UInt64 = 0
    private(set) var persistTask: Task<Void, Never>?
    /// `mutation_seq` stamped on the disk cache while it still matches memory.
    private var persistedMutationSeq: Int64?
    private(set) var lastWarmLoadMetrics: SearchWarmLoadMetrics?
#if DEBUG
    private(set) var lastSnapshotSource: FullIndexSnapshotSource?
    private(set) var lastDiskCacheLoadReason: FullIndexDiskCacheLoadReason?
#endif

    init(dbPath: String, warmupMinimumItemCount: Int) {
        self.dbPath = dbPath
        self.warmupMinimumItemCount = warmupMinimumItemCount
    }

    /// The index when it is installed and not superseded.
    var usableIndex: FullFuzzyIndex? { isStale ? nil : index }
    var buildTask: Task<Void, Never>? { build?.task }
#if DEBUG
    var pendingEventCount: Int { build?.pendingEvents.count ?? 0 }
#endif

    static func needsRebuild(itemCount: Int, tombstoneCount: Int) -> Bool {
        guard itemCount >= tombstoneMinSlotsForStale else { return false }
        guard tombstoneCount >= tombstoneMinCountForStale else { return false }
        return Double(tombstoneCount) / Double(itemCount) >= tombstoneRatioStaleThreshold
    }

    private static func needsRebuild(_ index: FullFuzzyIndex) -> Bool {
        needsRebuild(itemCount: index.items.count, tombstoneCount: index.tombstoneCount)
    }

    // MARK: - Builds

    /// Starts a detached build (disk cache first, then the database) unless the index is usable
    /// or a build is running; a non-forced warm-up also skips small corpora. `finish` runs the
    /// completion on the engine actor.
    func startBuildIfNeeded(
        force: Bool,
        trigger: BuildTrigger,
        estimatedCount: Int,
        finish: @escaping @Sendable (UInt64, FullIndexSnapshot?, SearchWarmLoadMetrics) async -> Void
    ) {
        guard build == nil else { return }
        guard index == nil || isStale else { return }
        guard force || estimatedCount >= warmupMinimumItemCount else { return }

        buildGeneration &+= 1
        let generation = buildGeneration
        let task = Task.detached(priority: .utility) { [dbPath] in
            var metrics = SearchWarmLoadMetrics()
            let snapshot = FullIndexStore.loadSnapshot(dbPath: dbPath, reserveSlots: estimatedCount, metrics: &metrics)
            await finish(generation, snapshot, metrics)
        }
        build = Build(task: task, generation: generation, trigger: trigger)
    }

    private static func loadSnapshot(
        dbPath: String,
        reserveSlots: Int,
        metrics: inout SearchWarmLoadMetrics
    ) -> FullIndexSnapshot? {
        let loadStart = ProcessInfo.processInfo.systemUptime
        let cached = SearchIndexDiskCache.loadFullSnapshot(dbPath: dbPath, metrics: &metrics)
        let loadMs = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
        ScopyLog.search.info("Full index disk cache load \(cached == nil ? "miss" : "hit", privacy: .public) in \(loadMs, format: .fixed(precision: 0), privacy: .public) ms")
        if let cached { return cached }

        metrics.addReason(.databaseRebuild)
        let index = metrics.measure("full_index_build_from_db") {
            SearchReadStore.loadFullIndex(dbPath: dbPath, reserveSlots: reserveSlots)
        }
        guard let index else { return nil }
        metrics.markSource(.database)
        return FullIndexSnapshot(index: index, source: .database)
    }

    func isCurrentBuild(_ generation: UInt64) -> Bool {
        build?.generation == generation
    }

    /// Installs the landed build with the commits it missed replayed on top. The caller has
    /// checked `isCurrentBuild` and synchronized with committed changes first.
    func finishBuild(
        snapshot: FullIndexSnapshot?,
        warmLoadMetrics: SearchWarmLoadMetrics,
        knownMutationSeq: Int64?
    ) -> BuildOutcome {
        let pending = build?.pendingEvents ?? []
        endBuild()
        lastWarmLoadMetrics = warmLoadMetrics
#if DEBUG
        let databaseRebuild = FullIndexDiskCacheLoadReason.databaseRebuild.rawValue
        if let reason = warmLoadMetrics.reasons.last(where: { $0 != databaseRebuild }) {
            lastDiskCacheLoadReason = FullIndexDiskCacheLoadReason(rawValue: reason)
        }
#endif

        guard let snapshot else { return .none }
        var index = snapshot.index
#if DEBUG
        lastSnapshotSource = snapshot.source
#endif

        for event in pending {
            switch event {
            case .upsert(let item):
                Self.upsert(item, into: &index)
            case .delete(let id):
                Self.remove(id, from: &index)
            case .pin(let id, let pinned):
                Self.setPinned(id, pinned, in: &index)
            }
        }

        self.index = index
        isStale = Self.needsRebuild(index)
        contentChanged()

        if snapshot.source == .diskCache, pending.isEmpty {
            persistedMutationSeq = knownMutationSeq
        }
        if isStale { return .rebuild }
        return snapshot.source == .database ? .persist : .none
    }

    /// Stops the running build; its completion is ignored.
    func cancelBuild() {
        build?.task.cancel()
        endBuild()
        buildGeneration &+= 1
    }

    /// Clears the build and resumes its waiters; they re-check the index on the engine actor.
    private func endBuild() {
        let waiters = build?.waiters.values
        build = nil
        waiters?.forEach { $0.resume() }
    }

    /// Suspends `continuation` until the running build ends; resumes it at once without a build.
    func addBuildWaiter(_ id: UUID, _ continuation: CheckedContinuation<Void, Error>) {
        guard build != nil else {
            continuation.resume()
            return
        }
        build?.waiters[id] = continuation
    }

    /// The waiter to resume on its search's cancellation; the build keeps running for others.
    func removeBuildWaiter(_ id: UUID) -> CheckedContinuation<Void, Error>? {
        build?.waiters.removeValue(forKey: id)
    }

    func cancelInteractiveBuild() {
        guard build?.trigger == .interactive else { return }
        cancelBuild()
    }

    /// Drops the index and any running build.
    func reset() {
        cancelBuild()
        index = nil
        isStale = true
        contentChanged()
    }

    /// Releases the index between search sessions; the next search loads it back.
    func release() {
        index = nil
        isStale = true
        contentChanged()
    }

    // MARK: - Committed changes

    /// Returns whether the corpus changed shape (the corpus metrics are stale) and whether the
    /// tombstones now call for a rebuild.
    func applyUpsert(_ item: ClipboardStoredItem) -> (corpusChanged: Bool, needsRebuild: Bool) {
        if build != nil {
            build?.pendingEvents.append(.upsert(item))
            return (true, false)
        }
        // Not built yet: the upsert may still change the corpus before the first search.
        guard var index, !isStale else { return (true, false) }

        // Hand the storage over to the local copy before mutating it: while the property still
        // referenced the same buffers, every touched array and dictionary was copied first.
        self.index = nil
        let beforeTombstones = index.tombstoneCount
        let appended = Self.upsert(item, into: &index)
        self.index = index
        contentChanged()

        let needsRebuild = index.tombstoneCount > beforeTombstones && Self.needsRebuild(index)
        if needsRebuild { isStale = true }
        return (appended, needsRebuild)
    }

    func applyPinChange(id: UUID, pinned: Bool) {
        if build != nil {
            build?.pendingEvents.append(.pin(id, pinned))
            return
        }
        guard var index, !isStale,
              let slot = index.idToSlot[id],
              slot < index.items.count,
              index.items[slot] != nil else { return }
        self.index = nil
        Self.setPinned(id, pinned, in: &index)
        self.index = index
        contentChanged()
    }

    /// Tombstones one committed delete set; returns whether the tombstones call for a rebuild.
    func applyDeletions(_ ids: [UUID]) -> Bool {
        if build != nil {
            build?.pendingEvents.append(contentsOf: ids.map(PendingEvent.delete))
            return false
        }
        guard var index, !isStale else { return false }
        self.index = nil
        for id in ids {
            Self.remove(id, from: &index)
        }
        self.index = index
        contentChanged()

        guard Self.needsRebuild(index) else { return false }
        isStale = true
        return true
    }

    /// Metadata-only changes update the slot in place; changed text tombstones the old slot and
    /// appends a new one, which avoids removing postings. Returns whether a slot was appended.
    @discardableResult
    private static func upsert(_ item: ClipboardStoredItem, into index: inout FullFuzzyIndex) -> Bool {
        let indexed = IndexedItem(from: item)

        if let slot = index.idToSlot[item.id],
           slot < index.items.count,
           let existing = index.items[slot] {
            if existing.plainTextLower == indexed.plainTextLower {
                index.items[slot] = indexed
                return false
            }
            index.items[slot] = nil
            index.tombstoneCount += 1
        }

        index.append(indexed)
        return true
    }

    private static func remove(_ id: UUID, from index: inout FullFuzzyIndex) {
        guard let slot = index.idToSlot.removeValue(forKey: id),
              slot < index.items.count,
              index.items[slot] != nil else { return }
        index.items[slot] = nil
        index.tombstoneCount += 1
    }

    private static func setPinned(_ id: UUID, _ pinned: Bool, in index: inout FullFuzzyIndex) {
        guard let slot = index.idToSlot[id],
              slot < index.items.count,
              var existing = index.items[slot] else { return }
        existing.isPinned = pinned
        index.items[slot] = existing
    }

    private func contentChanged() {
        contentGeneration &+= 1
        sortedMatchesCache = nil
    }

    // MARK: - Disk cache

    /// Writes the usable index to the disk cache stamped with `mutationSeq` unless that stamp is
    /// already there or a write is running. `finish` runs on the engine actor with the stamp that
    /// landed, or nil when the write failed.
    func startPersistIfNeeded(mutationSeq: Int64, finish: @escaping @Sendable (Int64?) async -> Void) {
        guard persistTask == nil, let index = usableIndex, persistedMutationSeq != mutationSeq else { return }
        guard let request = SearchIndexDiskCache.makeFullPersistRequest(
            index: index,
            dbPath: dbPath,
            mutationSeq: mutationSeq
        ) else { return }
        persistTask = Task.detached(priority: .utility) { [request] in
            let persisted: Bool
            do {
                try SearchIndexDiskCache.writeFullPersistRequest(request)
                persisted = true
            } catch {
                // Best-effort cache: ignore failures.
                persisted = false
            }
            await finish(persisted ? mutationSeq : nil)
        }
    }

    func finishPersist(mutationSeq: Int64?) {
        persistTask = nil
        if let mutationSeq {
            persistedMutationSeq = mutationSeq
        }
    }
}
