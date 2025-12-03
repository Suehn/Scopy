import Foundation
import SQLite3

/// v0.19: 共享的 SQLite 工具，消除代码重复
/// 包含 SQLITE_TRANSIENT 常量和 StoredItem 解析逻辑

// MARK: - SQLite Constants

/// SQLite TRANSIENT 常量，表示 SQLite 应该复制绑定的数据
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - StoredItem Parsing

/// 从 SQLite statement 解析 StoredItem
/// 用于 StorageService 和 SearchService 共享
func parseStoredItem(from stmt: OpaquePointer) -> StorageService.StoredItem? {
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

    return StorageService.StoredItem(
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
