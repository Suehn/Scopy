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
        case timeout  // v0.10.8: 搜索超时

        var errorDescription: String? {
            switch self {
            case .databaseNotOpen: return "Database is not open"
            case .invalidQuery(let msg): return "Invalid query: \(msg)"
            case .searchFailed(let msg): return "Search failed: \(msg)"
            case .timeout: return "Search timed out"
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
    /// v0.13: 扩展缓存策略 - 增加缓存大小和 TTL，提高命中率
    private var recentItemsCache: [StorageService.StoredItem] = []
    private var cacheTimestamp: Date = .distantPast
    private let cacheDuration: TimeInterval = 30.0 // v0.13: 30 seconds (原 5 秒)
    private let shortQueryCacheSize = 2000 // v0.13: 2000 条 (原 500 条)

    /// 防止并发缓存刷新的标志
    private var cacheRefreshInProgress = false

    /// v0.10.7: 保护缓存刷新的锁（防止并发刷新竞态）
    private let cacheRefreshLock = NSLock()

    /// v0.10.8: FTS5 COUNT 缓存（避免重复计算总数）
    private var cachedSearchTotal: (query: String, mode: SearchMode, appFilter: String?, typeFilter: ClipboardItemType?, total: Int, timestamp: Date)?
    private let searchTotalCacheTTL: TimeInterval = 5.0  // 5秒有效期

    /// v0.10.8: 搜索超时时间
    private let searchTimeout: TimeInterval = 5.0

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
    /// v0.17: 确保所有模糊搜索都不区分大小写
    private func searchFuzzy(request: SearchRequest) async throws -> SearchResult {
        guard let db = db else { throw SearchError.databaseNotOpen }

        // Empty query returns all items
        if request.query.isEmpty {
            return try await searchAllWithFilters(request: request, db: db)
        }

        // For short queries (<=4 chars), use in-memory cache with fuzzy matching
        // This ensures fuzzy patterns like "hlo" -> "Hello" work correctly
        // fuzzyMatch 内部已使用 lowercased()，无需额外处理
        if request.query.count <= 4 {
            return try await searchInCache(request: request) { item in
                self.fuzzyMatch(text: item.plainText, query: request.query)
            }
        }

        // v0.17: FTS5 with prefix matching for longer fuzzy search
        // 将查询转为小写，确保与 FTS5 unicode61 tokenizer 的 case-folding 一致
        let words = request.query.lowercased().split(separator: " ").map { String($0) }
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

    /// v0.13: 使用两步查询优化 FTS5 性能
    /// Step 1: 从 FTS5 获取 rowid 列表（避免 JOIN 开销）
    /// Step 2: 批量获取主表数据
    /// 同时使用 LIMIT+1 技巧消除 COUNT 查询
    private func searchWithFTS(
        db: OpaquePointer,
        query: String,
        request: SearchRequest,
        useFuzzyRanking: Bool = false
    ) async throws -> SearchResult {
        let result = try await runOnQueueWithTimeout { [self] in
            // v0.13: Step 1 - 从 FTS5 获取 rowid 列表（高效，避免 JOIN）
            let ftsSQL = """
                SELECT rowid FROM clipboard_fts
                WHERE clipboard_fts MATCH ?
                ORDER BY bm25(clipboard_fts)
                LIMIT ? OFFSET ?
            """

            var ftsStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, ftsSQL, -1, &ftsStmt, nil) == SQLITE_OK else {
                throw SearchError.searchFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(ftsStmt) }

            sqlite3_bind_text(ftsStmt, 1, query, -1, SQLITE_TRANSIENT)
            // v0.13: LIMIT+1 技巧 - 多取一条判断 hasMore
            sqlite3_bind_int(ftsStmt, 2, Int32(request.limit + 1))
            sqlite3_bind_int(ftsStmt, 3, Int32(request.offset))

            // 收集 rowid
            var rowids: [Int64] = []
            rowids.reserveCapacity(request.limit + 1)

            while sqlite3_step(ftsStmt) == SQLITE_ROW {
                let rowid = sqlite3_column_int64(ftsStmt, 0)
                rowids.append(rowid)
            }

            // 判断 hasMore
            let hasMore = rowids.count > request.limit
            if hasMore {
                rowids.removeLast()
            }

            // 如果没有结果，直接返回
            if rowids.isEmpty {
                return SearchResult(items: [], total: 0, hasMore: false, searchTimeMs: 0)
            }

            // v0.13: Step 2 - 批量获取主表数据
            let placeholders = rowids.map { _ in "?" }.joined(separator: ",")
            var mainSQL = """
                SELECT * FROM clipboard_items
                WHERE rowid IN (\(placeholders))
            """

            // Apply filters (v0.md 3.3)
            var filterParams: [Any] = []
            if let appFilter = request.appFilter {
                mainSQL += " AND app_bundle_id = ?"
                filterParams.append(appFilter)
            }
            if let typeFilter = request.typeFilter {
                mainSQL += " AND type = ?"
                filterParams.append(typeFilter.rawValue)
            }

            // 保持 FTS5 返回的排序顺序，并确保 pinned 置顶
            let orderCases = rowids.enumerated().map { "WHEN rowid = \($0.element) THEN \($0.offset)" }.joined(separator: " ")
            mainSQL += " ORDER BY is_pinned DESC, CASE \(orderCases) END"

            var mainStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, mainSQL, -1, &mainStmt, nil) == SQLITE_OK else {
                throw SearchError.searchFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(mainStmt) }

            // 绑定 rowid 参数
            for (index, rowid) in rowids.enumerated() {
                sqlite3_bind_int64(mainStmt, Int32(index + 1), rowid)
            }
            // 绑定过滤参数
            for (index, param) in filterParams.enumerated() {
                let paramIndex = Int32(rowids.count + index + 1)
                if let s = param as? String {
                    sqlite3_bind_text(mainStmt, paramIndex, s, -1, SQLITE_TRANSIENT)
                }
            }

            // 收集结果
            var items: [StorageService.StoredItem] = []
            items.reserveCapacity(rowids.count)

            while sqlite3_step(mainStmt) == SQLITE_ROW {
                guard let stmt = mainStmt else { break }
                if let item = self.parseItem(from: stmt) {
                    items.append(item)
                }
            }

            // v0.13: total 设为 -1 表示未知（UI 层处理显示 "50+ 条"）
            let total = hasMore ? -1 : request.offset + items.count

            return SearchResult(
                items: items,
                total: total,
                hasMore: hasMore,
                searchTimeMs: 0
            )
        }

        return result
    }

    // MARK: - In-Memory Cache Search (for short queries)

    /// v0.13: 优化缓存搜索，使用 LIMIT+1 逻辑保持一致性
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
            // 统一排序：Pinned 置顶，其次时间
            filtered.sort {
                if $0.isPinned != $1.isPinned {
                    return $0.isPinned && !$1.isPinned
                }
                return $0.lastUsedAt > $1.lastUsedAt
            }

            let totalFiltered = filtered.count
            let start = min(request.offset, totalFiltered)
            // v0.13: 多取一条判断 hasMore
            let end = min(request.offset + request.limit + 1, totalFiltered)

            var items = Array(filtered[start..<end])

            // v0.13: 判断 hasMore 并移除多取的那条
            let hasMore = items.count > request.limit
            if hasMore {
                items = Array(items.prefix(request.limit))
            }

            // v0.13: total 设为 -1 表示未知（与 FTS 搜索保持一致）
            let total = hasMore ? -1 : request.offset + items.count

            return SearchResult(
                items: items,
                total: total,
                hasMore: hasMore,
                searchTimeMs: 0
            )
        }
    }

    /// v0.12: 修复竞态条件 - 所有检查都在锁内进行
    /// v0.17.1: 使用 withLock 统一锁策略
    private func refreshCacheIfNeeded() throws {
        try cacheRefreshLock.withLock {
            // 所有检查都在锁内进行，确保原子性
            let now = Date()
            let needsRefresh = recentItemsCache.isEmpty || now.timeIntervalSince(cacheTimestamp) > cacheDuration
            guard needsRefresh && !cacheRefreshInProgress else { return }

            // 设置刷新标志
            cacheRefreshInProgress = true
            defer { cacheRefreshInProgress = false }

            // 执行刷新
            recentItemsCache = try storage.fetchRecent(limit: shortQueryCacheSize, offset: 0)
            cacheTimestamp = now
        }
    }

    /// v0.12: 完整缓存失效，同时清除搜索总数缓存
    func invalidateCache() {
        recentItemsCache = []
        cacheTimestamp = .distantPast
        cachedSearchTotal = nil
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

    /// v0.12: 带超时的队列执行，使用结构化并发避免任务泄漏
    private func runOnQueueWithTimeout<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            // 实际工作任务
            group.addTask { [self] in
                try await self.runOnQueue(work)
            }
            // 超时任务
            group.addTask { [searchTimeout] in
                try await Task.sleep(nanoseconds: UInt64(searchTimeout * 1_000_000_000))
                throw SearchError.timeout
            }

            do {
                guard let value = try await group.next() else {
                    group.cancelAll()
                    throw SearchError.timeout
                }
                group.cancelAll()
                return value
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    /// v0.10.8: 获取缓存的搜索总数
    private func getCachedTotal(for request: SearchRequest, query: String) -> Int? {
        guard let cached = cachedSearchTotal,
              cached.query == query,
              cached.mode == request.mode,
              cached.appFilter == request.appFilter,
              cached.typeFilter == request.typeFilter,
              Date().timeIntervalSince(cached.timestamp) < searchTotalCacheTTL else {
            return nil
        }
        return cached.total
    }

    /// v0.10.8: 缓存搜索总数
    private func cacheTotal(_ total: Int, for request: SearchRequest, query: String) {
        cachedSearchTotal = (query, request.mode, request.appFilter, request.typeFilter, total, Date())
    }

    /// v0.13: 空查询 + 过滤时直接访问 SQLite，使用 LIMIT+1 技巧
    private func searchAllWithFilters(request: SearchRequest, db: OpaquePointer) async throws -> SearchResult {
        let result = try await runOnQueueWithTimeout { [self] in
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

            // v0.13: LIMIT+1 技巧 - 多取一条判断 hasMore，避免 O(n) COUNT 查询
            sql += " LIMIT ? OFFSET ?"
            params.append(request.limit + 1)  // 多取一条
            params.append(request.offset)

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SearchError.searchFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            self.bindParams(stmt: stmt!, params: params)

            // v0.13: 预分配数组容量
            var items: [StorageService.StoredItem] = []
            items.reserveCapacity(request.limit + 1)

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let stmt = stmt else { break }
                if let item = self.parseItem(from: stmt) {
                    items.append(item)
                }
            }

            // v0.13: 判断 hasMore 并移除多取的那条
            let hasMore = items.count > request.limit
            if hasMore {
                items.removeLast()
            }

            // v0.13: total 设为 -1 表示未知
            let total = hasMore ? -1 : request.offset + items.count

            return SearchResult(
                items: items,
                total: total,
                hasMore: hasMore,
                searchTimeMs: 0
            )
        }

        return result
    }

    /// v0.11: 使缓存失效（数据变更时调用）
    func invalidateSearchTotalCache() {
        cachedSearchTotal = nil
    }
}

// MARK: - SQLITE_TRANSIENT helper

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
