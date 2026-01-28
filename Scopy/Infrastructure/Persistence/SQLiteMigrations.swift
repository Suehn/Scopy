import Foundation

enum SQLiteMigrations {
    static let currentUserVersion: Int32 = 6

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
        if userVersion < 4 {
            try setupTrigramFTSIfSupported(connection)
        }
        if userVersion < 5 {
            try setupMetaTable(connection)
        }
        if userVersion < 6 {
            try setupMetaCounters(connection)
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

    private static func setupMetaTable(_ connection: SQLiteConnection) throws {
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS scopy_meta (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                mutation_seq INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        try connection.execute("INSERT OR IGNORE INTO scopy_meta (id, mutation_seq) VALUES (1, 0)")
    }

    private static func setupMetaCounters(_ connection: SQLiteConnection) throws {
        try addColumnIfNeeded(connection, table: "scopy_meta", column: "item_count", type: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfNeeded(connection, table: "scopy_meta", column: "unpinned_count", type: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfNeeded(connection, table: "scopy_meta", column: "total_size_bytes", type: "INTEGER NOT NULL DEFAULT 0")

        // Backfill counters (one-time O(n)).
        try connection.execute(
            """
            UPDATE scopy_meta
            SET item_count = (SELECT COUNT(*) FROM clipboard_items),
                unpinned_count = (SELECT COUNT(*) FROM clipboard_items WHERE is_pinned = 0),
                total_size_bytes = COALESCE((SELECT SUM(size_bytes) FROM clipboard_items), 0)
            WHERE id = 1
            """
        )

        // Triggers keep counters exact. Must NOT touch mutation_seq (bumped exactly once per commit in code).
        try connection.execute(
            """
            CREATE TRIGGER IF NOT EXISTS scopy_meta_clipboard_ai
            AFTER INSERT ON clipboard_items
            BEGIN
                UPDATE scopy_meta
                SET item_count = item_count + 1,
                    unpinned_count = unpinned_count + CASE WHEN NEW.is_pinned = 0 THEN 1 ELSE 0 END,
                    total_size_bytes = total_size_bytes + NEW.size_bytes
                WHERE id = 1;
            END
            """
        )

        try connection.execute(
            """
            CREATE TRIGGER IF NOT EXISTS scopy_meta_clipboard_ad
            AFTER DELETE ON clipboard_items
            BEGIN
                UPDATE scopy_meta
                SET item_count = item_count - 1,
                    unpinned_count = unpinned_count - CASE WHEN OLD.is_pinned = 0 THEN 1 ELSE 0 END,
                    total_size_bytes = total_size_bytes - OLD.size_bytes
                WHERE id = 1;
            END
            """
        )

        try connection.execute(
            """
            CREATE TRIGGER IF NOT EXISTS scopy_meta_clipboard_au_size
            AFTER UPDATE OF size_bytes ON clipboard_items
            WHEN OLD.size_bytes IS NOT NEW.size_bytes
            BEGIN
                UPDATE scopy_meta
                SET total_size_bytes = total_size_bytes + (NEW.size_bytes - OLD.size_bytes)
                WHERE id = 1;
            END
            """
        )

        try connection.execute(
            """
            CREATE TRIGGER IF NOT EXISTS scopy_meta_clipboard_au_pinned
            AFTER UPDATE OF is_pinned ON clipboard_items
            WHEN OLD.is_pinned IS NOT NEW.is_pinned
            BEGIN
                UPDATE scopy_meta
                SET unpinned_count = unpinned_count
                    + (CASE WHEN NEW.is_pinned = 0 THEN 1 ELSE 0 END)
                    - (CASE WHEN OLD.is_pinned = 0 THEN 1 ELSE 0 END)
                WHERE id = 1;
            END
            """
        )
    }

    private static func createIndexes(_ connection: SQLiteConnection) throws {
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_created_at ON clipboard_items(created_at DESC)")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_last_used_at ON clipboard_items(last_used_at DESC)")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_pinned ON clipboard_items(is_pinned DESC, last_used_at DESC)")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_recent_order ON clipboard_items(is_pinned DESC, last_used_at DESC, id ASC)")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_content_hash ON clipboard_items(content_hash)")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_type ON clipboard_items(type)")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_app ON clipboard_items(app_bundle_id)")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_app_last_used ON clipboard_items(app_bundle_id, last_used_at DESC)")
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

    private static func setupTrigramFTSIfSupported(_ connection: SQLiteConnection) throws {
        // Optional: FTS5 trigram tokenizer may not be available on all SQLite builds.
        // If unsupported, keep the DB usable and fall back to existing search paths.
        do {
            try connection.execute(
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts_trigram USING fts5(
                    plain_text,
                    note,
                    content='clipboard_items',
                    content_rowid='rowid',
                    tokenize='trigram'
                )
                """
            )
        } catch {
            let message = error.localizedDescription.lowercased()
            if message.contains("trigram") || message.contains("tokenizer") {
                return
            }
            throw error
        }

        try connection.execute(
            """
            CREATE TRIGGER IF NOT EXISTS clipboard_trigram_ai AFTER INSERT ON clipboard_items BEGIN
                INSERT INTO clipboard_fts_trigram(rowid, plain_text, note) VALUES (NEW.rowid, NEW.plain_text, NEW.note);
            END
            """
        )

        try connection.execute(
            """
            CREATE TRIGGER IF NOT EXISTS clipboard_trigram_ad AFTER DELETE ON clipboard_items BEGIN
                INSERT INTO clipboard_fts_trigram(clipboard_fts_trigram, rowid, plain_text, note) VALUES('delete', OLD.rowid, OLD.plain_text, OLD.note);
            END
            """
        )

        try connection.execute("DROP TRIGGER IF EXISTS clipboard_trigram_au")
        try connection.execute(
            """
            CREATE TRIGGER clipboard_trigram_au
            AFTER UPDATE OF plain_text, note ON clipboard_items
            WHEN OLD.plain_text IS NOT NEW.plain_text OR OLD.note IS NOT NEW.note
            BEGIN
                INSERT INTO clipboard_fts_trigram(clipboard_fts_trigram, rowid, plain_text, note) VALUES('delete', OLD.rowid, OLD.plain_text, OLD.note);
                INSERT INTO clipboard_fts_trigram(rowid, plain_text, note) VALUES (NEW.rowid, NEW.plain_text, NEW.note);
            END
            """
        )

        try connection.execute("INSERT INTO clipboard_fts_trigram(clipboard_fts_trigram) VALUES('rebuild')")
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
