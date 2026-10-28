import Foundation
import os

/// The full-history fuzzy index's lifecycle: the installed index and whether it is stale, the
/// detached build, tombstone rebuilds, disk-cache
/// persists, and session release. Not Sendable: the search engine owns it, calls it only on its
/// actor, and routes each task's completion back through the actor.
final class FullIndexStore {
    enum BuildTrigger: Equatable {
        /// A search, a tombstone rebuild, or a test needs the index.
        case forced
        /// An interactive fuzzy query warms the index up; leaving fuzzy search cancels it.
        case interactive
    }

    private struct Build {
        let task: Task<Void, Never>
        let generation: UInt64
        let trigger: BuildTrigger
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
    private(set) var mutationSeq: Int64?
    private(set) var isStale = true
    /// Advances on every content change; keys the ranker's sorted-matches cache.
    private(set) var contentGeneration: UInt64 = 0
    var sortedMatchesCache: FullIndexRanker.SortedMatchesCache?

    private var build: Build?
    private var cancelledBuilds: [UInt64: Task<Void, Never>] = [:]
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
        let snapshot = metrics.measure("full_index_build_from_db") {
            SearchReadStore.loadFullIndex(dbPath: dbPath, reserveSlots: reserveSlots)
        }
        guard let snapshot else { return nil }
        metrics.markSource(.database)
        return snapshot
    }

    func isCurrentBuild(_ generation: UInt64) -> Bool {
        build?.generation == generation
    }

    /// Installs the build at its own read position. The engine advances it through the shared
    /// journal inside the next query's read transaction before using its candidates.
    func finishBuild(
        snapshot: FullIndexSnapshot?,
        warmLoadMetrics: SearchWarmLoadMetrics
    ) -> Bool {
        endBuild()
        lastWarmLoadMetrics = warmLoadMetrics
#if DEBUG
        let databaseRebuild = FullIndexDiskCacheLoadReason.databaseRebuild.rawValue
        if let reason = warmLoadMetrics.reasons.last(where: { $0 != databaseRebuild }) {
            lastDiskCacheLoadReason = FullIndexDiskCacheLoadReason(rawValue: reason)
        }
#endif

        guard let snapshot else { return false }
        let index = snapshot.index
#if DEBUG
        lastSnapshotSource = snapshot.source
#endif

        self.index = index
        mutationSeq = snapshot.mutationSeq
        isStale = false
        contentChanged()

        if snapshot.source == .diskCache {
            persistedMutationSeq = snapshot.mutationSeq
        }
        return snapshot.source == .database
    }

    /// Stops the running build; its completion is ignored.
    func cancelBuild() {
        if let build {
            build.task.cancel()
            cancelledBuilds[build.generation] = build.task
        }
        endBuild()
        buildGeneration &+= 1
    }

    func buildFinished(generation: UInt64) {
        cancelledBuilds.removeValue(forKey: generation)
    }

    /// Cancellation requests do not end SQLite scans. Shutdown retains and joins every task.
    func takeBuildTasksForShutdown() -> [Task<Void, Never>] {
        cancelBuild()
        let tasks = Array(cancelledBuilds.values)
        cancelledBuilds.removeAll()
        return tasks
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
        mutationSeq = nil
        isStale = true
        contentChanged()
    }

    /// Releases the index between search sessions; the next search loads it back.
    func release() {
        index = nil
        mutationSeq = nil
        isStale = true
        contentChanged()
    }

    // MARK: - Committed changes

    /// Applies one fact after this snapshot's cursor. Usage and pin changes touch only ranking
    /// metadata; searchable text is normalized only when the content actually changes.
    func apply(_ entry: StorageCommitJournal.Entry) {
        guard var index, let mutationSeq, entry.mutationSeq > mutationSeq else { return }
        self.index = nil
        switch entry.change {
        case .upserted(let item, let kind):
            switch kind {
            case .inserted, .content:
                Self.upsert(item, into: &index)
                contentChanged()
            case .usage, .pin:
                if let slot = index.idToSlot[item.id], var existing = index.items[slot] {
                    existing.lastUsedAt = item.lastUsedAt
                    existing.isPinned = item.isPinned
                    index.items[slot] = existing
                    contentChanged()
                }
            case .metadata:
                break
            }
        case .deleted(let ids), .clearedUnpinned(let ids):
            for id in ids { Self.remove(id, from: &index) }
            contentChanged()
        case .storageSizesUpdated:
            break
        }
        self.index = index
        self.mutationSeq = entry.mutationSeq
        isStale = Self.needsRebuild(index)
    }

    /// Content facts reuse a slot when normalized text is unchanged. Changed text tombstones
    /// the old slot and appends a new one, avoiding removal from postings lists.
    private static func upsert(_ item: ClipboardStoredItem, into index: inout FullFuzzyIndex) {
        let indexed = IndexedItem(from: item)

        if let slot = index.idToSlot[item.id],
           slot < index.items.count,
           let existing = index.items[slot] {
            if existing.plainTextLower == indexed.plainTextLower {
                index.items[slot] = indexed
                return
            }
            index.items[slot] = nil
            index.tombstoneCount += 1
        }

        index.append(indexed)
    }

    private static func remove(_ id: UUID, from index: inout FullFuzzyIndex) {
        guard let slot = index.idToSlot.removeValue(forKey: id),
              slot < index.items.count,
              index.items[slot] != nil else { return }
        index.items[slot] = nil
        index.tombstoneCount += 1
    }

    private func contentChanged() {
        contentGeneration &+= 1
        sortedMatchesCache = nil
    }

    // MARK: - Disk cache

    /// Writes the usable index at its own read position unless that stamp is already persisted
    /// or a write is running. `finish` runs on the engine actor with the stamp that
    /// landed, or nil when the write failed.
    func startPersistIfNeeded(finish: @escaping @Sendable (Int64?) async -> Void) {
        guard persistTask == nil, let index = usableIndex, let mutationSeq, persistedMutationSeq != mutationSeq else { return }
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
