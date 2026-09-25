import Foundation

/// The schema every connection relies on once migrations have run: the current `user_version`
/// and every table that queries, triggers, and counters touch.
enum SQLiteSchema {
    enum SchemaError: Error, LocalizedError {
        case outdated(userVersion: Int32)
        case missingTable(String)

        var errorDescription: String? {
            switch self {
            case .outdated(let userVersion):
                return "Database schema version \(userVersion) predates \(SQLiteMigrations.currentUserVersion)"
            case .missingTable(let name):
                return "Required table '\(name)' not found"
            }
        }
    }

    private static let requiredTables = [
        "clipboard_items",
        "clipboard_fts",
        "clipboard_fts_trigram",
        "scopy_meta",
        "ingest_receipts",
    ]

    /// Throws unless the database is migrated to the current version and every required table
    /// exists; a current `user_version` alone does not prove that no table was dropped.
    static func requireCurrentSchema(_ connection: SQLiteConnection) throws {
        let userVersion = try SQLiteMigrations.readUserVersion(connection)
        guard userVersion >= SQLiteMigrations.currentUserVersion else {
            throw SchemaError.outdated(userVersion: userVersion)
        }

        let stmt = try connection.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?")
        for table in requiredTables {
            stmt.reset()
            try stmt.bindText(table, at: 1)
            guard try stmt.step() else { throw SchemaError.missingTable(table) }
        }
    }
}
