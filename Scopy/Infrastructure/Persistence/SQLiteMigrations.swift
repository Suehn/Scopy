import Foundation

enum SQLiteMigrations {
    static let currentUserVersion: Int32 = 3

    static func migrateIfNeeded(_ connection: SQLiteConnection) throws {
        let userVersion = try readUserVersion(connection)
        if userVersion >= currentUserVersion {
            return
        }

        // v0.x baseline schema (idempotent)
        try createTables(connection)
        try createIndexes(connection)
        if userVersion < 3 {
            try addColumnIfNeeded(connection, table: "clipboard_items", column: "note", type: "TEXT")
            try addColumnIfNeeded(connection, table: "clipboard_items", column: "file_size_bytes", type: "INTEGER")
            try rebuildFTS(connection)
        } else {
            try setupFTS(connection)
        }

        try connection.execute("PRAGMA user_version = \(currentUserVersion)")
    }

    private static func readUserVersion(_ connection: SQLiteConnection) throws -> Int32 {
        let stmt = try connection.prepare("PRAGMA user_version")
        guard try stmt.step() else { return 0 }
        return Int32(stmt.columnInt(0))
    }

    private static func createTables(_ connection: SQLiteConnection) throws {
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS clipboard_items (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                plain_text TEXT,
                app_bundle_id TEXT,
                created_at REAL NOT NULL,
                last_used_at REAL NOT NULL,
                use_count INTEGER DEFAULT 1,
                is_pinned INTEGER DEFAULT 0,
                size_bytes INTEGER NOT NULL,
                storage_ref TEXT,
                raw_data BLOB,
                note TEXT,
                file_size_bytes INTEGER
            )
            """
        )

        // Legacy table kept for backward compatibility (older versions used it).
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY
            )
            """
        )
        try connection.execute("INSERT OR IGNORE INTO schema_version (version) VALUES (1)")
    }

    private static func createIndexes(_ connection: SQLiteConnection) throws {
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_created_at ON clipboard_items(created_at DESC)")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_last_used_at ON clipboard_items(last_used_at DESC)")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_pinned ON clipboard_items(is_pinned DESC, last_used_at DESC)")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_content_hash ON clipboard_items(content_hash)")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_type ON clipboard_items(type)")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_app ON clipboard_items(app_bundle_id)")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_type_recent ON clipboard_items(type, last_used_at DESC)")
    }

    private static func setupFTS(_ connection: SQLiteConnection) throws {
        try connection.execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts USING fts5(
                plain_text,
                note,
                content='clipboard_items',
                content_rowid='rowid',
                tokenize='unicode61 remove_diacritics 2'
            )
            """
        )

        try connection.execute(
            """
            CREATE TRIGGER IF NOT EXISTS clipboard_ai AFTER INSERT ON clipboard_items BEGIN
                INSERT INTO clipboard_fts(rowid, plain_text, note) VALUES (NEW.rowid, NEW.plain_text, NEW.note);
            END
            """
        )

        try connection.execute(
            """
            CREATE TRIGGER IF NOT EXISTS clipboard_ad AFTER DELETE ON clipboard_items BEGIN
                INSERT INTO clipboard_fts(clipboard_fts, rowid, plain_text, note) VALUES('delete', OLD.rowid, OLD.plain_text, OLD.note);
            END
            """
        )

        // v2: Avoid FTS churn on metadata-only updates (last_used_at/use_count/is_pinned).
        // Only refresh FTS row when plain_text or note changes.
        try connection.execute("DROP TRIGGER IF EXISTS clipboard_au")
        try connection.execute(
            """
            CREATE TRIGGER clipboard_au
            AFTER UPDATE OF plain_text, note ON clipboard_items
            WHEN OLD.plain_text IS NOT NEW.plain_text OR OLD.note IS NOT NEW.note
            BEGIN
                INSERT INTO clipboard_fts(clipboard_fts, rowid, plain_text, note) VALUES('delete', OLD.rowid, OLD.plain_text, OLD.note);
                INSERT INTO clipboard_fts(rowid, plain_text, note) VALUES (NEW.rowid, NEW.plain_text, NEW.note);
            END
            """
        )
    }

    private static func addColumnIfNeeded(
        _ connection: SQLiteConnection,
        table: String,
        column: String,
        type: String
    ) throws {
        let stmt = try connection.prepare("PRAGMA table_info(\(table))")
        while try stmt.step() {
            if let name = stmt.columnText(1), name == column {
                return
            }
        }
        try connection.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
    }

    private static func rebuildFTS(_ connection: SQLiteConnection) throws {
        try connection.execute("DROP TRIGGER IF EXISTS clipboard_ai")
        try connection.execute("DROP TRIGGER IF EXISTS clipboard_ad")
        try connection.execute("DROP TRIGGER IF EXISTS clipboard_au")
        try connection.execute("DROP TABLE IF EXISTS clipboard_fts")
        try setupFTS(connection)
        try connection.execute("INSERT INTO clipboard_fts(clipboard_fts) VALUES('rebuild')")
    }
}
