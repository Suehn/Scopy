import Foundation
import os

/// The one- and two-character query index's lifecycle: the installed snapshot, detached build,
/// tombstone rebuilds, and disk-cache persists. Not
/// Sendable: the search engine owns it, calls it only on its actor, and routes each task's
/// completion back through the actor.
final class ShortIndexStore {
    private struct Build {
        let task: Task<Void, Never>
        let generation: UInt64
    }

    private static let tombstoneRatioRebuildThreshold = 0.25
    private static let tombstoneMinSlotsForRebuild = 2000
    private static let tombstoneMinCountForRebuild = 256

    private let dbPath: String
    /// Smaller corpora scan SQL instead of keeping the index, unless a caller forces a build.
    private let minimumItemCount: Int

    private(set) var index: ShortQueryIndex?
    private(set) var mutationSeq: Int64?
    private var build: Build?
    private var cancelledBuilds: [UInt64: Task<Void, Never>] = [:]
    private var buildGeneration: UInt64 = 0
    private(set) var persistTask: Task<Void, Never>?
#if DEBUG
    private(set) var lastSnapshotSource: ShortQueryIndexSnapshotSource?
#endif

    init(dbPath: String, minimumItemCount: Int) {
        self.dbPath = dbPath
        self.minimumItemCount = minimumItemCount
    }

    var buildTask: Task<Void, Never>? { build?.task }

    // MARK: - Builds

    /// Starts a detached build (disk cache first, then the database) unless the index exists or
    /// a build is running; an unforced build also skips small corpora. `finish` runs the
    /// completion on the engine actor.
    func startBuildIfNeeded(
        force: Bool,
        estimatedCount: Int,
        finish: @escaping @Sendable (UInt64, ShortQueryIndexSnapshot?) async -> Void
    ) {
        guard index == nil, build == nil else { return }
        guard force || estimatedCount >= minimumItemCount else { return }

        buildGeneration &+= 1
        let generation = buildGeneration
        let task = Task.detached(priority: .utility) { [dbPath] in
            let loadStart = ProcessInfo.processInfo.systemUptime
            let cached = SearchIndexDiskCache.loadShortSnapshot(dbPath: dbPath)
            let loadMs = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
            ScopyLog.search.info("Short index disk cache load \(cached == nil ? "miss" : "hit", privacy: .public) in \(loadMs, format: .fixed(precision: 0), privacy: .public) ms")
            let snapshot = cached ?? SearchReadStore.loadShortQueryIndex(dbPath: dbPath, reserveSlots: estimatedCount)
            await finish(generation, snapshot)
        }
        build = Build(task: task, generation: generation)
    }

    func isCurrentBuild(_ generation: UInt64) -> Bool {
        build?.generation == generation
    }

    /// Installs the build at its own read position. Queries replay the shared journal from
    /// there before using any candidates; this store holds no second copy of commit history.
    func finishBuild(snapshot: ShortQueryIndexSnapshot?) -> Bool {
        build = nil
        guard let snapshot else { return false }
        index = snapshot.index
        mutationSeq = snapshot.mutationSeq
#if DEBUG
        lastSnapshotSource = snapshot.source
#endif
        return snapshot.source == .database
    }

    /// Stops the running build; its completion is ignored.
    func cancelBuild() {
        if let build {
            build.task.cancel()
            cancelledBuilds[build.generation] = build.task
        }
        build = nil
        buildGeneration &+= 1
    }

    func buildFinished(generation: UInt64) {
        cancelledBuilds.removeValue(forKey: generation)
    }

    func takeBuildTasksForShutdown() -> [Task<Void, Never>] {
        cancelBuild()
        let tasks = Array(cancelledBuilds.values)
        cancelledBuilds.removeAll()
        return tasks
    }

    /// Drops the index and any running build.
    func reset() {
        cancelBuild()
        index = nil
        mutationSeq = nil
    }

    // MARK: - Committed changes

    func apply(_ entry: StorageCommitJournal.Entry) {
        guard var index, let mutationSeq, entry.mutationSeq > mutationSeq else { return }
        self.index = nil
        switch entry.change {
        case .upserted(let item, let kind):
            switch kind {
            case .inserted, .content:
                index.upsert(item)
            case .usage, .metadata, .pin:
                break
            }
        case .deleted(let ids), .clearedUnpinned(let ids):
            for id in ids { index.markDeleted(id: id) }
        case .storageSizesUpdated:
            break
        }
        self.mutationSeq = entry.mutationSeq
        install(index)
    }

    /// Keeps `index` unless tombstones dominate it; a dropped index is rebuilt only while the
    /// corpus stays large enough to keep one.
    private func install(_ index: ShortQueryIndex) {
        let stats = index.healthStats()
        let needsRebuild = stats.slots >= Self.tombstoneMinSlotsForRebuild
            && stats.tombstones >= Self.tombstoneMinCountForRebuild
            && Double(stats.tombstones) / Double(stats.slots) >= Self.tombstoneRatioRebuildThreshold
        guard needsRebuild else {
            self.index = index
            return
        }
        reset()
    }

    // MARK: - Candidates

    func candidateIDStrings(for tokenLower: String) -> [String]? {
        index?.candidateIDStrings(for: tokenLower)
    }

    /// `nil` when there is no index or the token is not a non-ASCII bigram it covers.
    func candidateIDStringsForNonASCIIBigram(tokenLower: String) -> [String]? {
        index?.candidateIDStringsForNonASCIIBigram(tokenLower: tokenLower) ?? nil
    }

    // MARK: - Disk cache

    /// Writes the index to the disk cache stamped with `mutationSeq` unless a write is running.
    /// `finish` runs on the engine actor.
    func startPersistIfNeeded(finish: @escaping @Sendable () async -> Void) {
        guard persistTask == nil, let index, let mutationSeq else { return }
        guard let request = SearchIndexDiskCache.makeShortPersistRequest(
            index: index,
            dbPath: dbPath,
            mutationSeq: mutationSeq
        ) else { return }
        persistTask = Task.detached(priority: .utility) { [request] in
            do {
                try SearchIndexDiskCache.writeShortPersistRequest(request)
            } catch {
                // Best-effort cache: ignore failures.
            }
            await finish()
        }
    }

    func finishPersist() {
        persistTask = nil
    }

#if DEBUG
    /// Replaces any build with `task`, which never installs an index.
    func installPendingBuild(_ task: Task<Void, Never>) {
        reset()
        build = Build(task: task, generation: buildGeneration)
    }
#endif
}
