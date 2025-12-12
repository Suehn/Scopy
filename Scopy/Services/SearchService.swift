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

    private struct IndexedItem {
        let id: UUID
        let type: ClipboardItemType
        let contentHash: String
        let plainText: String
        let plainTextLower: String
        let plainTextLowerIsASCII: Bool
        let appBundleID: String?
        let createdAt: Date
        var lastUsedAt: Date
        var useCount: Int
        var isPinned: Bool
        let sizeBytes: Int
        let storageRef: String?

        init(from item: StorageService.StoredItem) {
            self.id = item.id
            self.type = item.type
            self.contentHash = item.contentHash
            self.plainText = item.plainText
            let lower = item.plainText.lowercased()
            self.plainTextLower = lower
            self.plainTextLowerIsASCII = lower.canBeConverted(to: .ascii)
            self.appBundleID = item.appBundleID
            self.createdAt = item.createdAt
            self.lastUsedAt = item.lastUsedAt
            self.useCount = item.useCount
            self.isPinned = item.isPinned
            self.sizeBytes = item.sizeBytes
            self.storageRef = item.storageRef
        }

        func toStoredItem() -> StorageService.StoredItem {
            StorageService.StoredItem(
                id: id,
                type: type,
                contentHash: contentHash,
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
    }

    private final class FullFuzzyIndex {
        var items: [IndexedItem?]
        var idToSlot: [UUID: Int]
        var charPostings: [Character: [Int]]

        init(items: [IndexedItem?], idToSlot: [UUID: Int], charPostings: [Character: [Int]]) {
            self.items = items
            self.idToSlot = idToSlot
            self.charPostings = charPostings
        }
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

    /// Full-history fuzzy index (v0.25: 全量模糊搜索)
    private var fullIndex: FullFuzzyIndex?
    private var fullIndexStale = true
    private let fullIndexLock = NSLock()

    // v0.22: 移除 cachedSearchTotal 和 searchTotalCacheTTL（死代码）
    // v0.13 引入 LIMIT+1 技巧后，不再需要单独缓存搜索总数

    /// v0.10.8: 搜索超时时间
    private let searchTimeout: TimeInterval = 5.0

    // MARK: - Initialization

    init(storage: StorageService) {
        self.storage = storage
    }

    func setDatabase(_ db: OpaquePointer?) {
        self.db = db
    }

    // MARK: - Index Updates

    /// 通知 SearchService 有新条目或条目更新（用于保持全量模糊索引最新）
    func handleUpsertedItem(_ item: StorageService.StoredItem) {
        // Short-query cache becomes stale
        cacheRefreshLock.withLock {
            recentItemsCache = []
            cacheTimestamp = .distantPast
        }

        fullIndexLock.withLock {
            guard let index = fullIndex, !fullIndexStale else { return }
            upsertItemIntoIndex(item, index: index)
        }
    }

    func handlePinnedChange(id: UUID, pinned: Bool) {
        fullIndexLock.withLock {
            guard let index = fullIndex, !fullIndexStale, let slot = index.idToSlot[id], let existing = index.items[slot] else {
                return
            }
            var updated = existing
            updated.isPinned = pinned
            index.items[slot] = updated
        }
    }

    func handleDeletion(id: UUID) {
        fullIndexLock.withLock {
            guard let index = fullIndex, !fullIndexStale, let slot = index.idToSlot[id] else { return }
            index.items[slot] = nil
            index.idToSlot.removeValue(forKey: id)
        }

        cacheRefreshLock.withLock {
            recentItemsCache = []
            cacheTimestamp = .distantPast
        }
    }

    func handleClearAll() {
        invalidateCache()
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
        case .fuzzyPlus:
            result = try await searchFuzzyPlus(request: request)
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
    /// v0.19: 所有模糊搜索都使用真正的模糊匹配（字符顺序匹配）
    /// v0.23: 移除强制解包，使用 guard let 确保安全
    private func searchFuzzy(request: SearchRequest) async throws -> SearchResult {
        guard let db = db else { throw SearchError.databaseNotOpen }

        // Empty query returns all items
        if request.query.isEmpty {
            return try await searchAllWithFilters(request: request, db: db)
        }

        return try await searchFullFuzzy(request: request, db: db, mode: .fuzzy)
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

    /// v0.19.1: Fuzzy+ 搜索 - 按空格分词，每个词独立模糊匹配
    /// 例如 "周五 匹配" 会匹配同时包含 "周五" 和 "匹配" 的文本
    /// v0.23: 移除强制解包，使用 guard let 确保安全
    private func searchFuzzyPlus(request: SearchRequest) async throws -> SearchResult {
        guard let db = db else { throw SearchError.databaseNotOpen }

        // Empty query returns all items
        if request.query.isEmpty {
            return try await searchAllWithFilters(request: request, db: db)
        }

        return try await searchFullFuzzy(request: request, db: db, mode: .fuzzyPlus)
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
            // v0.22: 支持 typeFilters 多类型过滤
            if let typeFilters = request.typeFilters, !typeFilters.isEmpty {
                let placeholders = typeFilters.map { _ in "?" }.joined(separator: ",")
                mainSQL += " AND type IN (\(placeholders))"
                for type in typeFilters {
                    filterParams.append(type.rawValue)
                }
            } else if let typeFilter = request.typeFilter {
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

            // Snapshot cache under lock to avoid concurrent mutation races
            let cachedItems = cacheRefreshLock.withLock { recentItemsCache }
            var filtered = cachedItems.filter(filter)

            // Apply additional filters
            if let appFilter = request.appFilter {
                filtered = filtered.filter { $0.appBundleID == appFilter }
            }
            // v0.22: 支持 typeFilters 多类型过滤
            if let typeFilters = request.typeFilters, !typeFilters.isEmpty {
                filtered = filtered.filter { typeFilters.contains($0.type) }
            } else if let typeFilter = request.typeFilter {
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
    /// v0.19: 修复内存问题 - 缓存时去除 rawData，避免 200MB 内存占用
    /// v0.22: 修复死锁风险 - 在锁外执行数据库查询，避免持锁调用 storage.fetchRecent()
    private func refreshCacheIfNeeded() throws {
        // Step 1: 在锁内检查是否需要刷新，并设置刷新标志
        let shouldRefresh = cacheRefreshLock.withLock { () -> Bool in
            let now = Date()
            let needsRefresh = recentItemsCache.isEmpty || now.timeIntervalSince(cacheTimestamp) > cacheDuration
            guard needsRefresh && !cacheRefreshInProgress else { return false }
            cacheRefreshInProgress = true
            return true
        }

        guard shouldRefresh else { return }

        // Step 2: 在锁外执行数据库查询（避免死锁）
        defer {
            cacheRefreshLock.withLock {
                cacheRefreshInProgress = false
            }
        }

        let items = try storage.fetchRecent(limit: shortQueryCacheSize, offset: 0)

        // Step 3: 在锁内更新缓存
        cacheRefreshLock.withLock {
            // v0.19: 去除 rawData，只保留搜索所需的元数据
            recentItemsCache = items.map { item in
                StorageService.StoredItem(
                    id: item.id,
                    type: item.type,
                    contentHash: item.contentHash,
                    plainText: item.plainText,
                    appBundleID: item.appBundleID,
                    createdAt: item.createdAt,
                    lastUsedAt: item.lastUsedAt,
                    useCount: item.useCount,
                    isPinned: item.isPinned,
                    sizeBytes: item.sizeBytes,
                    storageRef: item.storageRef,
                    rawData: nil  // 不缓存原始数据，节省内存
                )
            }
            cacheTimestamp = Date()
        }
    }

    /// v0.12: 完整缓存失效
    /// v0.22: 移除 cachedSearchTotal 清除（已删除该死代码）
    func invalidateCache() {
        cacheRefreshLock.withLock {
            recentItemsCache = []
            cacheTimestamp = .distantPast
        }

        fullIndexLock.withLock {
            fullIndex = nil
            fullIndexStale = true
        }
    }

    // MARK: - Full-History Fuzzy Search

    private func searchFullFuzzy(request: SearchRequest, db: OpaquePointer, mode: SearchMode) async throws -> SearchResult {
        let trimmedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return try await searchAllWithFilters(request: request, db: db)
        }

        let normalizedRequest = SearchRequest(
            query: trimmedQuery,
            mode: mode,
            appFilter: request.appFilter,
            typeFilter: request.typeFilter,
            typeFilters: request.typeFilters,
            limit: request.limit,
            offset: request.offset
        )

        return try await runOnQueueWithTimeout { [self] in
            try ensureFullIndex(db: db)
            return try fullIndexLock.withLock {
                guard let index = fullIndex, !fullIndexStale else {
                    return SearchResult(items: [], total: 0, hasMore: false, searchTimeMs: 0)
                }
                return try searchInFullIndex(index: index, request: normalizedRequest, mode: mode, db: db)
            }
        }
    }

    private func ensureFullIndex(db: OpaquePointer) throws {
        _ = try getOrBuildFullIndex(db: db)
    }

    private func getOrBuildFullIndex(db: OpaquePointer) throws -> FullFuzzyIndex {
        if let existing = fullIndexLock.withLock({ (!fullIndexStale) ? fullIndex : nil }) {
            return existing
        }

        let newIndex = try buildFullIndex(db: db)
        fullIndexLock.withLock {
            fullIndex = newIndex
            fullIndexStale = false
        }
        return newIndex
    }

    private func buildFullIndex(db: OpaquePointer) throws -> FullFuzzyIndex {
        let sql = """
            SELECT id, type, content_hash, plain_text, app_bundle_id, created_at, last_used_at,
                   use_count, is_pinned, size_bytes, storage_ref
            FROM clipboard_items
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SearchError.searchFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var items: [IndexedItem?] = []
        var idToSlot: [UUID: Int] = [:]
        var charPostings: [Character: [Int]] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let stmt = stmt, let stored = parseStoredItemSummary(from: stmt) else { continue }
            let indexed = IndexedItem(from: stored)
            let slot = items.count
            items.append(indexed)
            idToSlot[indexed.id] = slot

            for ch in uniqueNonWhitespaceCharacters(indexed.plainTextLower) {
                charPostings[ch, default: []].append(slot)
            }
        }

        return FullFuzzyIndex(items: items, idToSlot: idToSlot, charPostings: charPostings)
    }

    private func searchInFullIndex(index: FullFuzzyIndex, request: SearchRequest, mode: SearchMode, db: OpaquePointer) throws -> SearchResult {
        let queryLower = request.query.lowercased()
        let queryChars = uniqueNonWhitespaceCharacters(queryLower)

        var candidateSlots: [Int]
        if queryChars.isEmpty {
            candidateSlots = Array(index.items.indices)
        } else {
            var lists: [[Int]] = []
            lists.reserveCapacity(queryChars.count)
            for ch in queryChars {
                guard let list = index.charPostings[ch] else {
                    return SearchResult(items: [], total: 0, hasMore: false, searchTimeMs: 0)
                }
                lists.append(list)
            }
            lists.sort { $0.count < $1.count }

            var candidates = lists[0]
            for list in lists.dropFirst() {
                candidates = intersectSorted(candidates, list)
                if candidates.isEmpty { break }
            }
            candidateSlots = candidates
        }

        let queryLowerIsASCII = queryLower.canBeConverted(to: .ascii)
        let plusWords: [(word: String, isASCII: Bool)]
        if mode == .fuzzyPlus {
            plusWords = queryLower
                .split(separator: " ")
                .map(String.init)
                .filter { !$0.isEmpty }
                .map { (word: $0, isASCII: $0.canBeConverted(to: .ascii)) }
        } else {
            plusWords = []
        }

        // 可选 FTS 加速：仅用于大候选集的首屏（offset=0）ASCII 单词查询
        var totalIsUnknown = false
        if mode == .fuzzy,
           request.offset == 0,
           queryLower.count >= 3,
           queryLowerIsASCII,
           !queryLower.contains(" "),
           candidateSlots.count >= 20_000 {
            let desiredTopCount = max(0, request.offset + request.limit + 1)
            let prefilterLimit = min(20_000, max(5_000, desiredTopCount * 40))
            if let ftsSlots = try? ftsPrefilterSlots(db: db, index: index, queryLower: queryLower, limit: prefilterLimit),
               !ftsSlots.isEmpty {
                // 兜底：把候选里的 pinned 也并入，避免 pinned 漏召回
                let pinnedSlots = candidateSlots.filter { slot in
                    guard slot < index.items.count, let item = index.items[slot] else { return false }
                    return item.isPinned
                }
                var merged = Set(ftsSlots)
                for s in pinnedSlots { merged.insert(s) }
                candidateSlots = Array(merged)
                totalIsUnknown = true
            }
        }

        let desiredTopCount = max(0, request.offset + request.limit + 1)
        var topHeap = BinaryHeap<ScoredIndexedItem>(areSorted: isWorse)
        topHeap.reserveCapacity(desiredTopCount)
        var totalMatches = 0

        for slot in candidateSlots {
            guard slot < index.items.count, let item = index.items[slot] else { continue }

            if let appFilter = request.appFilter, item.appBundleID != appFilter { continue }
            if let typeFilters = request.typeFilters, !typeFilters.isEmpty {
                if !typeFilters.contains(item.type) { continue }
            } else if let typeFilter = request.typeFilter, item.type != typeFilter {
                continue
            }

            let score: Int?
            switch mode {
            case .fuzzy:
                score = fuzzyMatchScore(
                    textLower: item.plainTextLower,
                    textLowerIsASCII: item.plainTextLowerIsASCII,
                    queryLower: queryLower,
                    queryLowerIsASCII: queryLowerIsASCII
                )
            case .fuzzyPlus:
                var totalScore = 0
                var ok = true
                for wordInfo in plusWords {
                    guard let s = fuzzyMatchScore(
                        textLower: item.plainTextLower,
                        textLowerIsASCII: item.plainTextLowerIsASCII,
                        queryLower: wordInfo.word,
                        queryLowerIsASCII: wordInfo.isASCII
                    ) else {
                        ok = false
                        break
                    }
                    totalScore += s
                }
                score = ok ? totalScore : nil
            default:
                score = nil
            }

            guard let score else { continue }
            totalMatches += 1

            guard desiredTopCount > 0 else { continue }
            let scoredItem = ScoredIndexedItem(item: item, score: score)

            if topHeap.count < desiredTopCount {
                topHeap.insert(scoredItem)
            } else if let worst = topHeap.peek, isBetter(scoredItem, than: worst) {
                topHeap.replaceRoot(with: scoredItem)
            }
        }

        var topItems = topHeap.elements
        topItems.sort { isBetter($0, than: $1) }

        let start = min(request.offset, topItems.count)
        let end = min(start + request.limit, topItems.count)
        let page = (start < end) ? Array(topItems[start..<end]) : []

        let hasMore = totalIsUnknown ? (totalMatches >= request.limit) : (totalMatches > request.offset + request.limit)
        let resultItems = page.map { $0.item.toStoredItem() }
        let total = totalIsUnknown ? -1 : totalMatches
        return SearchResult(items: resultItems, total: total, hasMore: hasMore, searchTimeMs: 0)
    }

    private func ftsPrefilterSlots(
        db: OpaquePointer,
        index: FullFuzzyIndex,
        queryLower: String,
        limit: Int
    ) throws -> [Int] {
        let ftsQuery = escapeFTSQuery(queryLower)
        let sql = """
            SELECT clipboard_items.id
            FROM clipboard_fts
            JOIN clipboard_items ON clipboard_items.rowid = clipboard_fts.rowid
            WHERE clipboard_fts MATCH ?
            ORDER BY bm25(clipboard_fts)
            LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SearchError.searchFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, ftsQuery, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var slots: [Int] = []
        slots.reserveCapacity(limit)

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            let idString = String(cString: cStr)
            if let uuid = UUID(uuidString: idString),
               let slot = index.idToSlot[uuid] {
                slots.append(slot)
            }
        }

        return slots
    }

    private struct ScoredIndexedItem {
        let item: IndexedItem
        let score: Int
    }

    private func isBetter(_ lhs: ScoredIndexedItem, than rhs: ScoredIndexedItem) -> Bool {
        if lhs.item.isPinned != rhs.item.isPinned {
            return lhs.item.isPinned && !rhs.item.isPinned
        }
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        return lhs.item.lastUsedAt > rhs.item.lastUsedAt
    }

    private func isWorse(_ lhs: ScoredIndexedItem, than rhs: ScoredIndexedItem) -> Bool {
        return isBetter(rhs, than: lhs)
    }

    private func intersectSorted(_ a: [Int], _ b: [Int]) -> [Int] {
        var i = 0
        var j = 0
        var result: [Int] = []
        result.reserveCapacity(min(a.count, b.count))

        while i < a.count && j < b.count {
            let va = a[i]
            let vb = b[j]
            if va == vb {
                result.append(va)
                i += 1
                j += 1
            } else if va < vb {
                i += 1
            } else {
                j += 1
            }
        }

        return result
    }

    private struct BinaryHeap<Element> {
        private(set) var elements: [Element] = []
        private let areSorted: (Element, Element) -> Bool

        init(areSorted: @escaping (Element, Element) -> Bool) {
            self.areSorted = areSorted
        }

        var count: Int { elements.count }
        var peek: Element? { elements.first }

        mutating func reserveCapacity(_ n: Int) {
            elements.reserveCapacity(n)
        }

        mutating func insert(_ value: Element) {
            elements.append(value)
            siftUp(from: elements.count - 1)
        }

        mutating func replaceRoot(with value: Element) {
            guard !elements.isEmpty else {
                elements = [value]
                return
            }
            elements[0] = value
            siftDown(from: 0)
        }

        private mutating func siftUp(from index: Int) {
            var child = index
            var parent = (child - 1) / 2
            while child > 0 && areSorted(elements[child], elements[parent]) {
                elements.swapAt(child, parent)
                child = parent
                parent = (child - 1) / 2
            }
        }

        private mutating func siftDown(from index: Int) {
            var parent = index
            while true {
                let left = parent * 2 + 1
                let right = left + 1
                var candidate = parent

                if left < elements.count && areSorted(elements[left], elements[candidate]) {
                    candidate = left
                }
                if right < elements.count && areSorted(elements[right], elements[candidate]) {
                    candidate = right
                }

                if candidate == parent { return }
                elements.swapAt(parent, candidate)
                parent = candidate
            }
        }
    }

    private func upsertItemIntoIndex(_ item: StorageService.StoredItem, index: FullFuzzyIndex) {
        if let slot = index.idToSlot[item.id], let existing = index.items[slot] {
            if existing.plainText != item.plainText {
                fullIndex = nil
                fullIndexStale = true
                return
            }

            var updated = existing
            updated.lastUsedAt = item.lastUsedAt
            updated.useCount = item.useCount
            updated.isPinned = item.isPinned
            index.items[slot] = updated
            return
        }

        let indexed = IndexedItem(from: item)
        let slot = index.items.count
        index.items.append(indexed)
        index.idToSlot[indexed.id] = slot

        for ch in uniqueNonWhitespaceCharacters(indexed.plainTextLower) {
            index.charPostings[ch, default: []].append(slot)
        }
    }

    private func uniqueNonWhitespaceCharacters(_ text: String) -> [Character] {
        var seen = Set<Character>()
        var result: [Character] = []
        seen.reserveCapacity(min(text.count, 64))
        result.reserveCapacity(min(text.count, 64))

        for ch in text {
            if ch.isWhitespace { continue }
            if seen.insert(ch).inserted {
                result.append(ch)
            }
        }
        return result
    }

    private func fuzzyMatchScore(
        textLower: String,
        textLowerIsASCII: Bool,
        queryLower: String,
        queryLowerIsASCII: Bool
    ) -> Int? {
        guard !queryLower.isEmpty else { return 0 }

        // v0.26: 对极短查询（≤2 字符）使用连续子串语义
        // 全量历史仍参与搜索，但避免 subsequence 产生的大量弱相关噪音
        if queryLower.count <= 2 {
            guard let range = textLower.range(of: queryLower) else { return nil }
            let pos = range.lowerBound.utf16Offset(in: textLower)
            let m = queryLower.utf16.count
            return m * 10 - (m - 1) - pos
        }

        // ASCII 连续子串快速路径：等价于最优 subsequence 匹配
        if queryLowerIsASCII,
           textLowerIsASCII,
           let range = textLower.range(of: queryLower) {
            let pos = range.lowerBound.utf16Offset(in: textLower)
            let m = queryLower.utf16.count
            return m * 10 - (m - 1) - pos
        }

        var textIndex = textLower.startIndex
        var firstPos: Int?
        var lastPos = 0
        var gapPenalty = 0
        var matchedCount = 0

        for ch in queryLower {
            guard let found = textLower[textIndex...].firstIndex(of: ch) else { return nil }
            let pos = textLower.distance(from: textLower.startIndex, to: found)
            if firstPos == nil { firstPos = pos }
            gapPenalty += textLower.distance(from: textIndex, to: found)
            matchedCount += 1
            textIndex = textLower.index(after: found)
            lastPos = pos
        }

        let span = firstPos.map { lastPos - $0 } ?? 0
        return matchedCount * 10 - span - gapPenalty
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

    /// v0.19.1: Fuzzy+ 匹配 - 按空格分词，每个词独立模糊匹配
    /// 例如 "周五 匹配" 会匹配同时包含 "周五" 和 "匹配" 的文本
    private func fuzzyPlusMatch(text: String, query: String) -> Bool {
        // 按空格分词，过滤空字符串
        let words = query.split(separator: " ").map { String($0) }.filter { !$0.isEmpty }

        // 空查询匹配所有
        guard !words.isEmpty else { return true }

        // 所有词都必须匹配
        return words.allSatisfy { word in
            fuzzyMatch(text: text, query: word)
        }
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

    /// v0.19: 使用共享的 parseStoredItem 函数，消除代码重复
    private func parseItem(from stmt: OpaquePointer) -> StorageService.StoredItem? {
        return parseStoredItem(from: stmt)
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
            // v0.22: 支持 typeFilters 多类型过滤
            if let typeFilters = request.typeFilters, !typeFilters.isEmpty {
                let placeholders = typeFilters.map { _ in "?" }.joined(separator: ",")
                sql += " AND type IN (\(placeholders))"
                for type in typeFilters {
                    params.append(type.rawValue)
                }
            } else if let typeFilter = request.typeFilter {
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
}

// MARK: - SQLITE_TRANSIENT helper
// v0.19: 移至 SQLiteHelpers.swift，此处保留注释说明
// 使用全局 SQLITE_TRANSIENT 常量（定义在 SQLiteHelpers.swift）
