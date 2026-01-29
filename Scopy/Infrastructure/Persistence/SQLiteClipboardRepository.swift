import Foundation
import SQLite3

actor SQLiteClipboardRepository {
    enum RepositoryError: Error, LocalizedError {
        case databaseNotOpen
        case queryFailed(String)
        case migrationFailed(String)

        var errorDescription: String? {
            switch self {
            case .databaseNotOpen: return "Database is not open"
            case .queryFailed(let msg): return "Query failed: \(msg)"
            case .migrationFailed(let msg): return "Migration failed: \(msg)"
            }
        }
    }

    struct DeletePlan: Sendable {
        let ids: [UUID]
        let storageRefs: [String]
    }

    struct ExternalStorageSizeRecord: Sendable {
        let id: UUID
        let sizeBytes: Int
        let storageRef: String
    }

    struct SizeBytesUpdate: Sendable {
        let id: UUID
        let sizeBytes: Int
    }

    private let dbPath: String
    private var connection: SQLiteConnection?

    private(set) var isDatabaseCorrupted: Bool = false

    init(dbPath: String) {
        self.dbPath = dbPath
    }

    func open() throws {
        guard connection == nil else { return }

        let flags = SQLiteClipboardRepository.openFlags(for: dbPath)
        let conn = try SQLiteConnection(path: dbPath, flags: flags)

        do {
            try conn.execute("PRAGMA journal_mode = WAL")
            try conn.execute("PRAGMA synchronous = NORMAL")
            try conn.execute("PRAGMA busy_timeout = 500")
            try conn.execute("PRAGMA cache_size = -64000")
            try conn.execute("PRAGMA temp_store = MEMORY")
            try conn.execute("PRAGMA mmap_size = 268435456")

            try SQLiteMigrations.migrateIfNeeded(conn)
            try verifySchema(conn)
        } catch {
            conn.close()
            throw error
        }

        self.connection = conn
    }

    func close() {
        connection?.walCheckpointPassive()
        connection?.close()
        connection = nil
    }

    func walCheckpointPassive() {
        connection?.walCheckpointPassive()
    }

    func fetchItemByHash(_ hash: String) throws -> ClipboardStoredItem? {
        let sql = """
            SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref, raw_data, file_size_bytes
            FROM clipboard_items
            WHERE content_hash = ? LIMIT 1
        """
        let stmt = try prepare(sql)
        try stmt.bindText(hash, at: 1)
        if try stmt.step() {
            return try parseStoredItem(from: stmt)
        }
        return nil
    }

    func fetchItemByID(_ id: UUID) throws -> ClipboardStoredItem? {
        let sql = """
            SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref, raw_data, file_size_bytes
            FROM clipboard_items
            WHERE id = ? LIMIT 1
        """
        let stmt = try prepare(sql)
        try stmt.bindText(id.uuidString, at: 1)
        if try stmt.step() {
            return try parseStoredItem(from: stmt)
        }
        return nil
    }

    func insertItem(
        id: UUID,
        type: ClipboardItemType,
        contentHash: String,
        plainText: String,
        note: String?,
        appBundleID: String?,
        createdAt: Date,
        lastUsedAt: Date,
        sizeBytes: Int,
        fileSizeBytes: Int?,
        storageRef: String?,
        rawData: Data?
    ) throws {
        try performWriteTransaction {
            let sql = """
                INSERT INTO clipboard_items
                (id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at, use_count, is_pinned, size_bytes, storage_ref, raw_data, file_size_bytes)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, 0, ?, ?, ?, ?)
            """
            let stmt = try prepare(sql)

            try stmt.bindText(id.uuidString, at: 1)
            try stmt.bindText(type.rawValue, at: 2)
            try stmt.bindText(contentHash, at: 3)
            try stmt.bindText(plainText, at: 4)
            try stmt.bindText(note, at: 5)
            try stmt.bindText(appBundleID, at: 6)
            try stmt.bindDouble(createdAt.timeIntervalSince1970, at: 7)
            try stmt.bindDouble(lastUsedAt.timeIntervalSince1970, at: 8)
            try stmt.bindInt(sizeBytes, at: 9)
            try stmt.bindText(storageRef, at: 10)
            try stmt.bindBlob(rawData, at: 11)
            if let fileSizeBytes {
                try stmt.bindInt(fileSizeBytes, at: 12)
            } else {
                try stmt.bindNull(12)
            }

            _ = try stmt.step()
        }
    }

    func updateUsage(id: UUID, lastUsedAt: Date, useCount: Int) throws {
        try performWriteTransaction {
            let sql = """
                UPDATE clipboard_items
                SET last_used_at = ?, use_count = ?
                WHERE id = ?
            """
            let stmt = try prepare(sql)
            try stmt.bindDouble(lastUsedAt.timeIntervalSince1970, at: 1)
            try stmt.bindInt(useCount, at: 2)
            try stmt.bindText(id.uuidString, at: 3)
            _ = try stmt.step()
        }
    }

    func updateItemMetadata(id: UUID, lastUsedAt: Date, useCount: Int, isPinned: Bool) throws {
        try performWriteTransaction {
            let sql = """
                UPDATE clipboard_items
                SET last_used_at = ?, use_count = ?, is_pinned = ?
                WHERE id = ?
            """
            let stmt = try prepare(sql)
            try stmt.bindDouble(lastUsedAt.timeIntervalSince1970, at: 1)
            try stmt.bindInt(useCount, at: 2)
            try stmt.bindInt(isPinned ? 1 : 0, at: 3)
            try stmt.bindText(id.uuidString, at: 4)
            _ = try stmt.step()
        }
    }

    func updatePin(id: UUID, pinned: Bool) throws {
        try performWriteTransaction {
            let sql = "UPDATE clipboard_items SET is_pinned = ? WHERE id = ?"
            let stmt = try prepare(sql)
            try stmt.bindInt(pinned ? 1 : 0, at: 1)
            try stmt.bindText(id.uuidString, at: 2)
            _ = try stmt.step()
        }
    }

    func updateItemPayload(
        id: UUID,
        contentHash: String,
        sizeBytes: Int,
        storageRef: String?,
        rawData: Data?
    ) throws {
        try performWriteTransaction {
            let sql = """
                UPDATE clipboard_items
                SET content_hash = ?, size_bytes = ?, storage_ref = ?, raw_data = ?
                WHERE id = ?
            """
            let stmt = try prepare(sql)
            try stmt.bindText(contentHash, at: 1)
            try stmt.bindInt(sizeBytes, at: 2)
            try stmt.bindText(storageRef, at: 3)
            try stmt.bindBlob(rawData, at: 4)
            try stmt.bindText(id.uuidString, at: 5)
            _ = try stmt.step()
        }
    }

    func updateItemNote(id: UUID, note: String?) throws {
        try performWriteTransaction {
            let sql = "UPDATE clipboard_items SET note = ? WHERE id = ?"
            let stmt = try prepare(sql)
            try stmt.bindText(note, at: 1)
            try stmt.bindText(id.uuidString, at: 2)
            _ = try stmt.step()
        }
    }

    func updateItemFileSizeBytes(id: UUID, fileSizeBytes: Int?) throws {
        try performWriteTransaction {
            let sql = "UPDATE clipboard_items SET file_size_bytes = ? WHERE id = ?"
            let stmt = try prepare(sql)
            if let fileSizeBytes {
                try stmt.bindInt(fileSizeBytes, at: 1)
            } else {
                try stmt.bindNull(1)
            }
            try stmt.bindText(id.uuidString, at: 2)
            _ = try stmt.step()
        }
    }

    func deleteItem(id: UUID) throws {
        try performWriteTransaction {
            let sql = "DELETE FROM clipboard_items WHERE id = ?"
            let stmt = try prepare(sql)
            try stmt.bindText(id.uuidString, at: 1)
            _ = try stmt.step()
        }
    }

    func deleteItemReturningStorageRef(id: UUID) throws -> String? {
        var storageRef: String?
        try performWriteTransaction {
            // Finalize the statement before running the DELETE to avoid locking the table in the same connection.
            do {
                let sql = "SELECT storage_ref FROM clipboard_items WHERE id = ? LIMIT 1"
                let stmt = try prepare(sql)
                try stmt.bindText(id.uuidString, at: 1)
                if try stmt.step(),
                   let ref = stmt.columnText(0),
                   !ref.isEmpty {
                    storageRef = ref
                }
            }

            let sql = "DELETE FROM clipboard_items WHERE id = ?"
            let stmt = try prepare(sql)
            try stmt.bindText(id.uuidString, at: 1)
            _ = try stmt.step()
        }
        return storageRef
    }

    func deleteAllExceptPinned() throws {
        try performWriteTransaction {
            try execute("DELETE FROM clipboard_items WHERE is_pinned = 0")
        }
    }

    func deleteAllExceptPinnedReturningStorageRefs() throws -> [String] {
        var refs: [String] = []
        try performWriteTransaction {
            // Finalize the statement before running the DELETE to avoid locking the table in the same connection.
            do {
                let sql = "SELECT storage_ref FROM clipboard_items WHERE is_pinned = 0 AND storage_ref IS NOT NULL AND storage_ref <> ''"
                let stmt = try prepare(sql)
                while try stmt.step() {
                    if let ref = stmt.columnText(0) {
                        refs.append(ref)
                    }
                }
            }
            try execute("DELETE FROM clipboard_items WHERE is_pinned = 0")
        }
        return refs
    }

    func fetchStorageRefsForUnpinned() throws -> [String] {
        let sql = "SELECT storage_ref FROM clipboard_items WHERE is_pinned = 0 AND storage_ref IS NOT NULL"
        let stmt = try prepare(sql)

        var refs: [String] = []
        while try stmt.step() {
            if let ref = stmt.columnText(0) {
                refs.append(ref)
            }
        }
        return refs
    }

    func fetchExternalStorageSizeRecords(typeFilter: ClipboardItemType?) throws -> [ExternalStorageSizeRecord] {
        var sql = """
            SELECT id, size_bytes, storage_ref
            FROM clipboard_items
            WHERE storage_ref IS NOT NULL AND storage_ref != ''
        """

        if typeFilter != nil {
            sql += " AND type = ?"
        }

        let stmt = try prepare(sql)
        if let typeFilter {
            try stmt.bindText(typeFilter.rawValue, at: 1)
        }

        var records: [ExternalStorageSizeRecord] = []
        while try stmt.step() {
            guard let idString = stmt.columnText(0),
                  let id = UUID(uuidString: idString),
                  let storageRef = stmt.columnText(2),
                  !storageRef.isEmpty else { continue }

            records.append(
                ExternalStorageSizeRecord(
                    id: id,
                    sizeBytes: stmt.columnInt(1),
                    storageRef: storageRef
                )
            )
        }
        return records
    }

    func fetchRecent(limit: Int, offset: Int) throws -> [ClipboardStoredItem] {
        let sql = """
            SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref, raw_data, file_size_bytes
            FROM clipboard_items
            ORDER BY is_pinned DESC, last_used_at DESC, id ASC
            LIMIT ? OFFSET ?
        """
        let stmt = try prepare(sql)
        try stmt.bindInt(limit, at: 1)
        try stmt.bindInt(offset, at: 2)

        var items: [ClipboardStoredItem] = []
        items.reserveCapacity(limit)
        while try stmt.step() {
            items.append(try parseStoredItem(from: stmt))
        }
        return items
    }

    func fetchRecentSummaries(limit: Int, offset: Int) throws -> [ClipboardStoredItem] {
        let sql = """
            SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref, file_size_bytes
            FROM clipboard_items
            ORDER BY is_pinned DESC, last_used_at DESC, id ASC
            LIMIT ? OFFSET ?
        """
        let stmt = try prepare(sql)
        try stmt.bindInt(limit, at: 1)
        try stmt.bindInt(offset, at: 2)

        var items: [ClipboardStoredItem] = []
        items.reserveCapacity(limit)
        while try stmt.step() {
            items.append(try parseStoredItemSummary(from: stmt))
        }
        return items
    }

    func fetchAllSummaries() throws -> [ClipboardStoredItem] {
        let sql = """
            SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref, file_size_bytes
            FROM clipboard_items
        """
        let stmt = try prepare(sql)

        var items: [ClipboardStoredItem] = []
        while try stmt.step() {
            items.append(try parseStoredItemSummary(from: stmt))
        }
        return items
    }

    func fetchItemsByIDs(_ ids: [UUID]) throws -> [ClipboardStoredItem] {
        guard !ids.isEmpty else { return [] }

        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref, raw_data, file_size_bytes
            FROM clipboard_items
            WHERE id IN (\(placeholders))
        """
        let stmt = try prepare(sql)

        for (index, id) in ids.enumerated() {
            try stmt.bindText(id.uuidString, at: Int32(index + 1))
        }

        var fetched: [UUID: ClipboardStoredItem] = [:]
        fetched.reserveCapacity(ids.count)

        while try stmt.step() {
            let item = try parseStoredItem(from: stmt)
            fetched[item.id] = item
        }

        return ids.compactMap { fetched[$0] }
    }

    func fetchRecentApps(limit: Int) throws -> [String] {
        let sql = """
            SELECT app_bundle_id
            FROM clipboard_items
            WHERE app_bundle_id IS NOT NULL AND app_bundle_id != ''
            GROUP BY app_bundle_id
            ORDER BY MAX(last_used_at) DESC
            LIMIT ?
        """
        let stmt = try prepare(sql)
        try stmt.bindInt(limit, at: 1)

        var apps: [String] = []
        while try stmt.step() {
            if let bundleID = stmt.columnText(0) {
                apps.append(bundleID)
            }
        }
        return apps
    }

    func getItemCount() throws -> Int {
        do {
            let stmt = try prepare("SELECT item_count FROM scopy_meta WHERE id = 1")
            guard try stmt.step() else { return 0 }
            return stmt.columnInt(0)
        } catch {
            let stmt = try prepare("SELECT COUNT(*) FROM clipboard_items")
            guard try stmt.step() else { return 0 }
            return stmt.columnInt(0)
        }
    }

    func getTotalSize() throws -> Int {
        do {
            let stmt = try prepare("SELECT total_size_bytes FROM scopy_meta WHERE id = 1")
            guard try stmt.step() else { return 0 }
            let value = stmt.columnInt64(0)
            return Int(min(value, Int64(Int.max)))
        } catch {
            let stmt = try prepare("SELECT SUM(size_bytes) FROM clipboard_items")
            guard try stmt.step() else { return 0 }
            let value = stmt.columnInt64(0)
            return Int(min(value, Int64(Int.max)))
        }
    }

    func updateItemSizeBytesBatchInTransaction(updates: [SizeBytesUpdate]) throws {
        guard !updates.isEmpty else { return }
        try performWriteTransaction {
            let stmt = try prepare("UPDATE clipboard_items SET size_bytes = ? WHERE id = ?")
            for update in updates {
                stmt.reset()
                try stmt.bindInt(update.sizeBytes, at: 1)
                try stmt.bindText(update.id.uuidString, at: 2)
                _ = try stmt.step()
            }
        }
    }

    func searchAllWithFilters(
        appFilter: String?,
        typeFilter: ClipboardItemType?,
        typeFilters: [ClipboardItemType]?,
        limit: Int,
        offset: Int
    ) throws -> (items: [ClipboardStoredItem], total: Int, hasMore: Bool) {
        var sql = """
            SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref, file_size_bytes
            FROM clipboard_items
            WHERE 1 = 1
        """
        var params: [String] = []

        if let appFilter {
            sql += " AND app_bundle_id = ?"
            params.append(appFilter)
        }

        if let typeFilters, !typeFilters.isEmpty {
            let placeholders = typeFilters.map { _ in "?" }.joined(separator: ",")
            sql += " AND type IN (\(placeholders))"
            params.append(contentsOf: typeFilters.map(\.rawValue))
        } else if let typeFilter {
            sql += " AND type = ?"
            params.append(typeFilter.rawValue)
        }

        sql += " ORDER BY is_pinned DESC, last_used_at DESC, id ASC"
        sql += " LIMIT ? OFFSET ?"

        let stmt = try prepare(sql)
        var bindIndex: Int32 = 1
        for param in params {
            try stmt.bindText(param, at: bindIndex)
            bindIndex += 1
        }
        try stmt.bindInt(limit + 1, at: bindIndex)
        try stmt.bindInt(offset, at: bindIndex + 1)

        var items: [ClipboardStoredItem] = []
        items.reserveCapacity(limit + 1)
        while try stmt.step() {
            items.append(try parseStoredItemSummary(from: stmt))
        }

        let hasMore = items.count > limit
        if hasMore {
            items = Array(items.prefix(limit))
        }

        let total = hasMore ? -1 : offset + items.count
        return (items, total, hasMore)
    }

    func searchWithFTS(
        ftsQuery: String,
        appFilter: String?,
        typeFilter: ClipboardItemType?,
        typeFilters: [ClipboardItemType]?,
        limit: Int,
        offset: Int
    ) throws -> (items: [ClipboardStoredItem], total: Int, hasMore: Bool) {
        // Step 1: rowids from FTS
        let ftsSQL = """
            SELECT rowid FROM clipboard_fts
            WHERE clipboard_fts MATCH ?
            ORDER BY bm25(clipboard_fts)
            LIMIT ? OFFSET ?
        """
        let ftsStmt = try prepare(ftsSQL)
        try ftsStmt.bindText(ftsQuery, at: 1)
        try ftsStmt.bindInt(limit + 1, at: 2)
        try ftsStmt.bindInt(offset, at: 3)

        var rowids: [Int64] = []
        rowids.reserveCapacity(limit + 1)
        while try ftsStmt.step() {
            rowids.append(ftsStmt.columnInt64(0))
        }

        let hasMore = rowids.count > limit
        if hasMore {
            rowids.removeLast()
        }

        if rowids.isEmpty {
            return ([], 0, false)
        }

        // Step 2: fetch from main table (apply filters)
        let placeholders = rowids.map { _ in "?" }.joined(separator: ",")
        var mainSQL = """
            SELECT id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref, file_size_bytes
            FROM clipboard_items
            WHERE rowid IN (\(placeholders))
        """

        var filterParams: [String] = []
        if let appFilter {
            mainSQL += " AND app_bundle_id = ?"
            filterParams.append(appFilter)
        }

        if let typeFilters, !typeFilters.isEmpty {
            let placeholders = typeFilters.map { _ in "?" }.joined(separator: ",")
            mainSQL += " AND type IN (\(placeholders))"
            filterParams.append(contentsOf: typeFilters.map(\.rawValue))
        } else if let typeFilter {
            mainSQL += " AND type = ?"
            filterParams.append(typeFilter.rawValue)
        }

        let orderCases = rowids.enumerated().map { "WHEN rowid = \($0.element) THEN \($0.offset)" }.joined(separator: " ")
        mainSQL += " ORDER BY is_pinned DESC, CASE \(orderCases) END"

        let mainStmt = try prepare(mainSQL)

        var bindIndex: Int32 = 1
        for rowid in rowids {
            try mainStmt.bindInt64(rowid, at: bindIndex)
            bindIndex += 1
        }

        for param in filterParams {
            try mainStmt.bindText(param, at: bindIndex)
            bindIndex += 1
        }

        var items: [ClipboardStoredItem] = []
        items.reserveCapacity(rowids.count)
        while try mainStmt.step() {
            items.append(try parseStoredItemSummary(from: mainStmt))
        }

        let total = hasMore ? -1 : offset + items.count
        return (items, total, hasMore)
    }

    func ftsPrefilterIDs(ftsQuery: String, limit: Int) throws -> [UUID] {
        let sql = """
            SELECT clipboard_items.id
            FROM clipboard_fts
            JOIN clipboard_items ON clipboard_items.rowid = clipboard_fts.rowid
            WHERE clipboard_fts MATCH ?
            ORDER BY bm25(clipboard_fts)
            LIMIT ?
        """
        let stmt = try prepare(sql)
        try stmt.bindText(ftsQuery, at: 1)
        try stmt.bindInt(limit, at: 2)

        var ids: [UUID] = []
        ids.reserveCapacity(limit)
        while try stmt.step() {
            guard let idString = stmt.columnText(0),
                  let id = UUID(uuidString: idString) else { continue }
            ids.append(id)
        }
        return ids
    }

    func fetchExternalRefFilenames() throws -> Set<String> {
        let sql = "SELECT storage_ref FROM clipboard_items WHERE storage_ref IS NOT NULL AND storage_ref <> ''"
        let stmt = try prepare(sql)

        var filenames: Set<String> = []
        while try stmt.step() {
            guard let ref = stmt.columnText(0) else { continue }
            let filename = (ref as NSString).lastPathComponent
            filenames.insert(filename)
        }
        return filenames
    }

    func planCleanupByCount(target: Int) throws -> DeletePlan {
        let currentCount: Int
        do {
            let stmt = try prepare("SELECT unpinned_count FROM scopy_meta WHERE id = 1")
            guard try stmt.step() else { return DeletePlan(ids: [], storageRefs: []) }
            currentCount = stmt.columnInt(0)
        } catch {
            let countSQL = "SELECT COUNT(*) FROM clipboard_items WHERE is_pinned = 0"
            let countStmt = try prepare(countSQL)
            guard try countStmt.step() else { return DeletePlan(ids: [], storageRefs: []) }
            currentCount = countStmt.columnInt(0)
        }

        let deleteCount = currentCount - target
        guard deleteCount > 0 else { return DeletePlan(ids: [], storageRefs: []) }

        let selectSQL = """
            SELECT id, storage_ref FROM clipboard_items
            WHERE is_pinned = 0
            ORDER BY last_used_at ASC
            LIMIT ?
        """
        let selectStmt = try prepare(selectSQL)
        try selectStmt.bindInt(deleteCount, at: 1)

        var ids: [UUID] = []
        var refs: [String] = []
        ids.reserveCapacity(deleteCount)

        while try selectStmt.step() {
            guard let idString = selectStmt.columnText(0),
                  let id = UUID(uuidString: idString) else { continue }
            ids.append(id)
            if let ref = selectStmt.columnText(1) {
                refs.append(ref)
            }
        }

        return DeletePlan(ids: ids, storageRefs: refs)
    }

    func planCleanupByAge(cutoff: Date) throws -> DeletePlan {
        try planCleanupByAge(cutoff: cutoff, typeFilter: nil)
    }

    func planCleanupByAge(cutoff: Date, typeFilter: ClipboardItemType?) throws -> DeletePlan {
        var selectSQL = """
            SELECT id, storage_ref FROM clipboard_items
            WHERE is_pinned = 0 AND created_at < ?
        """
        if typeFilter != nil {
            selectSQL += " AND type = ?"
        }
        let stmt = try prepare(selectSQL)
        try stmt.bindDouble(cutoff.timeIntervalSince1970, at: 1)
        if let typeFilter {
            try stmt.bindText(typeFilter.rawValue, at: 2)
        }

        var ids: [UUID] = []
        var refs: [String] = []
        while try stmt.step() {
            guard let idString = stmt.columnText(0),
                  let id = UUID(uuidString: idString) else { continue }
            ids.append(id)
            if let ref = stmt.columnText(1) {
                refs.append(ref)
            }
        }
        return DeletePlan(ids: ids, storageRefs: refs)
    }

    func planCleanupByTotalSize(targetBytes: Int) throws -> DeletePlan {
        try planCleanupByTotalSize(targetBytes: targetBytes, typeFilter: nil)
    }

    func planCleanupByTotalSize(targetBytes: Int, typeFilter: ClipboardItemType?) throws -> DeletePlan {
        let currentSize = try getTotalSize()
        guard currentSize > targetBytes else { return DeletePlan(ids: [], storageRefs: []) }

        let excessBytes = currentSize - targetBytes

        var sql = """
            SELECT id, size_bytes, storage_ref FROM clipboard_items
            WHERE is_pinned = 0
        """
        if typeFilter != nil {
            sql += " AND type = ?"
        }
        sql += """

            ORDER BY last_used_at ASC
            LIMIT 10000
        """
        let stmt = try prepare(sql)
        if let typeFilter {
            try stmt.bindText(typeFilter.rawValue, at: 1)
        }

        var ids: [UUID] = []
        var refs: [String] = []
        var accumulatedSize = 0

        while try stmt.step() {
            guard let idString = stmt.columnText(0),
                  let id = UUID(uuidString: idString) else { continue }

            let size = stmt.columnInt(1)
            let ref = stmt.columnText(2)

            ids.append(id)
            accumulatedSize += size
            if let ref {
                refs.append(ref)
            }

            if accumulatedSize >= excessBytes {
                break
            }
        }

        return DeletePlan(ids: ids, storageRefs: refs)
    }

    func planCleanupExternalStorage(excessBytes: Int) throws -> DeletePlan {
        try planCleanupExternalStorage(excessBytes: excessBytes, typeFilter: nil)
    }

    func planCleanupExternalStorage(excessBytes: Int, typeFilter: ClipboardItemType?) throws -> DeletePlan {
        var sql = """
            SELECT id, size_bytes, storage_ref FROM clipboard_items
            WHERE is_pinned = 0 AND storage_ref IS NOT NULL
        """
        if typeFilter != nil {
            sql += " AND type = ?"
        }
        sql += """

            ORDER BY last_used_at ASC
            LIMIT 5000
        """
        let stmt = try prepare(sql)
        if let typeFilter {
            try stmt.bindText(typeFilter.rawValue, at: 1)
        }

        var ids: [UUID] = []
        var refs: [String] = []
        var accumulatedSize = 0

        while try stmt.step() {
            guard let idString = stmt.columnText(0),
                  let id = UUID(uuidString: idString),
                  let ref = stmt.columnText(2) else { continue }

            let size = stmt.columnInt(1)

            ids.append(id)
            refs.append(ref)
            accumulatedSize += size

            if accumulatedSize >= excessBytes {
                break
            }
        }

        return DeletePlan(ids: ids, storageRefs: refs)
    }

    func planCleanupUnpinnedImages(limit: Int) throws -> DeletePlan {
        guard limit > 0 else { return DeletePlan(ids: [], storageRefs: []) }

        let sql = """
            SELECT id, storage_ref FROM clipboard_items
            WHERE is_pinned = 0 AND type = ?
            ORDER BY last_used_at ASC
            LIMIT ?
        """
        let stmt = try prepare(sql)
        try stmt.bindText(ClipboardItemType.image.rawValue, at: 1)
        try stmt.bindInt(limit, at: 2)

        var ids: [UUID] = []
        var refs: [String] = []
        ids.reserveCapacity(limit)

        while try stmt.step() {
            guard let idString = stmt.columnText(0),
                  let id = UUID(uuidString: idString) else { continue }
            ids.append(id)
            if let ref = stmt.columnText(1) {
                refs.append(ref)
            }
        }

        return DeletePlan(ids: ids, storageRefs: refs)
    }

    func deleteItemsBatchInTransaction(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try performWriteTransaction {
            let batchSize = 999
            for batchStart in stride(from: 0, to: ids.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, ids.count)
                let batch = Array(ids[batchStart..<batchEnd])
                try deleteItemsBatch(ids: batch)
            }
        }
    }

    func incrementalVacuum(pages: Int) throws {
        try execute("PRAGMA incremental_vacuum(\(pages))")
    }

    // MARK: - Internals

    private static func openFlags(for path: String) -> Int32 {
        var flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        if path.hasPrefix("file:") {
            flags |= SQLITE_OPEN_URI
        }
        return flags
    }

    private func bumpMutationSeq() throws {
        try execute("UPDATE scopy_meta SET mutation_seq = mutation_seq + 1 WHERE id = 1")
    }

    private func performWriteTransaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try body()
            try bumpMutationSeq()
            try execute("COMMIT")
        } catch {
            do {
                try execute("ROLLBACK")
            } catch {
                isDatabaseCorrupted = true
                try recoverDatabase()
            }
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard let connection else { throw RepositoryError.databaseNotOpen }
        do {
            try connection.execute(sql)
        } catch {
            throw RepositoryError.queryFailed(error.localizedDescription)
        }
    }

    private func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let connection else { throw RepositoryError.databaseNotOpen }
        do {
            return try connection.prepare(sql)
        } catch {
            throw RepositoryError.queryFailed(error.localizedDescription)
        }
    }

    private func verifySchema(_ connection: SQLiteConnection) throws {
        // Main table
        let mainStmt = try connection.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='clipboard_items'")
        guard try mainStmt.step() else {
            throw RepositoryError.migrationFailed("Main table 'clipboard_items' not found")
        }

        // FTS table
        let ftsStmt = try connection.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='clipboard_fts'")
        guard try ftsStmt.step() else {
            throw RepositoryError.migrationFailed("FTS table 'clipboard_fts' not found")
        }
    }

    private func parseStoredItem(from stmt: SQLiteStatement) throws -> ClipboardStoredItem {
        guard let idString = stmt.columnText(0),
              let id = UUID(uuidString: idString),
              let typeString = stmt.columnText(1),
              let type = ClipboardItemType(rawValue: typeString),
              let contentHash = stmt.columnText(2) else {
            throw RepositoryError.queryFailed("Failed to parse item")
        }

        let plainText = stmt.columnText(3) ?? ""
        let note = stmt.columnText(4)
        let appBundleID = stmt.columnText(5)
        let createdAt = Date(timeIntervalSince1970: stmt.columnDouble(6))
        let lastUsedAt = Date(timeIntervalSince1970: stmt.columnDouble(7))
        let useCount = stmt.columnInt(8)
        let isPinned = stmt.columnInt(9) != 0
        let sizeBytes = stmt.columnInt(10)
        let storageRef = stmt.columnText(11)
        let rawData = stmt.columnBlobData(12)
        let fileSizeBytes = stmt.columnIntOptional(13)

        return ClipboardStoredItem(
            id: id,
            type: type,
            contentHash: contentHash,
            plainText: plainText,
            note: note,
            appBundleID: appBundleID,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            useCount: useCount,
            isPinned: isPinned,
            sizeBytes: sizeBytes,
            fileSizeBytes: fileSizeBytes,
            storageRef: storageRef,
            rawData: rawData
        )
    }

    private func parseStoredItemSummary(from stmt: SQLiteStatement) throws -> ClipboardStoredItem {
        guard let idString = stmt.columnText(0),
              let id = UUID(uuidString: idString),
              let typeString = stmt.columnText(1),
              let type = ClipboardItemType(rawValue: typeString),
              let contentHash = stmt.columnText(2) else {
            throw RepositoryError.queryFailed("Failed to parse item")
        }

        let plainText = stmt.columnText(3) ?? ""
        let note = stmt.columnText(4)
        let appBundleID = stmt.columnText(5)
        let createdAt = Date(timeIntervalSince1970: stmt.columnDouble(6))
        let lastUsedAt = Date(timeIntervalSince1970: stmt.columnDouble(7))
        let useCount = stmt.columnInt(8)
        let isPinned = stmt.columnInt(9) != 0
        let sizeBytes = stmt.columnInt(10)
        let storageRef = stmt.columnText(11)
        let fileSizeBytes = stmt.columnIntOptional(12)

        return ClipboardStoredItem(
            id: id,
            type: type,
            contentHash: contentHash,
            plainText: plainText,
            note: note,
            appBundleID: appBundleID,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            useCount: useCount,
            isPinned: isPinned,
            sizeBytes: sizeBytes,
            fileSizeBytes: fileSizeBytes,
            storageRef: storageRef,
            rawData: nil
        )
    }

    private func deleteItemsBatch(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }

        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "DELETE FROM clipboard_items WHERE id IN (\(placeholders))"

        let stmt = try prepare(sql)
        for (index, id) in ids.enumerated() {
            try stmt.bindText(id.uuidString, at: Int32(index + 1))
        }
        _ = try stmt.step()
    }

    private func recoverDatabase() throws {
        close()
        try open()
        isDatabaseCorrupted = false
    }
}
