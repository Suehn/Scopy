import Foundation
import SQLite3

/// v0.19: 共享的 SQLite 工具，消除代码重复
/// 包含 SQLITE_TRANSIENT 常量和 StoredItem 解析逻辑

// MARK: - SQLite Constants

/// SQLite TRANSIENT 常量，表示 SQLite 应该复制绑定的数据
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - StoredItem Parsing

/// v0.22: 安全地从 SQLite 列获取字符串，显式检查 NULL 指针
/// sqlite3_column_text 可能返回 NULL，直接传给 String(cString:) 会崩溃
private func safeColumnText(_ stmt: OpaquePointer, _ column: Int32) -> String? {
    guard let ptr = sqlite3_column_text(stmt, column) else { return nil }
    return String(cString: ptr)
}

/// 从 SQLite statement 解析 StoredItem
/// 用于 StorageService 和 SearchService 共享
/// v0.22: 使用 safeColumnText 防止 NULL 指针崩溃
func parseStoredItem(from stmt: OpaquePointer) -> StorageService.StoredItem? {
    guard let idStr = safeColumnText(stmt, 0),
          let id = UUID(uuidString: idStr),
          let typeStr = safeColumnText(stmt, 1),
          let type = ClipboardItemType(rawValue: typeStr),
          let hashStr = safeColumnText(stmt, 2) else {
        return nil
    }

    let plainText = safeColumnText(stmt, 3) ?? ""
    let appBundleID = safeColumnText(stmt, 4)
    let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
    let lastUsedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
    let useCount = Int(sqlite3_column_int(stmt, 7))
    let isPinned = sqlite3_column_int(stmt, 8) != 0
    let sizeBytes = Int(sqlite3_column_int(stmt, 9))
    let storageRef = safeColumnText(stmt, 10)

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

/// 从 SQLite statement 解析 StoredItem（不读取 raw_data）
/// 用于全量模糊搜索索引与列表查询，避免读取大字段
func parseStoredItemSummary(from stmt: OpaquePointer) -> StorageService.StoredItem? {
    guard let idStr = safeColumnText(stmt, 0),
          let id = UUID(uuidString: idStr),
          let typeStr = safeColumnText(stmt, 1),
          let type = ClipboardItemType(rawValue: typeStr),
          let hashStr = safeColumnText(stmt, 2) else {
        return nil
    }

    let plainText = safeColumnText(stmt, 3) ?? ""
    let appBundleID = safeColumnText(stmt, 4)
    let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
    let lastUsedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
    let useCount = Int(sqlite3_column_int(stmt, 7))
    let isPinned = sqlite3_column_int(stmt, 8) != 0
    let sizeBytes = Int(sqlite3_column_int(stmt, 9))
    let storageRef = safeColumnText(stmt, 10)

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
        rawData: nil
    )
}
