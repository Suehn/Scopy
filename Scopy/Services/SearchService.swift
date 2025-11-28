import Foundation
import SQLite3

/// SearchService - 高性能搜索服务
/// 符合 v0.md 第4节：超高性能搜索 + 渐进式结果返回
@MainActor
final class SearchService {
    // MARK: - Types

    enum SearchError: Error, LocalizedError {
        case databaseNotOpen
        case invalidQuery(String)
        case searchFailed(String)

        var errorDescription: String? {
            switch self {
            case .databaseNotOpen: return "Database is not open"
            case .invalidQuery(let msg): return "Invalid query: \(msg)"
            case .searchFailed(let msg): return "Search failed: \(msg)"
            }
        }
    }

    struct SearchResult {
        let items: [StorageService.StoredItem]
        let total: Int
        let hasMore: Bool
        let searchTimeMs: Double
    }

    // MARK: - Properties

    private let storage: StorageService
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.scopy.search", qos: .userInitiated)

    /// Cache for short queries (v0.md 4.2: 短词优化)
    private var recentItemsCache: [StorageService.StoredItem] = []
    private var cacheTimestamp: Date = .distantPast
    private let cacheDuration: TimeInterval = 5.0 // 5 seconds
    private let shortQueryCacheSize = 500

    /// 防止并发缓存刷新的标志
    private var cacheRefreshInProgress = false

    /// v0.10.7: 保护缓存刷新的锁（防止并发刷新竞态）
    private let cacheRefreshLock = NSLock()

    // MARK: - Initialization

    init(storage: StorageService) {
        self.storage = storage
    }

    func setDatabase(_ db: OpaquePointer?) {
        self.db = db
    }

    // MARK: - Search API

    /// Main search entry point (v0.md 3.3)
    func search(request: SearchRequest) async throws -> SearchResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        let result: SearchResult
        switch request.mode {
        case .exact:
            result = try await searchExact(request: request)
        case .fuzzy:
            result = try await searchFuzzy(request: request)
        case .regex:
            result = try await searchRegex(request: request)
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        return SearchResult(
            items: result.items,
            total: result.total,
            hasMore: result.hasMore,
            searchTimeMs: elapsed
        )
    }

    // MARK: - Search Modes

    /// Exact search using FTS5 (v0.md 3.3)
    private func searchExact(request: SearchRequest) async throws -> SearchResult {
        guard let db = db else { throw SearchError.databaseNotOpen }

        // Empty query returns all items (via cache or storage)
        if request.query.isEmpty {
            return try await searchAllWithFilters(request: request, db: db)
        }

        // For short queries, use in-memory cache
        if request.query.count <= 2 {
            return try await searchInCache(request: request) { item in
                item.plainText.localizedCaseInsensitiveContains(request.query)
            }
        }

        // Use FTS5 for longer queries
        let query = escapeFTSQuery(request.query)
        return try await searchWithFTS(db: db, query: query, request: request)
    }

    /// Fuzzy search (v0.md 3.3)
    private func searchFuzzy(request: SearchRequest) async throws -> SearchResult {
        guard let db = db else { throw SearchError.databaseNotOpen }

        // Empty query returns all items
        if request.query.isEmpty {
            return try await searchAllWithFilters(request: request, db: db)
        }

        // For short queries (<=4 chars), use in-memory cache with fuzzy matching
        // This ensures fuzzy patterns like "hlo" -> "Hello" work correctly
        if request.query.count <= 4 {
            return try await searchInCache(request: request) { item in
                self.fuzzyMatch(text: item.plainText, query: request.query)
            }
        }

        // FTS5 with prefix matching for longer fuzzy search
        let words = request.query.split(separator: " ").map { String($0) }
        let ftsQuery = words.map { "\($0)*" }.joined(separator: " ")
        return try await searchWithFTS(db: db, query: ftsQuery, request: request, useFuzzyRanking: true)
    }

