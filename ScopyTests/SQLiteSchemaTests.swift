import SQLite3
import XCTest
@testable import ScopyKit

final class SQLiteSchemaTests: XCTestCase {
    /// A current `user_version` does not vouch for the tables: the search engine refuses a
    /// database that lost any table its queries, triggers, or counters need.
    func testEngineRejectsDatabaseMissingRequiredTables() async throws {
        let intact = SearchEngineImpl(dbPath: try makeMigratedDatabase())
        try await intact.open()
        await intact.close()

        for table in ["clipboard_items", "clipboard_fts", "clipboard_fts_trigram", "scopy_meta", "ingest_receipts"] {
            let path = try makeMigratedDatabase()
            let connection = try SQLiteConnection(path: path, flags: SQLITE_OPEN_READWRITE)
            try connection.execute("DROP TABLE \(table)")
            connection.close()

            let engine = SearchEngineImpl(dbPath: path)
            do {
                try await engine.open()
                XCTFail("Opened a database without \(table)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("'\(table)'"), "\(table): \(error)")
            }
            await engine.close()
        }
    }

    private func makeMigratedDatabase() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-schema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clipboard.db").path

        let connection = try SQLiteConnection(path: path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        defer { connection.close() }
        try SQLiteMigrations.migrateIfNeeded(connection)
        return path
    }
}
