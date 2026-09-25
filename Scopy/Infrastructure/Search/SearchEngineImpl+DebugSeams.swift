#if DEBUG
import Foundation

/// Test seams into the engine's index lifecycle.
extension SearchEngineImpl {
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
}
#endif
