import Foundation

/// The `clipboard_items` column lists and row decoding shared by the repository's write
/// connection and the search engine's read connection, so both read one row shape.
enum ClipboardItemRow {
    enum DecodeError: Error {
        /// The row's id, type, or content hash is missing or malformed.
        case invalidRow
    }

    /// Every column except the payload blob, in the order `decodeSummary` reads them.
    static let summaryColumns =
        "id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at, "
        + "use_count, is_pinned, size_bytes, storage_ref, file_size_bytes"

    /// `summaryColumns` qualified with the table name for joins.
    static let qualifiedSummaryColumns = summaryColumns
        .split(separator: ",")
        .map { "clipboard_items." + $0.trimmingCharacters(in: .whitespaces) }
        .joined(separator: ", ")

    /// Every column including the payload blob, in the order `decodeFull` reads them.
    static let fullColumns =
        "id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at, "
        + "use_count, is_pinned, size_bytes, storage_ref, raw_data, file_size_bytes"

    static func decodeSummary(_ stmt: SQLiteStatement) throws -> ClipboardStoredItem {
        try decode(stmt, rawData: nil, fileSizeBytesColumn: 12)
    }

    static func decodeFull(_ stmt: SQLiteStatement) throws -> ClipboardStoredItem {
        try decode(stmt, rawData: stmt.columnBlobData(12), fileSizeBytesColumn: 13)
    }

    private static func decode(
        _ stmt: SQLiteStatement,
        rawData: Data?,
        fileSizeBytesColumn: Int32
    ) throws -> ClipboardStoredItem {
        guard let idString = stmt.columnText(0),
              let id = UUID(uuidString: idString),
              let typeString = stmt.columnText(1),
              let type = ClipboardItemType(rawValue: typeString),
              let contentHash = stmt.columnText(2) else {
            throw DecodeError.invalidRow
        }

        return ClipboardStoredItem(
            id: id,
            type: type,
            contentHash: contentHash,
            plainText: stmt.columnText(3) ?? "",
            note: stmt.columnText(4),
            appBundleID: stmt.columnText(5),
            createdAt: Date(timeIntervalSince1970: stmt.columnDouble(6)),
            lastUsedAt: Date(timeIntervalSince1970: stmt.columnDouble(7)),
            useCount: stmt.columnInt(8),
            isPinned: stmt.columnInt(9) != 0,
            sizeBytes: stmt.columnInt(10),
            fileSizeBytes: stmt.columnIntOptional(fileSizeBytesColumn),
            storageRef: stmt.columnText(11),
            rawData: rawData
        )
    }
}
