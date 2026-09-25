import SQLite3
import XCTest
@testable import ScopyKit

final class FullIndexColdBuildTests: XCTestCase {
    /// A row the index cannot decode fails the cold build; publishing the index without it would
    /// make fuzzy results silently incomplete.
    func testUndecodableRowFailsColdBuildInsteadOfPublishingPartialIndex() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-cold-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("clipboard.db").path

        let connection = try SQLiteConnection(path: dbPath, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        try SQLiteMigrations.migrateIfNeeded(connection)
        for (id, type) in [("00000000-0000-4000-8000-000000000001", "text"), ("00000000-0000-4000-8000-000000000002", "bogus")] {
            try connection.execute(
                """
                INSERT INTO clipboard_items (id, type, content_hash, plain_text, created_at, last_used_at, size_bytes)
                VALUES ('\(id)', '\(type)', 'hash-\(id)', 'alpha \(type)', 1, 1, 10)
                """
            )
        }
        connection.close()

        let search = SearchEngineImpl(dbPath: dbPath)
        try await search.open()
        do {
            _ = try await search.search(
                request: SearchRequest(query: "alpha", mode: .fuzzy, forceFullFuzzy: true, limit: 10, offset: 0)
            )
            XCTFail("A cold build over an undecodable row must fail")
        } catch is CancellationError {
            XCTFail("The build failed, it was not cancelled")
        } catch {}
        #if DEBUG
        let health = await search.debugFullIndexHealth()
        XCTAssertFalse(health.isBuilt)
        #endif
        await search.close()
    }
}
