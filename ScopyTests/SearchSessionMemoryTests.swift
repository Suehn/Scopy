#if DEBUG
import XCTest
@testable import ScopyKit

final class SearchSessionMemoryTests: XCTestCase {
    /// After an idle trim releases the full index, the next session reloads it and sees new rows.
    func testIdleTrimReleasesFullIndexAndNextSearchRestoresIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-session-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("clipboard.db").path

        let storage = StorageService(databasePath: dbPath)
        try await storage.open()
        func content(_ text: String) -> ClipboardMonitor.ClipboardContent {
            ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: text,
                payload: .none,
                appBundleID: "com.test.app",
                contentHash: "hash-\(text)",
                sizeBytes: text.utf8.count
            )
        }
        for i in 0..<50 {
            _ = try await storage.upsertItem(content("session entry \(i)"))
        }

        let search = SearchEngineImpl(dbPath: dbPath, commitJournal: storage.commitJournal)
        try await search.open()
        func fullFuzzy(_ query: String) -> SearchRequest {
            SearchRequest(query: query, mode: .fuzzy, forceFullFuzzy: true, limit: 100, offset: 0)
        }
        _ = try await search.search(request: fullFuzzy("session"))
        let built = await search.debugFullIndexHealth()
        XCTAssertTrue(built.isBuilt)

        await search.trimSessionMemory(.idle)
        let trimmed = await search.debugFullIndexHealth()
        XCTAssertFalse(trimmed.isBuilt)

        let added = try await storage.upsertItem(content("session zebra"))
        await search.applyCommittedChanges()

        let result = try await search.search(request: fullFuzzy("zebra"))
        XCTAssertEqual(result.items.map(\.id), [added.id])
        let restored = await search.debugFullIndexHealth()
        XCTAssertTrue(restored.isBuilt)
        let source = await search.debugFullIndexLastSnapshotSource()
        XCTAssertTrue(["diskCache", "database"].contains(source), "unexpected source \(String(describing: source))")

        await search.close()
        await storage.close()
    }
}
#endif
