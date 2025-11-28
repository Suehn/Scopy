import AppKit
import Foundation
import SQLite3

/// StorageService - 数据持久化服务
/// 符合 v0.md 第2节：分级存储（小内容SQLite内联，大内容外部文件）
@MainActor
final class StorageService {
    // MARK: - Types

    enum StorageError: Error, LocalizedError {
        case databaseNotOpen
        case queryFailed(String)
        case insertFailed(String)
        case updateFailed(String)
        case deleteFailed(String)
        case fileOperationFailed(String)
        case migrationFailed(String)

        var errorDescription: String? {
            switch self {
            case .databaseNotOpen: return "Database is not open"
            case .queryFailed(let msg): return "Query failed: \(msg)"
            case .insertFailed(let msg): return "Insert failed: \(msg)"
            case .updateFailed(let msg): return "Update failed: \(msg)"
            case .deleteFailed(let msg): return "Delete failed: \(msg)"
            case .fileOperationFailed(let msg): return "File operation failed: \(msg)"
            case .migrationFailed(let msg): return "Migration failed: \(msg)"
            }
        }
    }

    /// Internal storage model
    struct StoredItem {
        let id: UUID
        let type: ClipboardItemType
        let contentHash: String
        let plainText: String
        let appBundleID: String?
        let createdAt: Date
        var lastUsedAt: Date
        var useCount: Int
        var isPinned: Bool
        let sizeBytes: Int
        let storageRef: String? // nil for inline, path for external
        let rawData: Data?      // inline raw data (for small content)
    }

    // MARK: - Configuration

    /// Threshold for external storage (v0.md: 小内容 < X KB)
    static let externalStorageThreshold = 100 * 1024 // 100 KB

    /// Default cleanup settings (v0.md 2.1)
    struct CleanupSettings {
        var maxItems: Int = 10_000
        var maxDaysAge: Int? = nil // nil = unlimited
        var maxSmallStorageMB: Int = 200
        var maxLargeStorageMB: Int = 800
    }

    // MARK: - Properties

    private var db: OpaquePointer?
    private let dbPath: String
    private let externalStoragePath: String
    private let thumbnailCachePath: String

    var cleanupSettings = CleanupSettings()

    /// 暴露数据库连接给 SearchService 使用
    var database: OpaquePointer? { db }

    /// 数据库文件路径（用于设置窗口显示）
    var databaseFilePath: String { dbPath }

    // MARK: - Initialization

    init(databasePath: String? = nil) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let scopyDir = appSupport.appendingPathComponent("Scopy", isDirectory: true)

        // Create directories if needed
        try? FileManager.default.createDirectory(at: scopyDir, withIntermediateDirectories: true)

        self.dbPath = databasePath ?? scopyDir.appendingPathComponent("clipboard.db").path
        self.externalStoragePath = scopyDir.appendingPathComponent("content", isDirectory: true).path
        self.thumbnailCachePath = scopyDir.appendingPathComponent("thumbnails", isDirectory: true).path

