import XCTest
@testable import ScopyKit

@MainActor
final class FullIndexTombstoneUpsertStaleTests: XCTestCase {

    func testFullIndexMarksStaleAfterUpsertTombstonesAndRebuildsInBackground() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-upsert-tombstone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path
        let storage = StorageService(databasePath: dbPath)
        try await storage.open()
        var search: SearchEngineImpl?
        do {
            var firstItem: ClipboardStoredItem?
            for i in 0..<64 {
                let text = "item \(i)"
                let content = ClipboardMonitor.ClipboardContent(
                    type: .text,
                    plainText: text,
                    payload: .none,
                    appBundleID: "com.test.app",
                    contentHash: "hash-\(i)-\(UUID().uuidString)",
                    sizeBytes: text.utf8.count
                )
                let inserted = try await storage.upsertItem(content)
                if firstItem == nil { firstItem = inserted }
            }

            guard let target = firstItem else {
                XCTFail("Failed to insert seed item")
                await storage.close()
                return
            }

            let engine = SearchEngineImpl(dbPath: dbPath)
            search = engine
            try await engine.open()

            // Build full index first.
            _ = try await engine.search(request: SearchRequest(query: "item", mode: .fuzzy, sortMode: .relevance, forceFullFuzzy: true, limit: 10, offset: 0))
            var health = await engine.debugFullIndexHealth()
            XCTAssertTrue(health.isBuilt)
            XCTAssertFalse(health.isStale)
            XCTAssertEqual(health.slots, 64)
            XCTAssertEqual(health.tombstones, 0)

            // Repeated note updates should create tombstones; once past threshold, index should be marked stale and rebuilt.
            for i in 0..<64 {
                guard let updated = try await storage.updateNote(id: target.id, note: "note \(i)") else {
                    XCTFail("updateNote returned nil")
                    break
                }
                await engine.handleUpsertedItem(updated)

                let build = await engine.debugFullIndexBuildHealth()
                if build.isBuilding { break }
            }

            await engine.debugAwaitFullIndexBuild()

            health = await engine.debugFullIndexHealth()
            XCTAssertTrue(health.isBuilt)
            XCTAssertFalse(health.isStale)
            XCTAssertEqual(health.slots, 64)
            XCTAssertEqual(health.tombstones, 0)

            await engine.close()
            search = nil
            await storage.close()
        } catch {
            if let search {
                await search.close()
            }
            await storage.close()
            throw error
        }
    }
}
