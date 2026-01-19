import XCTest
@testable import ScopyKit

@MainActor
final class FullIndexPendingEventsCleanupTests: XCTestCase {

    func testFullIndexPendingEventsAreClearedWhenBackgroundBuildIsCancelled() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-fullindex-pending-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path
        let storage = StorageService(databasePath: dbPath)
        try await storage.open()
        var search: SearchEngineImpl?
        do {
            let largeSuffix = String(repeating: "x", count: 4096)
            var anyItem: ClipboardStoredItem?
            for i in 0..<600 {
                let text = "item \(i) \(largeSuffix)"
                let content = ClipboardMonitor.ClipboardContent(
                    type: .text,
                    plainText: text,
                    payload: .none,
                    appBundleID: "com.test.app",
                    contentHash: "hash-\(i)-\(UUID().uuidString)",
                    sizeBytes: text.utf8.count
                )
                let inserted = try await storage.upsertItem(content)
                if anyItem == nil { anyItem = inserted }
            }

            guard let item = anyItem else {
                XCTFail("Missing seed item")
                await storage.close()
                return
            }

            let engine = SearchEngineImpl(dbPath: dbPath)
            search = engine
            try await engine.open()

            await engine.debugStartFullIndexBuild(force: true)
            var build = await engine.debugFullIndexBuildHealth()
            XCTAssertTrue(build.isBuilding)

            // Enqueue a pending event while the index is building.
            await engine.handleUpsertedItem(item)
            build = await engine.debugFullIndexBuildHealth()
            XCTAssertGreaterThanOrEqual(build.pendingEvents, 1)

            // Cancel build and ensure pending events are cleared.
            await engine.debugCancelFullIndexBuild()
            await engine.debugAwaitFullIndexBuild()

            build = await engine.debugFullIndexBuildHealth()
            XCTAssertFalse(build.isBuilding)
            XCTAssertEqual(build.pendingEvents, 0)

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