        try? FileManager.default.createDirectory(atPath: externalStoragePath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: thumbnailCachePath, withIntermediateDirectories: true)
    }

    deinit {
        // Close database directly in deinit (synchronous cleanup)
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }

    // MARK: - Database Lifecycle

    func open() throws {
        guard db == nil else { return }

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            let error = String(cString: sqlite3_errmsg(db))
            throw StorageError.queryFailed("Failed to open database: \(error)")
        }

        // Enable WAL mode for better concurrent read performance
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA cache_size = -64000") // 64MB cache
        try execute("PRAGMA temp_store = MEMORY")

        try createTables()
        try createIndexes()
        try setupFTS()
    }

    func close() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }

    // MARK: - Schema

    private func createTables() throws {
        // Main items table
        try execute("""
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
                raw_data BLOB
            )
        """)

        // Schema version for migrations
        try execute("""
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY
            )
        """)

        // Insert initial version if needed
        try execute("INSERT OR IGNORE INTO schema_version (version) VALUES (1)")
    }

    private func createIndexes() throws {
        // v0.md 3.1: 索引设计
        try execute("CREATE INDEX IF NOT EXISTS idx_created_at ON clipboard_items(created_at DESC)")
        try execute("CREATE INDEX IF NOT EXISTS idx_last_used_at ON clipboard_items(last_used_at DESC)")
        try execute("CREATE INDEX IF NOT EXISTS idx_pinned ON clipboard_items(is_pinned DESC, last_used_at DESC)")
        try execute("CREATE INDEX IF NOT EXISTS idx_content_hash ON clipboard_items(content_hash)")
        try execute("CREATE INDEX IF NOT EXISTS idx_type ON clipboard_items(type)")
        try execute("CREATE INDEX IF NOT EXISTS idx_app ON clipboard_items(app_bundle_id)")
    }

    private func setupFTS() throws {
        // v0.md 4.2: SQLite FTS5 索引
        try execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts USING fts5(
                plain_text,
                content='clipboard_items',
                content_rowid='rowid',
                tokenize='unicode61 remove_diacritics 2'
            )
        """)

        // Triggers to keep FTS in sync
        try execute("""
            CREATE TRIGGER IF NOT EXISTS clipboard_ai AFTER INSERT ON clipboard_items BEGIN
                INSERT INTO clipboard_fts(rowid, plain_text) VALUES (NEW.rowid, NEW.plain_text);
            END
        """)

        try execute("""
            CREATE TRIGGER IF NOT EXISTS clipboard_ad AFTER DELETE ON clipboard_items BEGIN
                INSERT INTO clipboard_fts(clipboard_fts, rowid, plain_text) VALUES('delete', OLD.rowid, OLD.plain_text);
            END
        """)

        try execute("""
            CREATE TRIGGER IF NOT EXISTS clipboard_au AFTER UPDATE ON clipboard_items BEGIN
                INSERT INTO clipboard_fts(clipboard_fts, rowid, plain_text) VALUES('delete', OLD.rowid, OLD.plain_text);
                INSERT INTO clipboard_fts(rowid, plain_text) VALUES (NEW.rowid, NEW.plain_text);
            END
        """)
    }

    // MARK: - CRUD Operations

    /// Insert or update item (handles deduplication per v0.md 3.2)
    func upsertItem(_ content: ClipboardMonitor.ClipboardContent) throws -> StoredItem {
        guard db != nil else { throw StorageError.databaseNotOpen }

        // Check for duplicate by content hash (v0.md 3.2)
        if let existing = try findByHash(content.contentHash) {
            // Update lastUsedAt and useCount instead of creating new
            var updated = existing
            updated.lastUsedAt = Date()
            updated.useCount += 1
            try updateItem(updated)
            return updated
        }

        let id = UUID()
        let now = Date()
        var storageRef: String? = nil
        var inlineData: Data? = nil

        // Decide storage location based on size (v0.md 2.1)
        if content.sizeBytes >= Self.externalStorageThreshold, let rawData = content.rawData {
            storageRef = try storeExternally(id: id, data: rawData, type: content.type)
        } else {
            inlineData = content.rawData
        }

        let sql = """
            INSERT INTO clipboard_items
            (id, type, content_hash, plain_text, app_bundle_id, created_at, last_used_at, use_count, is_pinned, size_bytes, storage_ref, raw_data)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1, 0, ?, ?, ?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, content.type.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, content.contentHash, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, content.plainText, -1, SQLITE_TRANSIENT)
        if let appID = content.appBundleID {
            sqlite3_bind_text(stmt, 5, appID, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_double(stmt, 6, now.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 7, now.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 8, Int32(content.sizeBytes))
        if let ref = storageRef {
            sqlite3_bind_text(stmt, 9, ref, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        if let data = inlineData {
            sqlite3_bind_blob(stmt, 10, (data as NSData).bytes, Int32(data.count), SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 10)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StorageError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }

        return StoredItem(
            id: id,
            type: content.type,
            contentHash: content.contentHash,
            plainText: content.plainText,
            appBundleID: content.appBundleID,
            createdAt: now,
            lastUsedAt: now,
            useCount: 1,
            isPinned: false,
            sizeBytes: content.sizeBytes,
            storageRef: storageRef,
            rawData: inlineData
        )
    }

    func findByHash(_ hash: String) throws -> StoredItem? {
        guard db != nil else { throw StorageError.databaseNotOpen }

        let sql = "SELECT * FROM clipboard_items WHERE content_hash = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, hash, -1, SQLITE_TRANSIENT)

        if sqlite3_step(stmt) == SQLITE_ROW, let stmt = stmt {
            return parseItem(from: stmt)
        }
        return nil
    }

    func findByID(_ id: UUID) throws -> StoredItem? {
        guard db != nil else { throw StorageError.databaseNotOpen }

        let sql = "SELECT * FROM clipboard_items WHERE id = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)

        if sqlite3_step(stmt) == SQLITE_ROW, let stmt = stmt {
            return parseItem(from: stmt)
        }
        return nil
    }

    /// Fetch recent items with pagination (v0.md 2.2)
    func fetchRecent(limit: Int, offset: Int) throws -> [StoredItem] {
        guard db != nil else { throw StorageError.databaseNotOpen }

        // Pinned items first, then by lastUsedAt
        let sql = """
            SELECT * FROM clipboard_items
            ORDER BY is_pinned DESC, last_used_at DESC
            LIMIT ? OFFSET ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))
        sqlite3_bind_int(stmt, 2, Int32(offset))

        var items: [StoredItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let stmt = stmt, let item = parseItem(from: stmt) {
                items.append(item)
            }
        }
        return items
    }

    func updateItem(_ item: StoredItem) throws {
        guard db != nil else { throw StorageError.databaseNotOpen }

        let sql = """
            UPDATE clipboard_items
            SET last_used_at = ?, use_count = ?, is_pinned = ?
            WHERE id = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, item.lastUsedAt.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 2, Int32(item.useCount))
        sqlite3_bind_int(stmt, 3, item.isPinned ? 1 : 0)
        sqlite3_bind_text(stmt, 4, item.id.uuidString, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StorageError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func deleteItem(_ id: UUID) throws {
        guard db != nil else { throw StorageError.databaseNotOpen }

        // First get the item to clean up external storage
        if let item = try findByID(id), let storageRef = item.storageRef {
            try? FileManager.default.removeItem(atPath: storageRef)
        }

        let sql = "DELETE FROM clipboard_items WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StorageError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func deleteAllExceptPinned() throws {
        guard db != nil else { throw StorageError.databaseNotOpen }

        // Get external storage refs first
        let sql1 = "SELECT storage_ref FROM clipboard_items WHERE is_pinned = 0 AND storage_ref IS NOT NULL"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql1, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }

        var refs: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                refs.append(String(cString: cStr))
            }
        }
        sqlite3_finalize(stmt)

        // Delete files
        for ref in refs {
            try? FileManager.default.removeItem(atPath: ref)
        }

        // Delete from DB
        try execute("DELETE FROM clipboard_items WHERE is_pinned = 0")
    }

    func setPin(_ id: UUID, pinned: Bool) throws {
        guard db != nil else { throw StorageError.databaseNotOpen }

        let sql = "UPDATE clipboard_items SET is_pinned = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, pinned ? 1 : 0)
        sqlite3_bind_text(stmt, 2, id.uuidString, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StorageError.updateFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Statistics

    func getItemCount() throws -> Int {
        guard db != nil else { throw StorageError.databaseNotOpen }

        let sql = "SELECT COUNT(*) FROM clipboard_items"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    func getTotalSize() throws -> Int {
        guard db != nil else { throw StorageError.databaseNotOpen }

        let sql = "SELECT SUM(size_bytes) FROM clipboard_items"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    func getExternalStorageSize() throws -> Int {
        let url = URL(fileURLWithPath: externalStoragePath)
        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey]

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys)
        ) else {
            return 0
        }

        var totalSize = 0
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys),
                  let size = resourceValues.fileSize else { continue }
            totalSize += size
        }
        return totalSize
    }

    /// 获取数据库文件的实际磁盘大小（包含 WAL 和 SHM 文件）
    func getDatabaseFileSize() -> Int {
        let fm = FileManager.default
        var total = 0
        // SQLite WAL 模式会创建 .db-wal 和 .db-shm 文件
        for ext in ["", "-wal", "-shm"] {
            let path = dbPath + ext
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int {
                total += size
            }
        }
        return total
    }

    /// 获取最近使用的 app 列表（用于过滤）
    func getRecentApps(limit: Int) throws -> [String] {
        guard db != nil else { throw StorageError.databaseNotOpen }

        let sql = """
            SELECT app_bundle_id FROM clipboard_items
            WHERE app_bundle_id IS NOT NULL AND app_bundle_id != ''
            GROUP BY app_bundle_id
            ORDER BY MAX(last_used_at) DESC
            LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var apps: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                apps.append(String(cString: cStr))
            }
        }
        return apps
    }

    // MARK: - Cleanup (v0.md 2.3)

    func performCleanup() throws {
        guard db != nil else { throw StorageError.databaseNotOpen }

        // 1. By count
        let currentCount = try getItemCount()
        if currentCount > cleanupSettings.maxItems {
            try cleanupByCount(target: cleanupSettings.maxItems)
        }

        // 2. By age (if configured)
        if let maxDays = cleanupSettings.maxDaysAge {
            try cleanupByAge(maxDays: maxDays)
        }

        // 3. By space (small content / database)
        let dbSize = try getTotalSize()
        let maxSmallBytes = cleanupSettings.maxSmallStorageMB * 1024 * 1024
        if dbSize > maxSmallBytes {
            try cleanupBySize(targetBytes: maxSmallBytes)
        }

        // 4. By space (large content / external storage) - v0.9
        let externalSize = try getExternalStorageSize()
        let maxLargeBytes = cleanupSettings.maxLargeStorageMB * 1024 * 1024
        if externalSize > maxLargeBytes {
            try cleanupExternalStorage(targetBytes: maxLargeBytes)
        }

        // 5. SQLite housekeeping (v0.md 2.3)
        try execute("PRAGMA incremental_vacuum(100)")
    }

    /// v0.10.4: 检查 sqlite3_step 返回值
    private func cleanupByCount(target: Int) throws {
        // Delete oldest non-pinned items beyond limit
        let sql = """
            DELETE FROM clipboard_items
            WHERE id IN (
                SELECT id FROM clipboard_items
                WHERE is_pinned = 0
                ORDER BY last_used_at ASC
                LIMIT (SELECT MAX(0, COUNT(*) - ?) FROM clipboard_items WHERE is_pinned = 0)
            )
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(target))
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw StorageError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// v0.10.4: 检查 sqlite3_step 返回值
    private func cleanupByAge(maxDays: Int) throws {
        let cutoff = Date().addingTimeInterval(-Double(maxDays * 24 * 3600))

        let sql = "DELETE FROM clipboard_items WHERE is_pinned = 0 AND created_at < ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw StorageError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// v0.10.4: 修复无限循环风险，当没有可删除项目时立即退出
    private func cleanupBySize(targetBytes: Int) throws {
        // Delete oldest items until under target size
        while try getTotalSize() > targetBytes {
            // Get the oldest non-pinned item
            let sql = """
                SELECT id FROM clipboard_items
                WHERE is_pinned = 0
                ORDER BY last_used_at ASC
                LIMIT 100
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }

            var idsToDelete: [UUID] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 0),
                   let id = UUID(uuidString: String(cString: cStr)) {
                    idsToDelete.append(id)
                }
            }
            sqlite3_finalize(stmt)

            // 没有可删除的项目（全部被 pin），退出循环防止无限循环
            if idsToDelete.isEmpty { break }

            for id in idsToDelete {
                try deleteItem(id)
                if try getTotalSize() <= targetBytes { break }
            }
        }
    }

    /// 清理外部存储（大内容）- v0.9
    /// v0.10.4: 添加注释说明无限循环防护
    private func cleanupExternalStorage(targetBytes: Int) throws {
        // 获取有外部存储的最旧非置顶项目
        while try getExternalStorageSize() > targetBytes {
            let sql = """
                SELECT id FROM clipboard_items
                WHERE is_pinned = 0 AND storage_ref IS NOT NULL
                ORDER BY last_used_at ASC
                LIMIT 100
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }

            var idsToDelete: [UUID] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 0),
                   let id = UUID(uuidString: String(cString: cStr)) {
                    idsToDelete.append(id)
                }
            }
            sqlite3_finalize(stmt)

            // 没有可删除的项目（全部被 pin 或无外部存储），退出循环防止无限循环
            if idsToDelete.isEmpty { break }

            for id in idsToDelete {
                try deleteItem(id)
                if try getExternalStorageSize() <= targetBytes { break }
            }
        }
    }

    // MARK: - External Storage

    private func storeExternally(id: UUID, data: Data, type: ClipboardItemType) throws -> String {
        let ext: String
        switch type {
        case .image: ext = "png"
        case .rtf: ext = "rtf"
        case .html: ext = "html"
        default: ext = "dat"
        }

        let filename = "\(id.uuidString).\(ext)"
        let path = (externalStoragePath as NSString).appendingPathComponent(filename)

        do {
            try data.write(to: URL(fileURLWithPath: path))
            return path
        } catch {
            throw StorageError.fileOperationFailed("Failed to write external file: \(error)")
        }
    }

    func loadExternalData(path: String) throws -> Data {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw StorageError.fileOperationFailed("Failed to read external file: \(error)")
        }
    }

    // MARK: - Thumbnail Cache (v0.8)

    /// 获取缩略图路径（如果存在）
    func getThumbnailPath(for contentHash: String) -> String? {
        let path = (thumbnailCachePath as NSString).appendingPathComponent("\(contentHash).png")
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
        return nil
    }

    /// 保存缩略图
    func saveThumbnail(_ data: Data, for contentHash: String) throws {
        let path = (thumbnailCachePath as NSString).appendingPathComponent("\(contentHash).png")
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            throw StorageError.fileOperationFailed("Failed to save thumbnail: \(error)")
        }
    }

    /// 生成并保存缩略图（从原图数据）
    /// - Parameters:
    ///   - imageData: 原图数据
    ///   - contentHash: 内容哈希（用于命名）
    ///   - maxHeight: 最大高度
    /// - Returns: 缩略图路径
    func generateThumbnail(from imageData: Data, contentHash: String, maxHeight: Int) -> String? {
        // 检查是否已存在
        if let existing = getThumbnailPath(for: contentHash) {
            return existing
        }

        guard let nsImage = NSImage(data: imageData) else { return nil }
        let originalSize = nsImage.size

        // 计算缩放比例
        let scale = CGFloat(maxHeight) / originalSize.height
        let newWidth = originalSize.width * scale
        let newHeight = CGFloat(maxHeight)

        // 创建缩略图
        let newImage = NSImage(size: NSSize(width: newWidth, height: newHeight))
        newImage.lockFocus()
        nsImage.draw(in: NSRect(x: 0, y: 0, width: newWidth, height: newHeight),
                     from: NSRect(origin: .zero, size: originalSize),
                     operation: .copy,
                     fraction: 1.0)
        newImage.unlockFocus()

        // 转换为 PNG 数据
        guard let tiffData = newImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        // 保存
        let path = (thumbnailCachePath as NSString).appendingPathComponent("\(contentHash).png")
        do {
            try pngData.write(to: URL(fileURLWithPath: path))
            return path
        } catch {
            print("Failed to save thumbnail: \(error)")
            return nil
        }
    }

    /// 获取原图数据（用于预览）
    func getOriginalImageData(for item: StoredItem) -> Data? {
        if let storageRef = item.storageRef {
            return try? loadExternalData(path: storageRef)
        }
        return item.rawData
    }

    /// 清空缩略图缓存（设置变更时调用）
    func clearThumbnailCache() {
        try? FileManager.default.removeItem(atPath: thumbnailCachePath)
        try? FileManager.default.createDirectory(atPath: thumbnailCachePath,
                                                 withIntermediateDirectories: true)
    }

    /// 清理缩略图缓存（LRU 策略）
    func cleanupThumbnailCache(maxSizeMB: Int = 50) {
        let maxBytes = maxSizeMB * 1024 * 1024
        let url = URL(fileURLWithPath: thumbnailCachePath)

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey]
        ) else { return }

        var files: [(url: URL, size: Int, accessDate: Date)] = []
        var totalSize = 0

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey]),
                  let size = values.fileSize,
                  let accessDate = values.contentAccessDate else { continue }
            files.append((fileURL, size, accessDate))
            totalSize += size
        }

        // 如果超出限制，按访问时间排序删除最旧的
        if totalSize > maxBytes {
            files.sort { $0.accessDate < $1.accessDate }
            for file in files {
                if totalSize <= maxBytes { break }
                try? FileManager.default.removeItem(at: file.url)
                totalSize -= file.size
            }
        }
    }

    // MARK: - Helpers

    private func execute(_ sql: String) throws {
        guard db != nil else { throw StorageError.databaseNotOpen }

        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let error = errMsg.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errMsg)
            throw StorageError.queryFailed(error)
        }
    }

    private func parseItem(from stmt: OpaquePointer) -> StoredItem? {
        guard let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              let id = UUID(uuidString: idStr),
              let typeStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
              let type = ClipboardItemType(rawValue: typeStr),
              let hashStr = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }) else {
            return nil
        }

        let plainText = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
        let appBundleID = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
        let lastUsedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
        let useCount = Int(sqlite3_column_int(stmt, 7))
        let isPinned = sqlite3_column_int(stmt, 8) != 0
        let sizeBytes = Int(sqlite3_column_int(stmt, 9))
        let storageRef = sqlite3_column_text(stmt, 10).map { String(cString: $0) }

        // Read inline raw_data (column 11)
        var rawData: Data? = nil
        let blobBytes = sqlite3_column_blob(stmt, 11)
        let blobSize = sqlite3_column_bytes(stmt, 11)
        if let bytes = blobBytes, blobSize > 0 {
            rawData = Data(bytes: bytes, count: Int(blobSize))
        }

        return StoredItem(
            id: id,
            type: type,
            contentHash: hashStr,
            plainText: plainText,
            appBundleID: appBundleID,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            useCount: useCount,
            isPinned: isPinned,
            sizeBytes: sizeBytes,
            storageRef: storageRef,
            rawData: rawData
        )
    }
}

// MARK: - SQLITE_TRANSIENT helper

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
