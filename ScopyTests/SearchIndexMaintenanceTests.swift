import XCTest
@testable import ScopyKit

final class SearchIndexMaintenanceTests: XCTestCase {
    /// A cleanup commit tombstones its delete set in both indexes instead of dropping them.
    func testCommittedCleanupKeepsIndexesBuiltAndSearchable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-index-maintenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("clipboard.db").path

        let storage = StorageService(databasePath: dbPath)
        try await storage.open()
        var inserted: [ClipboardStoredItem] = []
        for i in 0..<100 {
            let text = "maintained entry \(i)"
            inserted.append(try await storage.upsertItem(ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: text,
                payload: .none,
                appBundleID: "com.test.app",
                contentHash: "maintained-\(i)",
                sizeBytes: text.utf8.count
            )))
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let search = SearchEngineImpl(dbPath: dbPath, commitJournal: storage.commitJournal)
        try await search.open()
        await search.debugStartShortQueryIndexBuild(force: true)
        await search.debugAwaitShortQueryIndexBuild()
        let everything = SearchRequest(query: "maintained", mode: .fuzzy, forceFullFuzzy: true, limit: 200, offset: 0)
        _ = try await search.search(request: everything)
        let builtHealth = await search.debugFullIndexHealth()
        XCTAssertTrue(builtHealth.isBuilt)

        var policy = StorageService.CleanupPolicy()
        policy.maxItems = 90
        let cleanup = try await storage.performCleanup(mode: .light, policy: policy)
        XCTAssertEqual(cleanup.deletedItemIDs.count, 10)
        await search.applyCommittedChanges()

        let fullHealth = await search.debugFullIndexHealth()
        XCTAssertTrue(fullHealth.isBuilt)
        XCTAssertEqual(fullHealth.tombstones, 10)
        let shortStats = await search.debugShortQueryIndexStats()
        XCTAssertTrue(shortStats.isBuilt)
        XCTAssertEqual(shortStats.tombstones, 10)

        let found = Set(try await search.search(request: everything).items.map(\.id))
        let deleted = Set(cleanup.deletedItemIDs)
        XCTAssertTrue(found.isDisjoint(with: deleted))
        XCTAssertEqual(found, Set(inserted.map(\.id)).subtracting(deleted))

        await search.close()
        await storage.close()
    }
}
