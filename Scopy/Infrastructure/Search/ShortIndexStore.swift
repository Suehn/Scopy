import Foundation
import os

/// The one- and two-character query index's lifecycle: the installed index, the detached build
/// and the commits that land while it runs, tombstone rebuilds, and disk-cache persists. Not
/// Sendable: the search engine owns it, calls it only on its actor, and routes each task's
/// completion back through the actor.
final class ShortIndexStore {
    private struct Build {
        let task: Task<Void, Never>
        let generation: UInt64
        var pendingUpserts: [ClipboardStoredItem] = []
        var pendingDeletions: [UUID] = []
    }

    private static let tombstoneRatioRebuildThreshold = 0.25
    private static let tombstoneMinSlotsForRebuild = 2000
    private static let tombstoneMinCountForRebuild = 256

    private let dbPath: String
    /// Smaller corpora scan SQL instead of keeping the index, unless a caller forces a build.
    private let minimumItemCount: Int

    private(set) var index: ShortQueryIndex?
    private var build: Build?
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
                .map { ShortQueryIndexSnapshot(index: $0, source: .database) }
            await finish(generation, snapshot)
        }
        build = Build(task: task, generation: generation)
    }

    func isCurrentBuild(_ generation: UInt64) -> Bool {
        build?.generation == generation
    }

    /// Installs the landed build with the commits it missed replayed on top; returns whether it
    /// came from the database and should be written to the disk cache. The caller has checked
    /// `isCurrentBuild` and synchronized with committed changes first.
    func finishBuild(snapshot: ShortQueryIndexSnapshot?) -> Bool {
        let pendingDeletions = build?.pendingDeletions ?? []
        let pendingUpserts = build?.pendingUpserts ?? []
        build = nil

        guard let snapshot else { return false }
        var index = snapshot.index
        for id in pendingDeletions {
            index.markDeleted(id: id)
        }
        for item in pendingUpserts {
            index.upsert(item)
        }
        self.index = index
#if DEBUG
        lastSnapshotSource = snapshot.source
#endif
        return snapshot.source == .database
    }

    /// Stops the running build; its completion is ignored.
    func cancelBuild() {
        build?.task.cancel()
        build = nil
        buildGeneration &+= 1
    }

    /// Drops the index and any running build.
    func reset() {
        cancelBuild()
        index = nil
    }

    // MARK: - Committed changes

    /// Returns whether the index was dropped for tombstones and should be built again.
    func applyUpsert(_ item: ClipboardStoredItem) -> Bool {
        if build != nil {
            build?.pendingUpserts.append(item)
            return false
        }
        guard var index else { return false }
        // Release the property's reference so the upsert mutates the existing buffers instead of
        // copying the whole index on every clipboard write.
        self.index = nil
        index.upsert(item)
        return install(index)
    }

    /// Returns whether the index was dropped for tombstones and should be built again.
    func applyDeletions(_ ids: [UUID]) -> Bool {
        if build != nil {
            build?.pendingDeletions.append(contentsOf: ids)
            return false
        }
        guard var index else { return false }
        self.index = nil
        for id in ids {
            index.markDeleted(id: id)
        }
        return install(index)
    }

    /// Keeps `index` unless tombstones dominate it; a dropped index is rebuilt only while the
    /// corpus stays large enough to keep one.
    private func install(_ index: ShortQueryIndex) -> Bool {
        let stats = index.healthStats()
        let needsRebuild = stats.slots >= Self.tombstoneMinSlotsForRebuild
            && stats.tombstones >= Self.tombstoneMinCountForRebuild
            && Double(stats.tombstones) / Double(stats.slots) >= Self.tombstoneRatioRebuildThreshold
        guard needsRebuild else {
            self.index = index
            return false
        }
        reset()
        return stats.live >= minimumItemCount
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
    func startPersistIfNeeded(mutationSeq: Int64, finish: @escaping @Sendable () async -> Void) {
        guard persistTask == nil, let index else { return }
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