    /// Regex search (v0.md 3.3: 限制仅对结果子集执行)
    private func searchRegex(request: SearchRequest) async throws -> SearchResult {
        // Regex is expensive - limit to cached recent items or smaller result set
        guard let regex = try? NSRegularExpression(pattern: request.query, options: [.caseInsensitive]) else {
            throw SearchError.invalidQuery("Invalid regex pattern")
        }

        return try await searchInCache(request: request) { item in
            let range = NSRange(item.plainText.startIndex..., in: item.plainText)
            return regex.firstMatch(in: item.plainText, range: range) != nil
        }
    }

    // MARK: - FTS5 Search Implementation

    private func searchWithFTS(
        db: OpaquePointer,
        query: String,
        request: SearchRequest,
        useFuzzyRanking: Bool = false
    ) async throws -> SearchResult {
        return try await runOnQueue { [self] in
            // Build SQL with filters
            var sql = """
                SELECT c.*, bm25(clipboard_fts) as rank
                FROM clipboard_items c
                JOIN clipboard_fts f ON c.rowid = f.rowid
                WHERE clipboard_fts MATCH ?
            """

            var params: [Any] = [query]

            // Apply filters (v0.md 3.3)
            if let appFilter = request.appFilter {
                sql += " AND c.app_bundle_id = ?"
                params.append(appFilter)
            }

            if let typeFilter = request.typeFilter {
                sql += " AND c.type = ?"
                params.append(typeFilter.rawValue)
            }

            // Order by relevance and recency (v0.md 4.3)
            if useFuzzyRanking {
                sql += " ORDER BY rank, c.last_used_at DESC"
            } else {
                sql += " ORDER BY rank"
            }

            // Get total count first
            let countSQL = "SELECT COUNT(*) FROM (\(sql))"
            var countStmt: OpaquePointer?
            var total = 0

            if sqlite3_prepare_v2(db, countSQL, -1, &countStmt, nil) == SQLITE_OK {
                self.bindParams(stmt: countStmt!, params: params)
                if sqlite3_step(countStmt) == SQLITE_ROW {
                    total = Int(sqlite3_column_int(countStmt, 0))
                }
                sqlite3_finalize(countStmt)
            }

            // Apply pagination
            sql += " LIMIT ? OFFSET ?"
            params.append(request.limit)
            params.append(request.offset)

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SearchError.searchFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            self.bindParams(stmt: stmt!, params: params)

            var items: [StorageService.StoredItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let item = self.parseItem(from: stmt!) {
                    items.append(item)
                }
            }

            return SearchResult(
                items: items,
                total: total,
                hasMore: request.offset + items.count < total,
                searchTimeMs: 0 // Will be updated by caller
            )
        }
    }

    // MARK: - In-Memory Cache Search (for short queries)

    private func searchInCache(
        request: SearchRequest,
        filter: @escaping (StorageService.StoredItem) -> Bool
    ) async throws -> SearchResult {
        return try await runOnQueue { [self] in
            // Refresh cache if stale
            try self.refreshCacheIfNeeded()

            // Apply all filters
            var filtered = recentItemsCache.filter(filter)

            // Apply additional filters
            if let appFilter = request.appFilter {
                filtered = filtered.filter { $0.appBundleID == appFilter }
            }
            if let typeFilter = request.typeFilter {
                filtered = filtered.filter { $0.type == typeFilter }
            }

            let total = filtered.count
            let start = min(request.offset, total)
            let end = min(request.offset + request.limit, total)
            let items = Array(filtered[start..<end])

            return SearchResult(
                items: items,
                total: total,
                hasMore: end < total,
                searchTimeMs: 0
            )
        }
    }

