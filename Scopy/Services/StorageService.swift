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

    /// v0.10.8: 外部存储大小缓存（避免重复遍历文件系统）
    private var cachedExternalSize: (size: Int, timestamp: Date)?
    private let externalSizeCacheTTL: TimeInterval = 180  // 延长缓存，降低频繁遍历

    /// v0.22: 保护 cachedExternalSize 的锁，防止后台线程和主线程之间的数据竞争
    private let externalSizeCacheLock = NSLock()

    /// 暴露数据库连接给 SearchService 使用
    var database: OpaquePointer? { db }

    /// 数据库文件路径（用于设置窗口显示）
    var databaseFilePath: String { dbPath }

    // MARK: - Initialization

    init(databasePath: String? = nil) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let scopyDir = appSupport.appendingPathComponent("Scopy", isDirectory: true)

        // v0.22: 改进目录创建错误处理 - 记录错误但不阻止初始化
        // 目录创建失败通常是权限问题，后续操作会有更具体的错误
        do {
            try FileManager.default.createDirectory(at: scopyDir, withIntermediateDirectories: true)
        } catch {
            print("⚠️ StorageService: Failed to create app directory: \(error.localizedDescription)")
        }

        self.dbPath = databasePath ?? scopyDir.appendingPathComponent("clipboard.db").path
        self.externalStoragePath = scopyDir.appendingPathComponent("content", isDirectory: true).path
        self.thumbnailCachePath = scopyDir.appendingPathComponent("thumbnails", isDirectory: true).path

        do {
            try FileManager.default.createDirectory(atPath: externalStoragePath, withIntermediateDirectories: true)
        } catch {
            print("⚠️ StorageService: Failed to create external storage directory: \(error.localizedDescription)")
        }

        do {
            try FileManager.default.createDirectory(atPath: thumbnailCachePath, withIntermediateDirectories: true)
        } catch {
            print("⚠️ StorageService: Failed to create thumbnail cache directory: \(error.localizedDescription)")
        }
    }

    deinit {
        // Close database directly in deinit (synchronous cleanup)
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }

    // MARK: - Database Lifecycle

    /// v0.11: 修复半打开状态问题 - 使用临时变量，失败时确保清理
    func open() throws {
        guard db == nil else { return }

        // 使用临时变量，避免半打开状态
        var tempDb: OpaquePointer?
        let openResult = sqlite3_open(dbPath, &tempDb)

        if openResult != SQLITE_OK {
            let error: String
            if let tempDb = tempDb {
                error = String(cString: sqlite3_errmsg(tempDb))
                sqlite3_close(tempDb)  // 清理部分打开的连接
            } else {
                error = "Unknown error (code: \(openResult))"
            }
            throw StorageError.queryFailed("Failed to open database: \(error)")
        }

        // 确保 tempDb 不为 nil
        guard let validDb = tempDb else {
            throw StorageError.queryFailed("Failed to open database: connection is nil")
        }

        // 尝试执行 PRAGMA 设置，失败时清理
        do {
            // Enable WAL mode for better concurrent read performance
            try executeOn(validDb, "PRAGMA journal_mode = WAL")
            try executeOn(validDb, "PRAGMA synchronous = NORMAL")
            try executeOn(validDb, "PRAGMA cache_size = -64000") // 64MB cache
            try executeOn(validDb, "PRAGMA temp_store = MEMORY")

            // 成功后才赋值给实例变量
            self.db = validDb

            try createTables()
            try createIndexes()
            try setupFTS()

            // v0.20: 验证 schema 完整性，确保所有表都正确创建
            try verifySchema()
        } catch {
            // PRAGMA 或 schema 设置失败，清理连接
            // v0.17: 确保重置 self.db，避免指向已关闭的连接
            self.db = nil
            sqlite3_close(validDb)
            throw error
        }
    }

    /// v0.11: 在指定数据库连接上执行 SQL（用于初始化阶段）
    private func executeOn(_ db: OpaquePointer, _ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let error = errMsg.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errMsg)
            throw StorageError.queryFailed(error)
        }
    }

    /// v0.11: 执行 WAL 检查点（定期调用以控制 WAL 文件大小）
    func performWALCheckpoint() {
        guard let db = db else { return }
        // PASSIVE 模式：不阻塞写入，尽可能多地检查点
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
    }

    /// v0.20: 验证数据库 schema 完整性
    /// 确保主表和 FTS 表都存在，防止半打开状态导致后续操作失败
    private func verifySchema() throws {
        guard let db = db else {
            throw StorageError.databaseNotOpen
        }

        // 检查主表是否存在
        let mainTableSQL = "SELECT name FROM sqlite_master WHERE type='table' AND name='clipboard_items'"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, mainTableSQL, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) != SQLITE_ROW {
                throw StorageError.migrationFailed("Main table 'clipboard_items' not found")
            }
        } else {
            throw StorageError.queryFailed("Failed to verify main table")
        }

        // 检查 FTS 表是否存在
        let ftsTableSQL = "SELECT name FROM sqlite_master WHERE type='table' AND name='clipboard_fts'"
        if sqlite3_prepare_v2(db, ftsTableSQL, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) != SQLITE_ROW {
                throw StorageError.migrationFailed("FTS table 'clipboard_fts' not found")
            }
        } else {
            throw StorageError.queryFailed("Failed to verify FTS table")
        }
    }

    /// v0.20: 关闭前执行 WAL 检查点，确保数据完整写入
    func close() {
        if db != nil {
            // 执行 WAL 检查点，将 WAL 日志合并到主数据库文件
            performWALCheckpoint()
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
        try execute("CREATE INDEX IF NOT EXISTS idx_type_recent ON clipboard_items(type, last_used_at DESC)")
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
    /// v0.13: 预分配数组容量，避免多次重新分配
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

        // v0.13: 预分配数组容量
        var items: [StoredItem] = []
        items.reserveCapacity(limit)

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
        // v0.19: 添加错误日志
        if let item = try findByID(id), let storageRef = item.storageRef {
            do {
                try FileManager.default.removeItem(atPath: storageRef)
            } catch {
                print("⚠️ StorageService: Failed to delete external file '\(storageRef)': \(error.localizedDescription)")
            }
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
        // v0.23: 添加错误日志，便于追踪文件删除失败
        for ref in refs {
            do {
                try FileManager.default.removeItem(atPath: ref)
            } catch {
                print("⚠️ StorageService: Failed to delete external file during clearAll: \(error.localizedDescription)")
            }
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
            let value = sqlite3_column_int64(stmt, 0)
            return Int(min(value, Int64(Int.max)))
        }
        return 0
    }

    /// v0.10.8: 使用缓存避免重复遍历文件系统
    /// v0.22: 使用锁保护缓存访问，防止数据竞争
    func getExternalStorageSize() throws -> Int {
        // 检查缓存是否有效（加锁读取）
        if let cached = externalSizeCacheLock.withLock({ cachedExternalSize }),
           Date().timeIntervalSince(cached.timestamp) < externalSizeCacheTTL {
            return cached.size
        }

        // 计算实际大小
        let size = try calculateExternalStorageSize()
        externalSizeCacheLock.withLock {
            cachedExternalSize = (size, Date())
        }
        return size
    }

    /// 实际计算外部存储大小（不使用缓存）
    private func calculateExternalStorageSize() throws -> Int {
        return try Self.calculateDirectorySize(at: externalStoragePath)
    }

    /// 静态目录大小计算，便于后台线程使用
    nonisolated private static func calculateDirectorySize(at path: String) throws -> Int {
        let url = URL(fileURLWithPath: path)
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

    /// v0.10.8: 使外部存储大小缓存失效
    /// v0.22: 使用锁保护缓存访问，防止数据竞争
    private func invalidateExternalSizeCache() {
        externalSizeCacheLock.withLock {
            cachedExternalSize = nil
        }
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

    /// v0.15.2: 获取外部存储大小（强制刷新，不使用缓存）
    /// 用于 Settings 页面显示准确的存储统计（后台线程计算，避免阻塞主线程）
    func getExternalStorageSizeForStats() async throws -> Int {
        let path = externalStoragePath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let size = try Self.calculateDirectorySize(at: path)
                    continuation.resume(returning: size)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// v0.15.2: 获取缩略图缓存大小
    func getThumbnailCacheSize() async -> Int {
        let path = thumbnailCachePath
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let url = URL(fileURLWithPath: path)
                let resourceKeys: Set<URLResourceKey> = [.fileSizeKey]

                guard let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: Array(resourceKeys)
                ) else {
                    continuation.resume(returning: 0)
                    return
                }

                var totalSize = 0
                for case let fileURL as URL in enumerator {
                    guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys),
                          let size = resourceValues.fileSize else { continue }
                    totalSize += size
                }
                continuation.resume(returning: totalSize)
            }
        }
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

        // 6. v0.15: Clean up orphaned files (files not referenced in database)
        try cleanupOrphanedFiles()
    }

    /// v0.15: Clean up orphaned files in external storage directory
    /// Files that exist on disk but have no corresponding database record
    /// This fixes the storage leak where files accumulate without being tracked
    /// v0.19: 修复 - 文件删除移到后台线程，避免阻塞主线程
    func cleanupOrphanedFiles() throws {
        guard db != nil else { throw StorageError.databaseNotOpen }

        // 1. Get all storage_ref values from database
        let sql = "SELECT storage_ref FROM clipboard_items WHERE storage_ref IS NOT NULL AND storage_ref <> ''"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var validRefs = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                let ref = String(cString: cStr)
                // Extract filename from full path (storage_ref stores full path)
                let filename = (ref as NSString).lastPathComponent
                validRefs.insert(filename)
            }
        }

        // 2. Enumerate all files in content directory
        let contentURL = URL(fileURLWithPath: externalStoragePath)
        guard let enumerator = FileManager.default.enumerator(
            at: contentURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }

        var orphanedFiles: [URL] = []
        for case let fileURL as URL in enumerator {
            let filename = fileURL.lastPathComponent
            if !validRefs.contains(filename) {
                orphanedFiles.append(fileURL)
            }
        }

        // 3. Delete orphaned files in background (non-blocking)
        // v0.19: 移到后台线程执行，避免阻塞主线程
        if !orphanedFiles.isEmpty {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let group = DispatchGroup()
                let queue = DispatchQueue(label: "com.scopy.orphan-cleanup", attributes: .concurrent)

                for fileURL in orphanedFiles {
                    group.enter()
                    queue.async {
                        defer { group.leave() }
                        try? FileManager.default.removeItem(at: fileURL)
                    }
                }
                group.wait()

                // 4. Invalidate cache after cleanup (on main thread)
                DispatchQueue.main.async {
                    self?.invalidateExternalSizeCache()
                }
            }
        }
    }

    /// v0.14: 深度优化 - 消除子查询 COUNT，使用单次查询 + 事务批量删除
    /// 原理：先计算当前非 pin 数量，再用 OFFSET 直接定位要删除的记录
    /// 收益：消除 O(n) 子查询，50k 数据下节省 ~200ms
    private func cleanupByCount(target: Int) throws {
        // Step 1: 获取当前非 pin 项目数量（单次 COUNT，比子查询更高效）
        let countSQL = "SELECT COUNT(*) FROM clipboard_items WHERE is_pinned = 0"
        var countStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, countSQL, -1, &countStmt, nil) == SQLITE_OK else {
            throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(countStmt) }

        guard sqlite3_step(countStmt) == SQLITE_ROW else {
            throw StorageError.queryFailed("Failed to get count")
        }
        let currentCount = Int(sqlite3_column_int(countStmt, 0))

        // 计算需要删除的数量
        let deleteCount = currentCount - target
        if deleteCount <= 0 { return }

        // Step 2: 直接获取要删除的项目（使用 LIMIT，避免子查询）
        let selectSQL = """
            SELECT id, storage_ref FROM clipboard_items
            WHERE is_pinned = 0
            ORDER BY last_used_at ASC
            LIMIT ?
        """
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
            throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(selectStmt) }

        sqlite3_bind_int(selectStmt, 1, Int32(deleteCount))

        var idsToDelete: [UUID] = []
        var filesToDelete: [String] = []
        idsToDelete.reserveCapacity(deleteCount)

        while sqlite3_step(selectStmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(selectStmt, 0),
               let id = UUID(uuidString: String(cString: cStr)) {
                idsToDelete.append(id)
                if let refCStr = sqlite3_column_text(selectStmt, 1) {
                    filesToDelete.append(String(cString: refCStr))
                }
            }
        }

        // 如果没有要删除的项目，直接返回
        if idsToDelete.isEmpty { return }

        // v0.14: 并发删除外部文件（与数据库删除并行）
        if !filesToDelete.isEmpty {
            deleteFilesInParallel(filesToDelete)
        }

        // v0.14: 使用事务包装批量删除，减少 fsync 次数
        try deleteItemsBatchInTransaction(ids: idsToDelete)
    }

    /// v0.10.4: 检查 sqlite3_step 返回值
    /// v0.19: 修复 - 同时删除外部存储文件，避免孤立文件累积
    private func cleanupByAge(maxDays: Int) throws {
        let cutoff = Date().addingTimeInterval(-Double(maxDays * 24 * 3600))

        // Step 1: 获取要删除的项目（包含外部存储引用）
        let selectSQL = """
            SELECT id, storage_ref FROM clipboard_items
            WHERE is_pinned = 0 AND created_at < ?
        """
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
            throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(selectStmt) }

        sqlite3_bind_double(selectStmt, 1, cutoff.timeIntervalSince1970)

        var idsToDelete: [UUID] = []
        var filesToDelete: [String] = []

        while sqlite3_step(selectStmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(selectStmt, 0),
               let id = UUID(uuidString: String(cString: cStr)) {
                idsToDelete.append(id)
                if let refCStr = sqlite3_column_text(selectStmt, 1) {
                    filesToDelete.append(String(cString: refCStr))
                }
            }
        }

        // 如果没有要删除的项目，直接返回
        if idsToDelete.isEmpty { return }

        // Step 2: 并发删除外部文件
        if !filesToDelete.isEmpty {
            deleteFilesInParallel(filesToDelete)
        }

        // Step 3: 事务批量删除数据库记录
        try deleteItemsBatchInTransaction(ids: idsToDelete)
    }

    /// v0.14: 深度优化 - 消除循环迭代，单次查询 + 事务批量删除
    /// 原理：一次性获取所有待删除项目，累加 size 直到达到目标，单事务删除
    /// 收益：消除多次迭代的 SQL 开销，9000 条删除从 ~4500ms 降到 ~200ms
    private func cleanupBySize(targetBytes: Int) throws {
        let currentSize = try getTotalSize()
        if currentSize <= targetBytes { return }

        let excessBytes = currentSize - targetBytes

        // 一次性获取所有非 pin 项目（按 last_used_at 排序）
        // 使用足够大的 LIMIT 避免多次查询
        let sql = """
            SELECT id, size_bytes, storage_ref FROM clipboard_items
            WHERE is_pinned = 0
            ORDER BY last_used_at ASC
            LIMIT 10000
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var idsToDelete: [UUID] = []
        var filesToDelete: [String] = []
        var accumulatedSize = 0

        // 累加 size 直到达到需要删除的量
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0),
               let id = UUID(uuidString: String(cString: cStr)) {
                let size = Int(sqlite3_column_int(stmt, 1))
                let storageRef = sqlite3_column_text(stmt, 2).map { String(cString: $0) }

                idsToDelete.append(id)
                accumulatedSize += size
                if let ref = storageRef {
                    filesToDelete.append(ref)
                }

                // 达到目标后停止
                if accumulatedSize >= excessBytes { break }
            }
        }

        if idsToDelete.isEmpty { return }

        // v0.14: 并发删除外部文件
        if !filesToDelete.isEmpty {
            deleteFilesInParallel(filesToDelete)
        }

        // v0.14: 事务批量删除
        try deleteItemsBatchInTransaction(ids: idsToDelete)
    }

    /// v0.13: 批量删除多个项目（单条 SQL，单事务，避免 N+1 查询）
    private func deleteItemsBatch(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }

        // 构建 IN 子句的占位符
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "DELETE FROM clipboard_items WHERE id IN (\(placeholders))"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        // 绑定所有 ID
        for (index, id) in ids.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), id.uuidString, -1, SQLITE_TRANSIENT)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StorageError.deleteFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// v0.14: 事务包装的批量删除 - 减少 fsync 次数，大幅提升性能
    /// 原理：SQLite 默认每条 DELETE 后 fsync，事务内只在 COMMIT 时 fsync 一次
    /// 收益：9000 条删除从 ~4500ms 降到 ~200ms
    /// v0.20: 增强错误处理 - ROLLBACK 失败时尝试恢复数据库连接
    /// v0.23: 改进恢复逻辑 - 添加 isDatabaseCorrupted 标志，上层可检查
    private(set) var isDatabaseCorrupted = false

    private func deleteItemsBatchInTransaction(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }

        // 开始事务
        try execute("BEGIN IMMEDIATE TRANSACTION")

        do {
            // 分批删除（每批 999 条，SQLite 变量限制）
            let batchSize = 999
            for batchStart in stride(from: 0, to: ids.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, ids.count)
                let batch = Array(ids[batchStart..<batchEnd])
                try deleteItemsBatch(ids: batch)
            }

            // 提交事务（单次 fsync）
            try execute("COMMIT")
        } catch {
            // v0.17: 回滚事务，记录回滚错误但不改变异常传播
            // v0.20: ROLLBACK 失败时尝试恢复数据库连接
            // v0.23: 添加状态标志，让上层知道数据库可能损坏
            do {
                try execute("ROLLBACK")
            } catch let rollbackError {
                print("⚠️ StorageService: ROLLBACK failed: \(rollbackError), attempting database recovery")
                // 尝试恢复数据库连接
                do {
                    close()
                    try open()
                    isDatabaseCorrupted = false
                    print("✅ StorageService: Database connection recovered after ROLLBACK failure")
                } catch let recoveryError {
                    print("❌ StorageService: Database recovery failed: \(recoveryError)")
                    // 标记数据库可能损坏，上层可以检查此标志并采取措施
                    isDatabaseCorrupted = true
                }
            }
            throw error
        }
    }

    /// v0.14: 深度优化 - 消除循环迭代，单次查询 + 事务批量删除
    /// 原理：一次性获取所有外部存储项目，累加 size 直到达到目标，单事务删除
    /// 收益：消除多次迭代的 SQL 和文件系统开销
    private func cleanupExternalStorage(targetBytes: Int) throws {
        // 使缓存失效，确保获取最新大小
        invalidateExternalSizeCache()
        let currentSize = try getExternalStorageSize()
        if currentSize <= targetBytes { return }

        let excessBytes = currentSize - targetBytes

        // 一次性获取所有有外部存储的非 pin 项目
        let sql = """
            SELECT id, size_bytes, storage_ref FROM clipboard_items
            WHERE is_pinned = 0 AND storage_ref IS NOT NULL
            ORDER BY last_used_at ASC
            LIMIT 5000
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var idsToDelete: [UUID] = []
        var filesToDelete: [String] = []
        var accumulatedSize = 0

        // 累加 size 直到达到需要删除的量
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0),
               let id = UUID(uuidString: String(cString: cStr)),
               let refCStr = sqlite3_column_text(stmt, 2) {
                let size = Int(sqlite3_column_int(stmt, 1))
                let storageRef = String(cString: refCStr)

                idsToDelete.append(id)
                filesToDelete.append(storageRef)
                accumulatedSize += size

                // 达到目标后停止
                if accumulatedSize >= excessBytes { break }
            }
        }

        if idsToDelete.isEmpty { return }

        // v0.14: 并发删除外部文件
        deleteFilesInParallel(filesToDelete)

        // v0.14: 事务批量删除数据库记录
        try deleteItemsBatchInTransaction(ids: idsToDelete)

        // 清理完成后使缓存失效
        invalidateExternalSizeCache()
    }

    /// v0.12: 并发删除文件，提升清理性能（后台执行，避免阻塞主线程）
    /// v0.17: 添加错误日志记录，便于追踪删除失败
    /// v0.20: 修复竞态条件 - 检查文件存在性，忽略"文件不存在"错误，不阻塞等待
    private func deleteFilesInParallel(_ files: [String]) {
        guard !files.isEmpty else { return }

        // 去重，避免并发删除同一文件
        let uniqueFiles = Array(Set(files))

        DispatchQueue.global(qos: .utility).async {
            let queue = DispatchQueue(label: "com.scopy.cleanup", attributes: .concurrent)

            for file in uniqueFiles {
                queue.async {
                    // 先检查文件是否存在，避免不必要的错误
                    guard FileManager.default.fileExists(atPath: file) else { return }

                    do {
                        try FileManager.default.removeItem(atPath: file)
                    } catch let error as NSError {
                        // 忽略"文件不存在"错误（可能被其他线程删除）
                        if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                            return
                        }
                        // v0.17: 记录其他删除失败，便于追踪存储泄漏
                        print("⚠️ StorageService: Failed to delete file '\(file)': \(error.localizedDescription)")
                    }
                }
            }
            // v0.20: 不再使用 group.wait() 阻塞，让删除操作异步完成
            // 文件删除是尽力而为，不需要等待完成
        }
    }

    /// v0.12: 仅删除数据库记录（不删除文件，用于并发清理场景）
    private func deleteItemFromDB(_ id: UUID) throws {
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

    // MARK: - External Storage

    /// v0.17: 原子文件写入 - 使用临时文件 + 重命名，避免崩溃时文件损坏
    private func writeAtomically(_ data: Data, to path: String) throws {
        let tempPath = path + ".tmp"
        let tempURL = URL(fileURLWithPath: tempPath)
        let finalURL = URL(fileURLWithPath: path)

        // 写入临时文件
        try data.write(to: tempURL)

        // 如果目标文件存在，先删除
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(at: finalURL)
        }

        // 原子重命名
        try FileManager.default.moveItem(at: tempURL, to: finalURL)
    }

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
            // v0.17: 使用原子写入
            try writeAtomically(data, to: path)
            return path
        } catch {
            throw StorageError.fileOperationFailed("Failed to write external file: \(error)")
        }
    }

    /// v0.10.7: 验证存储引用是否为有效的 UUID 文件名（防止路径遍历攻击）
    /// v0.17: 增强验证 - 添加符号链接检查和路径规范化
    private func validateStorageRef(_ ref: String) -> Bool {
        // 提取文件名（不含路径）
        let filename = (ref as NSString).lastPathComponent

        // 移除扩展名
        let nameWithoutExt = (filename as NSString).deletingPathExtension

        // 必须是有效的 UUID 格式
        guard UUID(uuidString: nameWithoutExt) != nil else {
            return false
        }

        // 不能包含路径遍历字符
        guard !ref.contains("..") && !filename.contains("/") else {
            return false
        }

        // v0.17: 检查符号链接
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: ref, isDirectory: &isDirectory)
        if exists {
            // 检查是否为符号链接
            if let attrs = try? FileManager.default.attributesOfItem(atPath: ref),
               let fileType = attrs[.type] as? FileAttributeType,
               fileType == .typeSymbolicLink {
                return false
            }

            // v0.17: 规范化路径并验证是否在允许的目录内
            let url = URL(fileURLWithPath: ref)
            let resolvedPath = url.resolvingSymlinksInPath().path
            let allowedPath = URL(fileURLWithPath: externalStoragePath).resolvingSymlinksInPath().path
            guard resolvedPath.hasPrefix(allowedPath) else {
                return false
            }
        }

        return true
    }

    /// v0.22: 外部文件加载最大大小限制 (100MB)
    /// 防止恶意或损坏的文件导致内存耗尽
    private static let maxExternalFileSize: Int = 100 * 1024 * 1024

    func loadExternalData(path: String) throws -> Data {
        // v0.10.7: 验证路径安全性
        guard validateStorageRef(path) else {
            throw StorageError.fileOperationFailed("Invalid storage reference: potential path traversal")
        }

        // v0.22: 检查文件大小，防止加载过大文件导致内存耗尽
        let url = URL(fileURLWithPath: path)
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            if let fileSize = attrs[.size] as? Int, fileSize > Self.maxExternalFileSize {
                throw StorageError.fileOperationFailed("File too large: \(fileSize) bytes (max: \(Self.maxExternalFileSize))")
            }
        } catch let error as StorageError {
            throw error
        } catch {
            // 文件属性获取失败，继续尝试读取（可能是权限问题）
            print("⚠️ StorageService: Failed to get file attributes: \(error.localizedDescription)")
        }

        do {
            return try Data(contentsOf: url)
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
    /// v0.19: 添加 autoreleasepool 管理中间对象内存
    func generateThumbnail(from imageData: Data, contentHash: String, maxHeight: Int) -> String? {
        // 检查是否已存在
        if let existing = getThumbnailPath(for: contentHash) {
            return existing
        }

        // v0.19: 使用 autoreleasepool 管理 NSImage/NSBitmapImageRep 等中间对象
        let pngData: Data? = autoreleasepool {
            guard let nsImage = NSImage(data: imageData) else { return nil }
            let originalSize = nsImage.size

            // 计算缩放比例
            guard originalSize.height > 0, originalSize.width > 0 else { return nil }
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
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                return nil
            }
            return png
        }

        guard let pngData = pngData else { return nil }

        // v0.17: 使用原子写入保存缩略图
        let path = (thumbnailCachePath as NSString).appendingPathComponent("\(contentHash).png")
        do {
            try writeAtomically(pngData, to: path)
            return path
        } catch {
            print("Failed to save thumbnail: \(error)")
            return nil
        }
    }

    /// 获取原图数据（用于预览）
    /// v0.22: 修复图片数据丢失问题 - 当 rawData 为 nil 时从数据库重新加载
    /// 这是因为 SearchService 缓存中的 rawData 被设为 nil（v0.19 内存优化）
    func getOriginalImageData(for item: StoredItem) -> Data? {
        // 1. 优先使用外部存储（大图片 >100KB）
        if let storageRef = item.storageRef {
            return try? loadExternalData(path: storageRef)
        }

        // 2. 使用内联数据（小图片）
        if let rawData = item.rawData {
            return rawData
        }

        // 3. 从数据库重新加载（缓存中 rawData 为 nil 的情况）
        // 这是 v0.19 内存优化导致的问题：缓存中的 rawData 被设为 nil
        if let freshItem = try? findByID(item.id), let rawData = freshItem.rawData {
            return rawData
        }

        print("⚠️ StorageService: Failed to get original image data for item \(item.id)")
        return nil
    }

    /// 清空缩略图缓存（设置变更时调用）
    func clearThumbnailCache() {
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(atPath: self.thumbnailCachePath)
            try? FileManager.default.createDirectory(atPath: self.thumbnailCachePath,
                                                     withIntermediateDirectories: true)
        }
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

    /// v0.19: 使用共享的 parseStoredItem 函数，消除代码重复
    private func parseItem(from stmt: OpaquePointer) -> StoredItem? {
        return parseStoredItem(from: stmt)
    }
}

// MARK: - SQLITE_TRANSIENT helper
// v0.19: 移至 SQLiteHelpers.swift，此处保留注释说明
// 使用全局 SQLITE_TRANSIENT 常量（定义在 SQLiteHelpers.swift）
