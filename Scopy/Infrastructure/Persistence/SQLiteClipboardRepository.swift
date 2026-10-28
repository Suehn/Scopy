import Foundation
import SQLite3

actor SQLiteClipboardRepository {
    enum RepositoryError: Error, LocalizedError {
        case databaseNotOpen
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case .databaseNotOpen: return "Database is not open"
            case .queryFailed(let msg): return "Query failed: \(msg)"
            }
        }
    }

    struct DeleteCandidate: Sendable {
        let id: UUID
        let type: ClipboardItemType
        let contentHash: String
        let lastUsedAt: Date
        let sizeBytes: Int
        let storageRef: String?
    }

    struct DeletePlan: Sendable {
        let candidates: [DeleteCandidate]

        var ids: [UUID] { candidates.map(\.id) }
        var storageRefs: [String] { candidates.compactMap(\.storageRef) }

        static let empty = DeletePlan(candidates: [])
    }

    struct DeleteCommitResult: Sendable {
        let plannedCount: Int
        let deletedItemIDs: [UUID]
        let storageRefs: [String]

        var skippedCount: Int { max(0, plannedCount - deletedItemIDs.count) }
    }

    enum IngestReceiptLookup: Sendable {
        case missing
        case alreadyApplied(ClipboardStoredItem?)
    }

    enum IngestUpsertOutcome: Sendable {
        case inserted(ClipboardStoredItem)
        case updated(ClipboardStoredItem)
        case alreadyApplied(ClipboardStoredItem?)
    }

    enum ExistingIngestCommitOutcome: Sendable {
        case needsInsert
        case updated(ClipboardStoredItem)
        case alreadyApplied(ClipboardStoredItem?)
    }

    static func mergeDeletePlans(_ plans: [DeletePlan]) -> DeletePlan {
        guard !plans.isEmpty else { return .empty }

        var mergedCandidates: [DeleteCandidate] = []
        var seenIDs: Set<UUID> = []

        for plan in plans {
            for candidate in plan.candidates where seenIDs.insert(candidate.id).inserted {
                mergedCandidates.append(candidate)
            }
        }
        return DeletePlan(candidates: mergedCandidates)
    }

    struct ExternalStorageSizeRecord: Sendable {
        let id: UUID
        let contentHash: String
        let sizeBytes: Int
        let storageRef: String
    }

    struct SizeBytesUpdate: Sendable {
        let id: UUID
        let expectedContentHash: String
        let expectedSizeBytes: Int
        let expectedStorageRef: String
        let sizeBytes: Int
    }

    enum MetadataUpdateKind: Sendable {
        case note
        case fileSizeBytes
    }

    private enum MetadataUpdate {
        case note(String?)
        case fileSizeBytes(expected: ClipboardStoredItem, value: Int?)
    }

    private let dbPath: String
    private var connection: SQLiteConnection?
    private var metadataUpdateInterlock: (@Sendable (MetadataUpdateKind, UUID) async -> Void)?
    #if DEBUG
    private var historyReadInterlockForTesting: (@Sendable () throws -> Void)?
    #endif
    /// One entry per committed write, read independently by search and presentation.
    nonisolated let commitJournal = StorageCommitJournal()

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
            try SQLiteSchema.requireCurrentSchema(conn)
            let position = try conn.prepare("SELECT mutation_seq FROM scopy_meta WHERE id = 1")
            guard try position.step() else {
                throw RepositoryError.queryFailed("scopy_meta row is missing")
            }
            commitJournal.reset(to: position.columnInt64(0))
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

    func setMetadataUpdateInterlockForTesting(
        _ interlock: (@Sendable (MetadataUpdateKind, UUID) async -> Void)?
    ) {
        metadataUpdateInterlock = interlock
    }

    #if DEBUG
    func setHistoryReadInterlockForTesting(_ interlock: (@Sendable () throws -> Void)?) {
        historyReadInterlockForTesting = interlock
    }
    #endif

    func fetchItemByHash(_ hash: String) throws -> ClipboardStoredItem? {
        let sql = """
            SELECT \(ClipboardItemRow.fullColumns)
            FROM clipboard_items
            WHERE content_hash = ? LIMIT 1
        """
        let stmt = try prepare(sql)
        try stmt.bindText(hash, at: 1)
        if try stmt.step() {
            return try ClipboardItemRow.decodeFull(stmt)
        }
        return nil
    }

    func fetchItemByID(_ id: UUID) throws -> ClipboardStoredItem? {
        let sql = """
            SELECT \(ClipboardItemRow.fullColumns)
            FROM clipboard_items
            WHERE id = ? LIMIT 1
        """
        let stmt = try prepare(sql)
        try stmt.bindText(id.uuidString, at: 1)
        if try stmt.step() {
            return try ClipboardItemRow.decodeFull(stmt)
        }
        return nil
    }

    private func fetchItemSummaryByID(_ id: UUID) throws -> ClipboardStoredItem? {
        let stmt = try prepare(
            "SELECT \(ClipboardItemRow.summaryColumns) FROM clipboard_items WHERE id = ? LIMIT 1"
        )
        try stmt.bindText(id.uuidString, at: 1)
        return try stmt.step() ? ClipboardItemRow.decodeSummary(stmt) : nil
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
            try insertItemRow(
                id: id,
                type: type,
                contentHash: contentHash,
                plainText: plainText,
                note: note,
                appBundleID: appBundleID,
                createdAt: createdAt,
                lastUsedAt: lastUsedAt,
                sizeBytes: sizeBytes,
                fileSizeBytes: fileSizeBytes,
                storageRef: storageRef,
                rawData: rawData
            )
            guard let inserted = try fetchItemSummaryByID(id) else {
                throw RepositoryError.queryFailed("Inserted row could not be read back")
            }
            return .upserted(inserted, kind: .inserted)
        }
    }

    /// Resolves an existing receipt under BEGIN IMMEDIATE before external file work. A missing
    /// result is only advisory; the final receipt/hash decision is repeated by
    /// `upsertItemForIngest` after candidate publication.
    func resolveExistingIngestReceipt(_ ingestID: UUID) throws -> IngestReceiptLookup {
        var result: IngestReceiptLookup = .missing
        try performMaintenanceWriteTransaction {
            guard let itemID = try fetchIngestReceiptItemID(ingestID) else { return }
            result = .alreadyApplied(try fetchItemByID(itemID))
        }
        return result
    }

    /// Read-only hint. Callers must never publish or acknowledge from this result; it only avoids
    /// taking a write transaction for the common new-content path.
    func mightResolveIngestWithoutFileWork(ingestID: UUID, contentHash: String) throws -> Bool {
        if try fetchIngestReceiptItemID(ingestID) != nil { return true }
        return try fetchItemByHash(contentHash) != nil
    }

    /// Finalizes only receipt replay or an existing-hash use. If the advisory row disappeared,
    /// returns `needsInsert`; the caller then publishes a candidate and uses the full final upsert.
    func commitExistingIngestIfPossible(
        ingestID: UUID,
        contentHash: String,
        lastUsedAt: Date
    ) throws -> ExistingIngestCommitOutcome {
        var outcome: ExistingIngestCommitOutcome = .needsInsert
        try performWriteTransaction {
            if let receiptItemID = try fetchIngestReceiptItemID(ingestID) {
                outcome = .alreadyApplied(try fetchItemByID(receiptItemID))
                return nil
            }
            guard let existing = try fetchItemByHash(contentHash) else { return nil }
            let updated = try incrementUsageRow(existing.id, lastUsedAt: lastUsedAt)
            try insertIngestReceipt(ingestID: ingestID, itemID: updated.id, committedAt: lastUsedAt)
            outcome = .updated(updated)
            return .upserted(updated, kind: .usage)
        }
        return outcome
    }

    /// Atomically applies one durable envelope. Receipt lookup, final hash recheck, item mutation,
    /// and receipt insertion share the same write transaction so replay cannot increment usage
    /// twice or resurrect a later-deleted row.
    func upsertItemForIngest(
        ingestID: UUID,
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
    ) throws -> IngestUpsertOutcome {
        var outcome: IngestUpsertOutcome?
        try performWriteTransaction {
            if let receiptItemID = try fetchIngestReceiptItemID(ingestID) {
                outcome = .alreadyApplied(try fetchItemByID(receiptItemID))
                return nil
            }

            if let existing = try fetchItemByHash(contentHash) {
                let updated = try incrementUsageRow(existing.id, lastUsedAt: lastUsedAt)
                try insertIngestReceipt(ingestID: ingestID, itemID: updated.id, committedAt: lastUsedAt)
                outcome = .updated(updated)
                return .upserted(updated, kind: .usage)
            }

            try insertItemRow(
                id: id,
                type: type,
                contentHash: contentHash,
                plainText: plainText,
                note: note,
                appBundleID: appBundleID,
                createdAt: createdAt,
                lastUsedAt: lastUsedAt,
                sizeBytes: sizeBytes,
                fileSizeBytes: fileSizeBytes,
                storageRef: storageRef,
                rawData: rawData
            )
            try insertIngestReceipt(ingestID: ingestID, itemID: id, committedAt: lastUsedAt)
            guard let inserted = try fetchItemByID(id) else {
                throw RepositoryError.queryFailed("Inserted ingest row could not be read back")
            }
            outcome = .inserted(inserted)
            return .upserted(inserted, kind: .inserted)
        }

        guard let outcome else {
            throw RepositoryError.queryFailed("Ingest transaction produced no outcome")
        }
        return outcome
    }

    /// Receipt cleanup is maintenance metadata: it intentionally does not advance mutation_seq
    /// because item/search authority is unchanged.
    func removeIngestReceipt(_ ingestID: UUID) throws {
        try performMaintenanceWriteTransaction {
            let stmt = try prepare("DELETE FROM ingest_receipts WHERE ingest_id = ?")
            try stmt.bindText(ingestID.uuidString, at: 1)
            _ = try stmt.step()
        }
    }

    func ingestReceiptCount() throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM ingest_receipts")
        guard try stmt.step() else { return 0 }
        return stmt.columnInt(0)
    }

    /// Atomically records one use and returns the complete row that won the transaction. Using an
    /// increment in SQL prevents concurrent callers from overwriting each other's counts, while
    /// `MAX` prevents an older suspended command from moving `last_used_at` backwards.
    func incrementUsageReturningCurrent(id: UUID, lastUsedAt: Date) throws -> ClipboardStoredItem? {
        var updatedItem: ClipboardStoredItem?
        try performWriteTransaction {
            guard try fetchItemByID(id) != nil else { return nil }

            let stmt = try prepare(
                """
                UPDATE clipboard_items
                SET last_used_at = MAX(last_used_at, ?), use_count = use_count + 1
                WHERE id = ?
                """
            )
            try stmt.bindDouble(lastUsedAt.timeIntervalSince1970, at: 1)
            try stmt.bindText(id.uuidString, at: 2)
            _ = try stmt.step()
            updatedItem = try fetchItemByID(id)
            return updatedItem.map { .upserted($0, kind: .usage) }
        }
        return updatedItem
    }

    func updatePin(id: UUID, pinned: Bool) throws {
        try performWriteTransaction {
            let sql = "UPDATE clipboard_items SET is_pinned = ? WHERE id = ? AND is_pinned <> ?"
            let stmt = try prepare(sql)
            try stmt.bindInt(pinned ? 1 : 0, at: 1)
            try stmt.bindText(id.uuidString, at: 2)
            try stmt.bindInt(pinned ? 1 : 0, at: 3)
            _ = try stmt.step()
            guard (connection?.changeCount() ?? 0) > 0 else { return nil }
            guard let updated = try fetchItemSummaryByID(id) else {
                throw RepositoryError.queryFailed("Updated row could not be read back")
            }
            return .upserted(updated, kind: .pin)
        }
    }

    /// Replaces only the payload columns when the row still owns the exact payload snapshot that
    /// the caller read before doing asynchronous work. Metadata-only changes (pin, note, usage)
    /// intentionally do not invalidate payload ownership.
    ///
    /// The read/compare/write sequence runs inside one `BEGIN IMMEDIATE` transaction, so another
    /// repository writer cannot replace the same row between validation and mutation. This is a
    /// schema-free optimistic-concurrency boundary for image optimization and similar transforms.
    func compareAndSwapItemPayload(
        expected: ClipboardStoredItem,
        contentHash: String,
        sizeBytes: Int,
        storageRef: String?,
        rawData: Data?
    ) throws -> ClipboardStoredItem? {
        var committedItem: ClipboardStoredItem?
        try performWriteTransaction {
            guard let current = try fetchItemByID(expected.id),
                  Self.hasSamePayload(current, as: expected) else {
                return nil
            }
            if current.contentHash == contentHash,
               current.sizeBytes == sizeBytes,
               current.storageRef == storageRef,
               current.rawData == rawData {
                committedItem = current
                return nil
            }

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
            try stmt.bindText(expected.id.uuidString, at: 5)
            _ = try stmt.step()
            committedItem = ClipboardStoredItem(
                id: current.id,
                type: current.type,
                contentHash: contentHash,
                plainText: current.plainText,
                note: current.note,
                appBundleID: current.appBundleID,
                createdAt: current.createdAt,
                lastUsedAt: current.lastUsedAt,
                useCount: current.useCount,
                isPinned: current.isPinned,
                sizeBytes: sizeBytes,
                fileSizeBytes: current.fileSizeBytes,
                storageRef: storageRef,
                rawData: rawData
            )
            return committedItem.map { .upserted($0, kind: .content) }
        }
        return committedItem
    }

    func updateItemNoteReturningItem(id: UUID, note: String?) async throws -> ClipboardStoredItem? {
        await metadataUpdateInterlock?(.note, id)
        return try updateMetadataAndReturnCurrent(id: id, update: .note(note))
    }

    func updateItemFileSizeBytesReturningItem(
        expected: ClipboardStoredItem,
        fileSizeBytes: Int?
    ) async throws -> ClipboardStoredItem? {
        await metadataUpdateInterlock?(.fileSizeBytes, expected.id)
        return try updateMetadataAndReturnCurrent(
            id: expected.id,
            update: .fileSizeBytes(expected: expected, value: fileSizeBytes)
        )
    }

    /// The caller's immutable usage count identifies the version it intended to delete. A
    /// recopy wins over that intent; metadata changes alone do not prevent the deletion.
    func deleteItem(id: UUID, expectedUseCount: Int) throws -> (
        item: ClipboardStoredItem?, mutationSeq: Int64, storageRef: String?
    ) {
        var retainedItem: ClipboardStoredItem?
        var storageRef: String?
        let mutationSeq = try performWriteTransaction {
            guard let current = try fetchItemSummaryByID(id) else { return nil }
            guard current.useCount == expectedUseCount else {
                retainedItem = current
                return nil
            }
            if let ref = current.storageRef, !ref.isEmpty {
                storageRef = ref
            }

            let sql = "DELETE FROM clipboard_items WHERE id = ?"
            let stmt = try prepare(sql)
            try stmt.bindText(id.uuidString, at: 1)
            _ = try stmt.step()
            return .deleted([id])
        }
        return (retainedItem, mutationSeq, storageRef)
    }

    func deleteAllExceptPinnedReturningStorageRefs() throws -> [String] {
        var refs: [String] = []
        try performWriteTransaction {
            var deletedItemIDs: [UUID] = []
            // Finalize the statement before running the DELETE to avoid locking the table in the same connection.
            do {
                let sql = "SELECT id, storage_ref FROM clipboard_items WHERE is_pinned = 0"
                let stmt = try prepare(sql)
                while try stmt.step() {
                    guard let idString = stmt.columnText(0), let id = UUID(uuidString: idString) else {
                        throw ClipboardItemRow.DecodeError.invalidRow
                    }
                    deletedItemIDs.append(id)
                    if let ref = stmt.columnText(1), !ref.isEmpty {
                        refs.append(ref)
                    }
                }
            }
            try execute("DELETE FROM clipboard_items WHERE is_pinned = 0")
            return .clearedUnpinned(deletedItemIDs: deletedItemIDs)
        }
        return refs
    }

    func fetchExternalStorageSizeRecords(typeFilter: ClipboardItemType?) throws -> [ExternalStorageSizeRecord] {
        var sql = """
            SELECT id, content_hash, size_bytes, storage_ref
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
                  let contentHash = stmt.columnText(1),
                  let storageRef = stmt.columnText(3),
                  !storageRef.isEmpty else { continue }

            records.append(
                ExternalStorageSizeRecord(
                    id: id,
                    contentHash: contentHash,
                    sizeBytes: stmt.columnInt(2),
                    storageRef: storageRef
                )
            )
        }
        return records
    }

    func fetchRecent(limit: Int, offset: Int) throws -> [ClipboardStoredItem] {
        let sql = """
            SELECT \(ClipboardItemRow.summaryColumns)
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
            items.append(try ClipboardItemRow.decodeSummary(stmt))
        }
        return items
    }

    func fetchPinned() throws -> [ClipboardStoredItem] {
        let sql = """
            SELECT \(ClipboardItemRow.summaryColumns)
            FROM clipboard_items
            WHERE is_pinned = 1
            ORDER BY last_used_at DESC, id ASC
        """
        let stmt = try prepare(sql)

        var items: [ClipboardStoredItem] = []
        while try stmt.step() {
            items.append(try ClipboardItemRow.decodeSummary(stmt))
        }
        return items
    }

    /// Up to `limit` unpinned rows strictly after `cursor` in recent order, walked on
    /// `idx_recent_order` from the cursor's key: a deep page costs the same as the first.
    private func fetchUnpinned(limit: Int, after cursor: RecentHistoryCursor?) throws -> [ClipboardStoredItem] {
        let keyset = cursor == nil ? "" : "AND last_used_at <= ?2 AND (last_used_at < ?2 OR id > ?3)"
        let sql = """
            SELECT \(ClipboardItemRow.summaryColumns)
            FROM clipboard_items
            WHERE is_pinned = 0 \(keyset)
            ORDER BY last_used_at DESC, id ASC
            LIMIT ?1
        """
        let stmt = try prepare(sql)
        try stmt.bindInt(limit, at: 1)
        if let cursor {
            try stmt.bindDouble(cursor.lastUsedAt.timeIntervalSince1970, at: 2)
            try stmt.bindText(cursor.id.uuidString, at: 3)
        }

        var items: [ClipboardStoredItem] = []
        items.reserveCapacity(limit)
        while try stmt.step() {
            items.append(try ClipboardItemRow.decodeSummary(stmt))
        }
        return items
    }

    /// The recent page after `cursor` (the first page, with every pinned row, when `nil`) and the
    /// total, from one read snapshot. One row past the page decides whether a next page exists.
    func fetchHistoryPage(limit: Int, after cursor: RecentHistoryCursor?) throws -> (
        pinned: [ClipboardStoredItem], items: [ClipboardStoredItem], total: Int,
        nextCursor: RecentHistoryCursor?, mutationSeq: Int64
    ) {
        let limit = max(1, limit)
        try execute("BEGIN DEFERRED TRANSACTION")
        do {
            let pinned = cursor == nil ? try fetchPinned() : []
            var items = try fetchUnpinned(limit: limit + 1, after: cursor)
            let total: Int
            let mutationSeq: Int64
            do {
                let position = try prepare("SELECT item_count, mutation_seq FROM scopy_meta WHERE id = 1")
                guard try position.step() else {
                    throw RepositoryError.queryFailed("scopy_meta row is missing")
                }
                total = position.columnInt(0)
                mutationSeq = position.columnInt64(1)
            }
            try execute("COMMIT")
            let hasMore = items.count > limit
            if hasMore { items.removeLast() }
            let nextCursor = hasMore ? items.last.map { RecentHistoryCursor(lastUsedAt: $0.lastUsedAt, id: $0.id) } : nil
            return (pinned, items, total, nextCursor, mutationSeq)
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Reads only requested identities from one snapshot. A requested ID absent from `items`
    /// does not exist at the returned sequence, including when the request spans SQL batches.
    func fetchHistoryItems(itemIDs: Set<UUID>) throws -> (items: [ClipboardStoredItem], mutationSeq: Int64) {
        try execute("BEGIN DEFERRED TRANSACTION")
        do {
            let mutationSeq: Int64
            do {
                let position = try prepare("SELECT mutation_seq FROM scopy_meta WHERE id = 1")
                guard try position.step() else {
                    throw RepositoryError.queryFailed("scopy_meta row is missing")
                }
                mutationSeq = position.columnInt64(0)
            }

            let ids = itemIDs.sorted { $0.uuidString < $1.uuidString }
            var items: [ClipboardStoredItem] = []
            items.reserveCapacity(ids.count)
            let batchSize = 900
            for start in stride(from: 0, to: ids.count, by: batchSize) {
                let batch = ids[start..<min(start + batchSize, ids.count)]
                let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                let statement = try prepare(
                    "SELECT \(ClipboardItemRow.summaryColumns) FROM clipboard_items WHERE id IN (\(placeholders)) ORDER BY id"
                )
                for (index, id) in batch.enumerated() {
                    try statement.bindText(id.uuidString, at: Int32(index + 1))
                }
                while try statement.step() {
                    items.append(try ClipboardItemRow.decodeSummary(statement))
                }
                #if DEBUG
                if start == 0 {
                    try historyReadInterlockForTesting?()
                }
                #endif
            }
            try execute("COMMIT")
            return (items, mutationSeq)
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
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
        let stmt = try prepare("SELECT item_count FROM scopy_meta WHERE id = 1")
        guard try stmt.step() else { return 0 }
        return stmt.columnInt(0)
    }

    func getTotalSize() throws -> Int {
        let stmt = try prepare("SELECT total_size_bytes FROM scopy_meta WHERE id = 1")
        guard try stmt.step() else { return 0 }
        let value = stmt.columnInt64(0)
        return Int(min(value, Int64(Int.max)))
    }

    func getExternalSize() throws -> Int {
        let stmt = try prepare("SELECT external_size_bytes FROM scopy_meta WHERE id = 1")
        guard try stmt.step() else { return 0 }
        let value = stmt.columnInt64(0)
        return Int(min(value, Int64(Int.max)))
    }

    func updateItemSizeBytesBatchInTransaction(updates: [SizeBytesUpdate]) throws -> Int {
        guard !updates.isEmpty else { return 0 }
        var updatedCount = 0
        try performWriteTransaction {
            var updatedItems: [ClipboardStoredItem] = []
            let stmt = try prepare(
                """
                UPDATE clipboard_items
                SET size_bytes = ?
                WHERE id = ? AND content_hash = ? AND size_bytes = ? AND storage_ref = ?
                """
            )
            for update in updates where update.sizeBytes != update.expectedSizeBytes {
                stmt.reset()
                try stmt.bindInt(update.sizeBytes, at: 1)
                try stmt.bindText(update.id.uuidString, at: 2)
                try stmt.bindText(update.expectedContentHash, at: 3)
                try stmt.bindInt(update.expectedSizeBytes, at: 4)
                try stmt.bindText(update.expectedStorageRef, at: 5)
                _ = try stmt.step()
                guard (connection?.changeCount() ?? 0) > 0 else { continue }
                guard let item = try fetchItemSummaryByID(update.id) else {
                    throw RepositoryError.queryFailed("Updated row could not be read back")
                }
                updatedItems.append(item)
                updatedCount += 1
            }
            return updatedItems.isEmpty ? nil : .storageSizesUpdated(updatedItems)
        }
        return updatedCount
    }

    /// Distinct (type, content hash) pairs of rows that can own a thumbnail.
    func fetchThumbnailOwners() throws -> [(type: ClipboardItemType, contentHash: String)] {
        let stmt = try prepare(
            "SELECT DISTINCT type, content_hash FROM clipboard_items WHERE type IN ('image', 'file')"
        )
        var owners: [(type: ClipboardItemType, contentHash: String)] = []
        while try stmt.step() {
            guard let typeString = stmt.columnText(0),
                  let type = ClipboardItemType(rawValue: typeString),
                  let contentHash = stmt.columnText(1) else { continue }
            owners.append((type: type, contentHash: contentHash))
        }
        return owners
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

    func isStorageRefReferenced(_ storageRef: String) throws -> Bool {
        let filename = (storageRef as NSString).lastPathComponent
        let escapedFilename = filename
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let stmt = try prepare(
            """
            SELECT 1
            FROM clipboard_items
            WHERE storage_ref = ? OR storage_ref LIKE ? ESCAPE '\\'
            LIMIT 1
            """
        )
        try stmt.bindText(storageRef, at: 1)
        try stmt.bindText("%/\(escapedFilename)", at: 2)
        return try stmt.step()
    }

    /// Batch ownership check for post-commit cleanup. Callers hold process-wide file reservations
    /// for these exact paths while this query and unlink run, avoiding per-file actor round trips.
    func unreferencedStorageRefs(_ storageRefs: [String]) throws -> Set<String> {
        guard !storageRefs.isEmpty else { return [] }
        var unreferenced = Set(storageRefs)
        let batchSize = 900

        for batchStart in stride(from: 0, to: storageRefs.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, storageRefs.count)
            let batch = Array(storageRefs[batchStart..<batchEnd])
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            let stmt = try prepare(
                """
                SELECT DISTINCT storage_ref
                FROM clipboard_items
                WHERE storage_ref IN (\(placeholders))
                """
            )
            for (index, storageRef) in batch.enumerated() {
                try stmt.bindText(storageRef, at: Int32(index + 1))
            }
            while try stmt.step() {
                if let referenced = stmt.columnText(0) {
                    unreferenced.remove(referenced)
                }
            }
        }
        return unreferenced
    }

    func planCleanupByCount(target: Int) throws -> DeletePlan {
        let stmt = try prepare("SELECT unpinned_count FROM scopy_meta WHERE id = 1")
        guard try stmt.step() else { return .empty }
        let currentCount = stmt.columnInt(0)

        let deleteCount = currentCount - target
        guard deleteCount > 0 else { return .empty }

        let selectSQL = """
            SELECT id, type, content_hash, last_used_at, size_bytes, storage_ref
            FROM clipboard_items
            WHERE is_pinned = 0
            ORDER BY last_used_at ASC, id ASC
            LIMIT ?
        """
        let selectStmt = try prepare(selectSQL)
        try selectStmt.bindInt(deleteCount, at: 1)

        var candidates: [DeleteCandidate] = []
        candidates.reserveCapacity(deleteCount)

        while try selectStmt.step() {
            if let candidate = try parseDeleteCandidate(from: selectStmt) {
                candidates.append(candidate)
            }
        }

        return DeletePlan(candidates: candidates)
    }

    func planCleanupByAge(cutoff: Date) throws -> DeletePlan {
        try planCleanupByAge(cutoff: cutoff, typeFilter: nil)
    }

    func planCleanupByAge(cutoff: Date, typeFilter: ClipboardItemType?) throws -> DeletePlan {
        var selectSQL = """
            SELECT id, type, content_hash, last_used_at, size_bytes, storage_ref
            FROM clipboard_items
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

        var candidates: [DeleteCandidate] = []
        while try stmt.step() {
            if let candidate = try parseDeleteCandidate(from: stmt) {
                candidates.append(candidate)
            }
        }
        return DeletePlan(candidates: candidates)
    }

    func planCleanupByTotalSize(targetBytes: Int) throws -> DeletePlan {
        try planCleanupByTotalSize(targetBytes: targetBytes, typeFilter: nil)
    }

    func planCleanupByTotalSize(targetBytes: Int, typeFilter: ClipboardItemType?) throws -> DeletePlan {
        let currentSize = try getTotalSize()
        guard currentSize > targetBytes else { return .empty }

        let excessBytes = currentSize - targetBytes

        var sql = """
            SELECT id, type, content_hash, last_used_at, size_bytes, storage_ref
            FROM clipboard_items
            WHERE is_pinned = 0
        """
        if typeFilter != nil {
            sql += " AND type = ?"
        }
        sql += """

            ORDER BY last_used_at ASC
        """
        let stmt = try prepare(sql)
        if let typeFilter {
            try stmt.bindText(typeFilter.rawValue, at: 1)
        }

        var candidates: [DeleteCandidate] = []
        var accumulatedSize = 0

        while try stmt.step() {
            guard let candidate = try parseDeleteCandidate(from: stmt) else { continue }
            candidates.append(candidate)
            accumulatedSize += candidate.sizeBytes

            if accumulatedSize >= excessBytes {
                break
            }
        }

        return DeletePlan(candidates: candidates)
    }

    func sumExternalBytes(ids: [UUID]) throws -> Int {
        guard !ids.isEmpty else { return 0 }

        let batchSize = 900
        var total: Int64 = 0

        for batchStart in stride(from: 0, to: ids.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, ids.count)
            let batch = Array(ids[batchStart..<batchEnd])
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            let sql = """
                SELECT COALESCE(SUM(size_bytes), 0)
                FROM clipboard_items
                WHERE storage_ref IS NOT NULL AND storage_ref <> ''
                  AND id IN (\(placeholders))
                """
            let stmt = try prepare(sql)
            for (index, id) in batch.enumerated() {
                try stmt.bindText(id.uuidString, at: Int32(index + 1))
            }
            guard try stmt.step() else { continue }
            total += max(0, stmt.columnInt64(0))
        }

        return Int(min(total, Int64(Int.max)))
    }

    func planCleanupExternalStorage(excessBytes: Int) throws -> DeletePlan {
        try planCleanupExternalStorage(excessBytes: excessBytes, typeFilter: nil, excludingIDs: [])
    }

    func planCleanupExternalStorage(excessBytes: Int, typeFilter: ClipboardItemType?) throws -> DeletePlan {
        try planCleanupExternalStorage(excessBytes: excessBytes, typeFilter: typeFilter, excludingIDs: [])
    }

    func planCleanupExternalStorage(
        excessBytes: Int,
        typeFilter: ClipboardItemType?,
        excludingIDs: Set<UUID>
    ) throws -> DeletePlan {
        var sql = """
            SELECT id, type, content_hash, last_used_at, size_bytes, storage_ref
            FROM clipboard_items
            WHERE is_pinned = 0 AND storage_ref IS NOT NULL
        """
        if typeFilter != nil {
            sql += " AND type = ?"
        }
        sql += " AND storage_ref <> ''"
        sql += " ORDER BY last_used_at ASC, id ASC"
        let stmt = try prepare(sql)
        if let typeFilter {
            try stmt.bindText(typeFilter.rawValue, at: 1)
        }

        var candidates: [DeleteCandidate] = []
        var accumulatedSize: Int64 = 0
        let targetBytes = Int64(max(0, excessBytes))

        while try stmt.step() {
            guard let candidate = try parseDeleteCandidate(from: stmt),
                  candidate.storageRef != nil else { continue }
            if excludingIDs.contains(candidate.id) { continue }

            candidates.append(candidate)
            let size = max(Int64(0), Int64(candidate.sizeBytes))
            accumulatedSize += size

            if accumulatedSize >= targetBytes {
                break
            }
        }

        return DeletePlan(candidates: candidates)
    }

    func planCleanupUnpinnedImages(limit: Int) throws -> DeletePlan {
        guard limit > 0 else { return .empty }

        let sql = """
            SELECT id, type, content_hash, last_used_at, size_bytes, storage_ref
            FROM clipboard_items
            WHERE is_pinned = 0 AND type = ?
            ORDER BY last_used_at ASC, id ASC
            LIMIT ?
        """
        let stmt = try prepare(sql)
        try stmt.bindText(ClipboardItemType.image.rawValue, at: 1)
        try stmt.bindInt(limit, at: 2)

        var candidates: [DeleteCandidate] = []
        candidates.reserveCapacity(limit)

        while try stmt.step() {
            if let candidate = try parseDeleteCandidate(from: stmt) {
                candidates.append(candidate)
            }
        }

        return DeletePlan(candidates: candidates)
    }

    /// Commits only candidates whose cleanup-relevant snapshot is still current. Planning remains
    /// an advisory read for fast policy selection; pin/payload/recency revalidation, ref capture,
    /// and deletion share one write transaction so actor reentrancy cannot delete a newer row.
    func commitDeletePlan(_ plan: DeletePlan) throws -> DeleteCommitResult {
        guard !plan.candidates.isEmpty else {
            return DeleteCommitResult(plannedCount: 0, deletedItemIDs: [], storageRefs: [])
        }

        var deletedItemIDs: [UUID] = []
        var deletedStorageRefs: [String] = []
        try performWriteTransaction {
            let batchSize = 900
            for batchStart in stride(from: 0, to: plan.candidates.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, plan.candidates.count)
                let batch = Array(plan.candidates[batchStart..<batchEnd])
                let currentCandidates = try fetchCurrentDeleteCandidates(ids: batch.map(\.id))
                let plannedByID = Dictionary(
                    uniqueKeysWithValues: batch.map { ($0.id, $0) }
                )
                let committed = currentCandidates.filter { current in
                    guard let planned = plannedByID[current.id] else { return false }
                    return Self.hasSameCleanupSnapshot(current, as: planned)
                }
                guard !committed.isEmpty else { continue }

                try deleteItemsBatch(ids: committed.map(\.id))
                deletedItemIDs.append(contentsOf: committed.map(\.id))
                deletedStorageRefs.append(contentsOf: committed.compactMap(\.storageRef))
            }
            return deletedItemIDs.isEmpty ? nil : .deleted(deletedItemIDs)
        }

        return DeleteCommitResult(
            plannedCount: plan.candidates.count,
            deletedItemIDs: deletedItemIDs,
            storageRefs: deletedStorageRefs
        )
    }

    func walCheckpointTruncate() {
        connection?.walCheckpointTruncate()
    }

    func releaseMemory() {
        connection?.releaseMemory()
    }

    // MARK: - Internals

    private static func openFlags(for path: String) -> Int32 {
        var flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        if path.hasPrefix("file:") {
            flags |= SQLITE_OPEN_URI
        }
        return flags
    }

    private func advanceCommitPosition() throws -> (mutationSeq: Int64, totalCount: Int) {
        let stmt = try prepare("UPDATE scopy_meta SET mutation_seq = mutation_seq + 1 WHERE id = 1 RETURNING mutation_seq, item_count")
        guard try stmt.step() else {
            throw RepositoryError.queryFailed("scopy_meta row is missing")
        }
        let position = (mutationSeq: stmt.columnInt64(0), totalCount: stmt.columnInt(1))
        _ = try stmt.step()
        return position
    }

    /// Commits `body` and records the change it reports in the commit journal, together with the
    /// commit's `mutation_seq`, before any other repository work can run.
    /// A nil fact advances no sequence. Command acknowledgements, including an empty clear,
    /// still return a fact even when no item row changed. The result is always read in this
    /// transaction, including no-op commands that must return an authoritative snapshot position.
    @discardableResult
    private func performWriteTransaction(
        _ body: () throws -> StorageCommittedChange?
    ) throws -> Int64 {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            guard let change = try body() else {
                let mutationSeq: Int64
                do {
                    let position = try prepare("SELECT mutation_seq FROM scopy_meta WHERE id = 1")
                    guard try position.step() else {
                        throw RepositoryError.queryFailed("scopy_meta row is missing")
                    }
                    mutationSeq = position.columnInt64(0)
                }
                try execute("COMMIT")
                return mutationSeq
            }
            let position = try advanceCommitPosition()
            try execute("COMMIT")
            commitJournal.append(
                mutationSeq: position.mutationSeq,
                totalCount: position.totalCount,
                change: change
            )
            return position.mutationSeq
        } catch {
            do {
                try execute("ROLLBACK")
            } catch {
                try recoverDatabase()
            }
            throw error
        }
    }

    private func performMaintenanceWriteTransaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            do {
                try execute("ROLLBACK")
            } catch {
                try recoverDatabase()
            }
            throw error
        }
    }

    private func insertItemRow(
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
        let stmt = try prepare(
            """
            INSERT INTO clipboard_items
            (id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at, use_count, is_pinned, size_bytes, storage_ref, raw_data, file_size_bytes)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, 0, ?, ?, ?, ?)
            """
        )
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

    private func fetchIngestReceiptItemID(_ ingestID: UUID) throws -> UUID? {
        let stmt = try prepare("SELECT item_id FROM ingest_receipts WHERE ingest_id = ? LIMIT 1")
        try stmt.bindText(ingestID.uuidString, at: 1)
        guard try stmt.step() else { return nil }
        guard let rawID = stmt.columnText(0), let itemID = UUID(uuidString: rawID) else {
            throw RepositoryError.queryFailed("Invalid item id in ingest receipt")
        }
        return itemID
    }

    private func insertIngestReceipt(ingestID: UUID, itemID: UUID, committedAt: Date) throws {
        let stmt = try prepare(
            "INSERT INTO ingest_receipts (ingest_id, item_id, committed_at) VALUES (?, ?, ?)"
        )
        try stmt.bindText(ingestID.uuidString, at: 1)
        try stmt.bindText(itemID.uuidString, at: 2)
        try stmt.bindDouble(committedAt.timeIntervalSince1970, at: 3)
        _ = try stmt.step()
    }

    private func incrementUsageRow(_ id: UUID, lastUsedAt: Date) throws -> ClipboardStoredItem {
        let stmt = try prepare(
            """
            UPDATE clipboard_items
            SET last_used_at = MAX(last_used_at, ?), use_count = use_count + 1
            WHERE id = ?
            """
        )
        try stmt.bindDouble(lastUsedAt.timeIntervalSince1970, at: 1)
        try stmt.bindText(id.uuidString, at: 2)
        _ = try stmt.step()
        guard let updated = try fetchItemByID(id) else {
            throw RepositoryError.queryFailed("Ingest dedup row disappeared inside write transaction")
        }
        return updated
    }

    private func updateMetadataAndReturnCurrent(
        id: UUID,
        update: MetadataUpdate
    ) throws -> ClipboardStoredItem? {
        var updatedItem: ClipboardStoredItem?
        try performWriteTransaction {
            guard let current = try fetchItemByID(id) else { return nil }

            let kind: HistoryItemChangeKind
            switch update {
            case .note(let note):
                guard current.note != note else {
                    updatedItem = current
                    return nil
                }
                kind = .content
                do {
                    let stmt = try prepare("UPDATE clipboard_items SET note = ? WHERE id = ?")
                    try stmt.bindText(note, at: 1)
                    try stmt.bindText(id.uuidString, at: 2)
                    _ = try stmt.step()
                }
            case .fileSizeBytes(let expected, let fileSizeBytes):
                guard Self.hasSameFileReference(current, as: expected) else { return nil }
                guard current.fileSizeBytes != fileSizeBytes else { return nil }
                kind = .metadata
                do {
                    let stmt = try prepare("UPDATE clipboard_items SET file_size_bytes = ? WHERE id = ?")
                    if let fileSizeBytes {
                        try stmt.bindInt(fileSizeBytes, at: 1)
                    } else {
                        try stmt.bindNull(1)
                    }
                    try stmt.bindText(id.uuidString, at: 2)
                    _ = try stmt.step()
                }
            }

            updatedItem = try fetchItemByID(id)
            return updatedItem.map { .upserted($0, kind: kind) }
        }
        return updatedItem
    }

    /// File-size work reads the referenced paths, not serialized payload bytes omitted by summaries.
    private static func hasSameFileReference(
        _ lhs: ClipboardStoredItem,
        as rhs: ClipboardStoredItem
    ) -> Bool {
        lhs.id == rhs.id &&
            lhs.type == rhs.type &&
            lhs.contentHash == rhs.contentHash &&
            lhs.plainText == rhs.plainText &&
            lhs.sizeBytes == rhs.sizeBytes &&
            lhs.fileSizeBytes == rhs.fileSizeBytes &&
            lhs.storageRef == rhs.storageRef
    }

    private static func hasSamePayload(
        _ lhs: ClipboardStoredItem,
        as rhs: ClipboardStoredItem
    ) -> Bool {
        lhs.id == rhs.id &&
            lhs.type == rhs.type &&
            lhs.contentHash == rhs.contentHash &&
            lhs.plainText == rhs.plainText &&
            lhs.sizeBytes == rhs.sizeBytes &&
            lhs.fileSizeBytes == rhs.fileSizeBytes &&
            lhs.storageRef == rhs.storageRef &&
            lhs.rawData == rhs.rawData
    }

    private static func hasSameCleanupSnapshot(
        _ lhs: DeleteCandidate,
        as rhs: DeleteCandidate
    ) -> Bool {
        lhs.id == rhs.id &&
            lhs.type == rhs.type &&
            lhs.contentHash == rhs.contentHash &&
            lhs.lastUsedAt == rhs.lastUsedAt &&
            lhs.sizeBytes == rhs.sizeBytes &&
            lhs.storageRef == rhs.storageRef
    }

    /// Expected columns: id, type, content_hash, last_used_at, size_bytes, storage_ref.
    private func parseDeleteCandidate(from stmt: SQLiteStatement) throws -> DeleteCandidate? {
        guard let idString = stmt.columnText(0),
              let id = UUID(uuidString: idString),
              let typeString = stmt.columnText(1),
              let type = ClipboardItemType(rawValue: typeString),
              let contentHash = stmt.columnText(2) else {
            return nil
        }
        return DeleteCandidate(
            id: id,
            type: type,
            contentHash: contentHash,
            lastUsedAt: Date(timeIntervalSince1970: stmt.columnDouble(3)),
            sizeBytes: stmt.columnInt(4),
            storageRef: stmt.columnText(5)
        )
    }

    /// The explicit pin predicate is part of the commit-time read. Because this executes after
    /// BEGIN IMMEDIATE, no writer can change a matched row before the following batch delete.
    private func fetchCurrentDeleteCandidates(ids: [UUID]) throws -> [DeleteCandidate] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let stmt = try prepare(
            """
            SELECT id, type, content_hash, last_used_at, size_bytes, storage_ref
            FROM clipboard_items
            WHERE is_pinned = 0 AND id IN (\(placeholders))
            """
        )
        for (index, id) in ids.enumerated() {
            try stmt.bindText(id.uuidString, at: Int32(index + 1))
        }

        var candidates: [DeleteCandidate] = []
        candidates.reserveCapacity(ids.count)
        while try stmt.step() {
            if let candidate = try parseDeleteCandidate(from: stmt) {
                candidates.append(candidate)
            }
        }
        return candidates
    }

    // SQLite failures propagate as `SQLiteConnectionError`, which carries the extended result code.
    private func execute(_ sql: String) throws {
        guard let connection else { throw RepositoryError.databaseNotOpen }
        try connection.execute(sql)
    }

    private func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let connection else { throw RepositoryError.databaseNotOpen }
        return try connection.prepare(sql)
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
    }
}