    /// v0.10.7: 使用锁保护缓存刷新，确保原子性检查
    private func refreshCacheIfNeeded() throws {
        let now = Date()

        // 先检查是否需要刷新（不需要则直接返回）
        let needsRefresh = recentItemsCache.isEmpty || now.timeIntervalSince(cacheTimestamp) > cacheDuration
        guard needsRefresh else { return }

        // 加锁保护并发检查和刷新
        cacheRefreshLock.lock()
        defer { cacheRefreshLock.unlock() }

        // 再次检查（double-check pattern）
        guard !cacheRefreshInProgress else { return }
        let stillNeedsRefresh = recentItemsCache.isEmpty || now.timeIntervalSince(cacheTimestamp) > cacheDuration
        guard stillNeedsRefresh else { return }

        // 设置刷新标志
        cacheRefreshInProgress = true
        defer { cacheRefreshInProgress = false }

        // 执行刷新
        recentItemsCache = try storage.fetchRecent(limit: shortQueryCacheSize, offset: 0)
        cacheTimestamp = now
    }

    func invalidateCache() {
        recentItemsCache = []
        cacheTimestamp = .distantPast
    }

    // MARK: - Fuzzy Matching

    private func fuzzyMatch(text: String, query: String) -> Bool {
        let lowerText = text.lowercased()
        let lowerQuery = query.lowercased()

        // Simple fuzzy: all characters must appear in order
        var textIndex = lowerText.startIndex
        for char in lowerQuery {
            guard let foundIndex = lowerText[textIndex...].firstIndex(of: char) else {
                return false
            }
            textIndex = lowerText.index(after: foundIndex)
        }
        return true
    }

    // MARK: - Query Utilities

    private func escapeFTSQuery(_ query: String) -> String {
        // Escape special FTS5 characters
        var escaped = query
            .replacingOccurrences(of: "\"", with: "\"\"")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "-", with: " ")

        // Quote the whole thing for exact phrase matching
        escaped = "\"\(escaped)\""
        return escaped
    }

    private func bindParams(stmt: OpaquePointer, params: [Any]) {
        for (index, param) in params.enumerated() {
            let i = Int32(index + 1)
            switch param {
            case let s as String:
                sqlite3_bind_text(stmt, i, s, -1, SQLITE_TRANSIENT)
            case let n as Int:
                sqlite3_bind_int(stmt, i, Int32(n))
            case let d as Double:
                sqlite3_bind_double(stmt, i, d)
            default:
                sqlite3_bind_null(stmt, i)
            }
        }
    }

    private func parseItem(from stmt: OpaquePointer) -> StorageService.StoredItem? {
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

        // Read inline raw_data (column 11) - SearchService also needs access for file type items
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

    // MARK: - Helpers

    private func runOnQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let value = try work()
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 空查询 + 过滤时直接访问 SQLite，避免缓存截断历史
    private func searchAllWithFilters(request: SearchRequest, db: OpaquePointer) async throws -> SearchResult {
        try await runOnQueue { [self] in
            var sql = """
                SELECT * FROM clipboard_items
                WHERE 1 = 1
            """
            var params: [Any] = []

            if let appFilter = request.appFilter {
                sql += " AND app_bundle_id = ?"
                params.append(appFilter)
            }
            if let typeFilter = request.typeFilter {
                sql += " AND type = ?"
                params.append(typeFilter.rawValue)
            }

            sql += " ORDER BY is_pinned DESC, last_used_at DESC"

            let countSQL = "SELECT COUNT(*) FROM (\(sql))"
            var total = 0
            var countStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, countSQL, -1, &countStmt, nil) == SQLITE_OK {
                self.bindParams(stmt: countStmt!, params: params)
                if sqlite3_step(countStmt) == SQLITE_ROW {
                    total = Int(sqlite3_column_int(countStmt, 0))
                }
                sqlite3_finalize(countStmt)
            }

            sql += " LIMIT ? OFFSET ?"
            params.append(request.limit)
            params.append(request.offset)

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SearchError.searchFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            self.bindParams(stmt: stmt!, params: params)

            var items: [StorageService.StoredItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let item = self.parseItem(from: stmt!) {
                    items.append(item)
                }
            }

            return SearchResult(
                items: items,
                total: total,
                hasMore: request.offset + items.count < total,
                searchTimeMs: 0
            )
        }
    }
}

// MARK: - SQLITE_TRANSIENT helper

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
