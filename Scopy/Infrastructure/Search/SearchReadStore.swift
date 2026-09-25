import Foundation
import SQLite3

/// The search engine's read-only SQLite connection and every query it runs. Owned by the engine
/// actor and never shared: the engine interrupts this connection on timeout or cancellation, and
/// a separate connection keeps those interrupts and the 10-40 ms FTS scans away from the
/// repository's write transactions.
final class SearchReadStore {
    struct Page {
        let items: [ClipboardStoredItem]
        /// `-1` when a further page may exist.
        let total: Int
        let hasMore: Bool

        static let empty = Page(items: [], total: 0, hasMore: false)
    }

    /// The optional row filters every listing query supports; `typeFilters` wins over `typeFilter`.
    struct Filters {
        let appFilter: String?
        let typeFilter: ClipboardItemType?
        let typeFilters: [ClipboardItemType]?

        init(_ request: SearchRequest) {
            appFilter = request.appFilter
            typeFilter = request.typeFilter
            typeFilters = request.typeFilters.map(Array.init)
        }

        /// Appends `AND` clauses and their parameters. `column` prefixes the column names for
        /// joined queries (`"clipboard_items."`).
        func append(to sql: inout String, params: inout [String], column: String = "") {
            if let appFilter {
                sql += " AND \(column)app_bundle_id = ?"
                params.append(appFilter)
            }

            if let typeFilters, !typeFilters.isEmpty {
                let placeholders = typeFilters.map { _ in "?" }.joined(separator: ",")
                sql += " AND \(column)type IN (\(placeholders))"
                params.append(contentsOf: typeFilters.map(\.rawValue))
            } else if let typeFilter {
                sql += " AND \(column)type = ?"
                params.append(typeFilter.rawValue)
            }
        }
    }

    /// One page of a listing: the query fetches `limit + 1` rows so `hasMore` needs no count.
    struct PageWindow {
        let limit: Int
        let offset: Int

        init(_ request: SearchRequest) {
            limit = request.limit
            offset = request.offset
        }

        func bind(to stmt: SQLiteStatement, at index: Int32) throws {
            try stmt.bindInt(limit + 1, at: index)
            try stmt.bindInt(offset, at: index + 1)
        }

        func page(_ fetched: [ClipboardStoredItem]) -> Page {
            var items = fetched
            let hasMore = items.count > limit
            if hasMore {
                items.removeLast()
            }
            return Page(items: items, total: hasMore ? -1 : offset + items.count, hasMore: hasMore)
        }
    }

    struct CorpusMetrics: Sendable {
        let itemCount: Int
        let avgPlainTextLength: Double
        let maxPlainTextLength: Int

        /// A long-text corpus makes full-history fuzzy scanning expensive and unpredictable:
        /// average of 1k characters or a 100k-character item prefers FTS for interactive fuzzy.
        var isHeavyPlainTextCorpus: Bool {
            avgPlainTextLength >= 1024 || maxPlainTextLength >= 100_000
        }
    }

    private struct CachedStatement {
        let sql: String
        let statement: SQLiteStatement
    }

    private let dbPath: String
    private var connection: SQLiteConnection?
    private var statementCache: [String: CachedStatement] = [:]
    private var statementCacheLRU: [String] = []
    private let statementCacheLimit = 32

    init(dbPath: String) {
        self.dbPath = dbPath
    }

    var isOpen: Bool { connection != nil }

    /// For `sqlite3_interrupt` from the engine's timeout and cancellation handlers.
    var connectionHandle: OpaquePointer? { connection?.handle }

    func open() throws {
        guard connection == nil else { return }

        let conn: SQLiteConnection
        do {
            conn = try Self.openConnection(dbPath: dbPath)
        } catch {
            throw SearchEngineImpl.SearchError.searchFailed(error.localizedDescription)
        }

        do {
            try SQLiteSchema.requireCurrentSchema(conn)
        } catch {
            conn.close()
            throw SearchEngineImpl.SearchError.searchFailed(error.localizedDescription)
        }

        connection = conn
        statementCache = [:]
        statementCacheLRU = []
    }

    func close() {
        statementCache = [:]
        statementCacheLRU = []
        connection?.close()
        connection = nil
    }

    /// Drops cached statements and the connection's page cache.
    func trimMemory() {
        statementCache = [:]
        statementCacheLRU = []
        connection?.releaseMemory()
    }

    /// A read-only connection tuned for search reads. The index builds open their own, off the
    /// engine actor.
    private static func openConnection(dbPath: String) throws -> SQLiteConnection {
        let conn = try SQLiteConnection(path: dbPath, flags: SQLiteConnection.openFlags(for: dbPath, readOnly: true))
        do {
            try conn.execute("PRAGMA query_only = 1")
            try conn.execute("PRAGMA busy_timeout = 500")
            try conn.execute("PRAGMA cache_size = -64000")
            try conn.execute("PRAGMA temp_store = MEMORY")
            try conn.execute("PRAGMA mmap_size = 268435456")
        } catch {
            conn.close()
            throw error
        }
        return conn
    }

    /// A prepared statement for `sql`, reset and ready to bind; the most recent 32 are kept.
    private func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let connection else { throw SearchEngineImpl.SearchError.databaseNotOpen }

        if let cached = statementCache[sql] {
            cached.statement.reset()
            if let idx = statementCacheLRU.firstIndex(of: sql) {
                statementCacheLRU.remove(at: idx)
            }
            statementCacheLRU.append(sql)
            return cached.statement
        }

        do {
            let stmt = try connection.prepare(sql)
            if statementCache.count >= statementCacheLimit {
                while statementCache.count >= statementCacheLimit, let evictSQL = statementCacheLRU.first {
                    statementCacheLRU.removeFirst()
                    statementCache.removeValue(forKey: evictSQL)
                }

                if statementCache.count >= statementCacheLimit {
                    statementCache.removeAll(keepingCapacity: true)
                    statementCacheLRU.removeAll(keepingCapacity: true)
                }
            }

            statementCache[sql] = CachedStatement(sql: sql, statement: stmt)
            if let idx = statementCacheLRU.firstIndex(of: sql) {
                statementCacheLRU.remove(at: idx)
            }
            statementCacheLRU.append(sql)
            return stmt
        } catch {
            statementCache.removeValue(forKey: sql)
            if let idx = statementCacheLRU.firstIndex(of: sql) {
                statementCacheLRU.remove(at: idx)
            }
            throw SearchEngineImpl.SearchError.searchFailed(error.localizedDescription)
        }
    }

    // MARK: - Metadata

    func fetchMutationSeq() throws -> Int64 {
        let stmt = try prepare("SELECT mutation_seq FROM scopy_meta WHERE id = 1")
        defer { stmt.reset() }
        guard try stmt.step() else { return 0 }
        return stmt.columnInt64(0)
    }

    func corpusMetrics() throws -> CorpusMetrics {
        // Served as an index-only scan by idx_plain_text_bytes (see SQLiteMigrations); the
        // aggregate expression must stay byte-identical to that index's expression.
        let sql = """
            SELECT COUNT(*), AVG(LENGTH(CAST(plain_text AS BLOB))), MAX(LENGTH(CAST(plain_text AS BLOB)))
            FROM clipboard_items
        """
        let stmt = try prepare(sql)
        defer { stmt.reset() }

        guard try stmt.step() else {
            return CorpusMetrics(itemCount: 0, avgPlainTextLength: 0, maxPlainTextLength: 0)
        }

        return CorpusMetrics(
            itemCount: stmt.columnInt(0),
            avgPlainTextLength: stmt.columnDouble(1),
            maxPlainTextLength: stmt.columnInt(2)
        )
    }

    // MARK: - Row fetches

    func fetchRecentSummaries(limit: Int, offset: Int) throws -> [ClipboardStoredItem] {
        let sql = """
            SELECT \(ClipboardItemRow.summaryColumns)
            FROM clipboard_items
            ORDER BY is_pinned DESC, last_used_at DESC, id ASC
            LIMIT ? OFFSET ?
        """
        let stmt = try prepare(sql)
        defer { stmt.reset() }
        try stmt.bindInt(limit, at: 1)
        try stmt.bindInt(offset, at: 2)

        var items: [ClipboardStoredItem] = []
        items.reserveCapacity(limit)
        var row = 0
        while try stmt.step() {
            if row % 512 == 0 { try Task.checkCancellation() }
            row += 1
            items.append(try ClipboardItemRow.decodeSummary(stmt))
        }
        return items
    }

    /// The rows for `ids`, in the given order; missing ids are skipped.
    func fetchItemsByIDs(_ ids: [UUID]) throws -> [ClipboardStoredItem] {
        guard !ids.isEmpty else { return [] }

        // A fixed SQL shape keeps the statement cached; the JSON array carries the order.
        let sql = """
            WITH ids(id, ord) AS (
                SELECT value, CAST(key AS INT)
                FROM json_each(?)
            )
            SELECT \(ClipboardItemRow.qualifiedSummaryColumns)
            FROM ids
            JOIN clipboard_items ON clipboard_items.id = ids.id
            ORDER BY ids.ord
        """
        let stmt = try prepare(sql)
        defer { stmt.reset() }

        try stmt.bindText(Self.jsonArray(ids.map(\.uuidString)), at: 1)

        var fetched: [ClipboardStoredItem] = []
        fetched.reserveCapacity(ids.count)
        while try stmt.step() {
            fetched.append(try ClipboardItemRow.decodeSummary(stmt))
        }

        return fetched
    }

    func fetchAll(filters: Filters, window: PageWindow) throws -> Page {
        var sql = """
            SELECT \(ClipboardItemRow.summaryColumns)
            FROM clipboard_items
            WHERE 1 = 1
        """
        var params: [String] = []
        filters.append(to: &sql, params: &params)
        sql += " ORDER BY is_pinned DESC, last_used_at DESC, id ASC"
        sql += " LIMIT ? OFFSET ?"

        return try runPage(sql, params: params, window: window)
    }

    // MARK: - FTS

    func searchFTS(ftsQuery: String, sortMode: SearchSortMode, filters: Filters, window: PageWindow) throws -> Page {
        var sql = """
            SELECT \(ClipboardItemRow.qualifiedSummaryColumns)
            FROM clipboard_fts
            JOIN clipboard_items ON clipboard_items.rowid = clipboard_fts.rowid
            WHERE clipboard_fts MATCH ?
        """
        var params: [String] = [ftsQuery]
        filters.append(to: &sql, params: &params, column: "clipboard_items.")

        switch sortMode {
        case .relevance:
            sql += " ORDER BY clipboard_items.is_pinned DESC, bm25(clipboard_fts) ASC, clipboard_items.last_used_at DESC, clipboard_items.id ASC"
        case .recent:
            sql += " ORDER BY clipboard_items.is_pinned DESC, clipboard_items.last_used_at DESC, clipboard_items.id ASC"
        }
        sql += " LIMIT ? OFFSET ?"

        return try runPage(sql, params: params, window: window)
    }

    /// Ids of the best FTS matches, pinned and recent first; narrows a large fuzzy candidate set.
    func ftsPrefilterIDs(ftsQuery: String, limit: Int) throws -> [UUID] {
        let sql = """
            SELECT clipboard_items.id
            FROM clipboard_fts
            JOIN clipboard_items ON clipboard_items.rowid = clipboard_fts.rowid
            WHERE clipboard_fts MATCH ?
            ORDER BY clipboard_items.is_pinned DESC, clipboard_items.last_used_at DESC
            LIMIT ?
        """
        let stmt = try prepare(sql)
        defer { stmt.reset() }
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

    // MARK: - Substring

    /// Every token must occur in the plain text or note. Tokens of three or more characters go
    /// through the case-insensitive trigram index; shorter ones scan with case-sensitive `instr`.
    func searchSubstring(tokens: [String], sortMode: SearchSortMode, filters: Filters, window: PageWindow) throws -> Page {
        let tokens = tokens.filter { !$0.isEmpty }
        guard let primary = tokens.first else { return .empty }
        let extraTokens = Array(tokens.dropFirst())

        if Self.trigramCanMatch(tokens) {
            return try searchTrigram(tokens: tokens, sortMode: sortMode, filters: filters, window: window)
        }

        var params: [String] = []
        var sql: String

        func appendTokenFilter(_ token: String) {
            sql += " AND (instr(plain_text, ?) > 0 OR instr(coalesce(note, ''), ?) > 0)"
            params.append(token)
            params.append(token)
        }

        switch sortMode {
        case .recent:
            sql = """
                SELECT \(ClipboardItemRow.summaryColumns)
                FROM clipboard_items INDEXED BY idx_pinned
                WHERE 1 = 1
            """
            filters.append(to: &sql, params: &params)
            appendTokenFilter(primary)
            for token in extraTokens {
                appendTokenFilter(token)
            }
            sql += " ORDER BY is_pinned DESC, last_used_at DESC, id ASC"
            sql += " LIMIT ? OFFSET ?"
        case .relevance:
            sql = """
                SELECT \(ClipboardItemRow.summaryColumns)
                FROM (
                    SELECT \(ClipboardItemRow.summaryColumns),
                           instr(plain_text, ?) AS plainPos,
                           instr(coalesce(note, ''), ?) AS notePos
                    FROM clipboard_items INDEXED BY idx_pinned
                    WHERE 1 = 1
            """
            params.append(primary)
            params.append(primary)
            filters.append(to: &sql, params: &params)
            for token in extraTokens {
                appendTokenFilter(token)
            }
            sql += Self.earliestPositionOrderTail
        }

        return try runPage(sql, params: params, window: window)
    }

    /// Every token must occur in the plain text or note, case-insensitively, through the
    /// trigram index; every token needs at least three characters, the tokenizer's minimum.
    func searchTrigram(tokens: [String], sortMode: SearchSortMode, filters: Filters, window: PageWindow) throws -> Page {
        let tokens = tokens.filter { !$0.isEmpty }
        guard let primary = tokens.first else { return .empty }

        var sql: String
        var params: [String] = []

        switch sortMode {
        case .recent:
            sql = """
                SELECT \(ClipboardItemRow.qualifiedSummaryColumns)
                FROM clipboard_fts_trigram
                JOIN clipboard_items ON clipboard_items.rowid = clipboard_fts_trigram.rowid
                WHERE clipboard_fts_trigram MATCH ?
            """
            params.append(Self.trigramFTSQuery(tokens: tokens))
        case .relevance:
            sql = """
                SELECT \(ClipboardItemRow.summaryColumns)
                FROM (
                    SELECT \(ClipboardItemRow.qualifiedSummaryColumns),
                           instr(lower(clipboard_items.plain_text), ?) AS plainPos,
                           instr(lower(coalesce(clipboard_items.note, '')), ?) AS notePos
                    FROM clipboard_fts_trigram
                    JOIN clipboard_items ON clipboard_items.rowid = clipboard_fts_trigram.rowid
                    WHERE clipboard_fts_trigram MATCH ?
            """
            let primaryLower = primary.lowercased()
            params.append(primaryLower)
            params.append(primaryLower)
            params.append(Self.trigramFTSQuery(tokens: tokens))
        }

        filters.append(to: &sql, params: &params)

        switch sortMode {
        case .recent:
            sql += " ORDER BY is_pinned DESC, last_used_at DESC, id ASC"
            sql += " LIMIT ? OFFSET ?"
        case .relevance:
            sql += Self.earliestPositionOrderTail
        }

        return try runPage(sql, params: params, window: window)
    }

    // MARK: - Short queries (one or two characters)

    /// Full scan for a short token. Ranks a note-only match as if it followed the plain text
    /// and one separator, so plain-text matches outrank note-only matches.
    func searchShortQuerySubstring(tokenLower: String, sortMode: SearchSortMode, filters: Filters, window: PageWindow) throws -> Page {
        let tokenLower = tokenLower.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tokenLower.isEmpty else { return .empty }

        var params: [String] = [tokenLower, tokenLower]
        var sql = """
            SELECT \(ClipboardItemRow.summaryColumns)
            FROM (
                SELECT \(ClipboardItemRow.summaryColumns),
                       \(Self.shortQueryPositionColumns(tokenLower: tokenLower))
                FROM clipboard_items INDEXED BY idx_pinned
                WHERE 1 = 1
        """
        filters.append(to: &sql, params: &params)
        sql += Self.shortQueryOrderTail(sortMode: sortMode)

        return try runPage(sql, params: params, window: window)
    }

    /// The short index's candidate ids, filtered and ranked in SQL by match position.
    func searchShortQuerySubstringCandidatesSQL(
        tokenLower: String,
        candidateIDStrings: [String],
        sortMode: SearchSortMode,
        filters: Filters,
        window: PageWindow
    ) throws -> Page {
        let tokenLower = tokenLower.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tokenLower.isEmpty else { return .empty }
        guard !candidateIDStrings.isEmpty else { return .empty }

        var params: [String] = [Self.jsonArray(candidateIDStrings), tokenLower, tokenLower]
        var sql = """
            WITH candidates(id) AS (SELECT value FROM json_each(?))
            SELECT \(ClipboardItemRow.summaryColumns)
            FROM (
                SELECT \(ClipboardItemRow.qualifiedSummaryColumns),
                       \(Self.shortQueryPositionColumns(tokenLower: tokenLower))
                FROM clipboard_items
                JOIN candidates ON clipboard_items.id = candidates.id
                WHERE 1 = 1
        """
        filters.append(to: &sql, params: &params)
        sql += Self.shortQueryOrderTail(sortMode: sortMode)

        return try runPage(sql, params: params, window: window)
    }

    /// The short index's candidate ids for a one- or two-byte ASCII token, matched
    /// case-insensitively over the raw UTF-8 bytes and ranked in Swift, which avoids SQLite's
    /// `lower()` over long texts.
    func searchShortQuerySubstringCandidates(
        tokenLower: String,
        candidateIDStrings: [String],
        sortMode: SearchSortMode,
        filters: Filters,
        window: PageWindow
    ) throws -> Page {
        let tokenLower = tokenLower.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tokenLower.isEmpty else { return .empty }
        guard !candidateIDStrings.isEmpty else { return .empty }

        let needleLowerBytes = Array(tokenLower.utf8)
        guard (needleLowerBytes.count == 1 || needleLowerBytes.count == 2),
              needleLowerBytes.allSatisfy({ $0 < 128 }) else {
            return try searchShortQuerySubstring(
                tokenLower: tokenLower,
                sortMode: sortMode,
                filters: filters,
                window: window
            )
        }

        var sql = """
            WITH candidates(id) AS (SELECT value FROM json_each(?))
            SELECT clipboard_items.id,
                   clipboard_items.last_used_at,
                   clipboard_items.is_pinned,
                   clipboard_items.plain_text,
                   clipboard_items.note
            FROM clipboard_items
            JOIN candidates ON clipboard_items.id = candidates.id
            WHERE 1 = 1
        """
        var params: [String] = [Self.jsonArray(candidateIDStrings)]
        filters.append(to: &sql, params: &params)

        let stmt = try prepare(sql)
        defer { stmt.reset() }
        try Self.bind(params, to: stmt)

        let keepCount = window.offset + window.limit + 1
        var selector = TopKSelector<SearchRankKey>(capacity: keepCount) { lhs, rhs in
            SearchRankKey.isBetter(lhs, than: rhs, sortMode: sortMode)
        }
        selector.reserveCapacity(min(keepCount, 8192))

        while try stmt.step() {
            guard let idString = stmt.columnText(0), let id = UUID(uuidString: idString) else { continue }

            let lastUsedAt = Date(timeIntervalSince1970: stmt.columnDouble(1))
            let isPinned = stmt.columnInt(2) != 0

            let plainRes = Self.instrASCIIInsensitiveUTF8(
                haystack: stmt.columnTextBytes(3),
                needleLower: needleLowerBytes
            )
            let matchPos: Int
            if plainRes.pos > 0 {
                matchPos = plainRes.pos
            } else {
                let noteRes = Self.instrASCIIInsensitiveUTF8(
                    haystack: stmt.columnTextBytes(4),
                    needleLower: needleLowerBytes
                )
                guard noteRes.pos > 0 else { continue }
                // A note match ranks as if it followed the plain text and one separator.
                matchPos = plainRes.lengthIfNoMatch + 1 + noteRes.pos
            }
            selector.offer(SearchRankKey(isPinned: isPinned, lastUsedAt: lastUsedAt, score: -matchPos, id: id))
        }

        let hits = selector.sortedElements()
        let start = min(window.offset, hits.count)
        let end = min(window.offset + window.limit + 1, hits.count)
        var pageIDs: [UUID] = (start < end) ? hits[start..<end].map(\.id) : []

        let hasMore = hits.count == keepCount
        if hasMore {
            pageIDs.removeLast()
        }

        let items = try fetchItemsByIDs(pageIDs)
        return Page(items: items, total: hasMore ? -1 : window.offset + items.count, hasMore: hasMore)
    }

    // MARK: - Index scans (a private connection each, off the engine actor)

    /// Every row's short-index fields; `nil` when the task is cancelled or the scan fails. A row
    /// that cannot be decoded fails the scan: an index missing rows must not pass as complete.
    static func loadShortQueryIndex(dbPath: String, reserveSlots: Int) -> ShortQueryIndex? {
        guard let conn = try? openConnection(dbPath: dbPath) else { return nil }
        defer { conn.close() }

        var index = ShortQueryIndex(reserveSlots: reserveSlots)

        do {
            let stmt = try conn.prepare("SELECT id, type, content_hash, plain_text, note FROM clipboard_items")
            var row = 0
            while try stmt.step() {
                if row % 256 == 0, Task.isCancelled { return nil }
                row += 1

                guard let idString = stmt.columnText(0),
                      let id = UUID(uuidString: idString),
                      let typeRaw = stmt.columnText(1),
                      let type = ClipboardItemType(rawValue: typeRaw) else {
                    throw ClipboardItemRow.DecodeError.invalidRow
                }

                let contentHash = stmt.columnText(2) ?? ""
                let plainText = stmt.columnText(3) ?? ""
                let note = stmt.columnText(4)

                index.upsert(id: id, type: type, contentHash: contentHash, plainText: plainText, note: note)
            }
        } catch {
            logScanFailure("short", error)
            return nil
        }

        guard !Task.isCancelled else { return nil }
        return index
    }

    /// Every row's summary; `nil` when the task is cancelled or the scan fails. A row that cannot
    /// be decoded fails the scan: an index missing rows must not pass as complete.
    static func loadFullIndex(dbPath: String, reserveSlots: Int) -> FullFuzzyIndex? {
        guard let conn = try? openConnection(dbPath: dbPath) else { return nil }
        defer { conn.close() }

        var index = FullFuzzyIndex(reserveSlots: reserveSlots)

        do {
            let stmt = try conn.prepare("SELECT \(ClipboardItemRow.summaryColumns) FROM clipboard_items")
            defer { stmt.reset() }

            var row = 0
            while try stmt.step() {
                if row % 512 == 0, Task.isCancelled { return nil }
                row += 1
                index.append(IndexedItem(from: try ClipboardItemRow.decodeSummary(stmt)))
            }
        } catch {
            logScanFailure("full", error)
            return nil
        }

        guard !Task.isCancelled else { return nil }
        return index
    }

    /// SQLite failures carry their extended result code; row content is never logged.
    private static func logScanFailure(_ index: String, _ error: Error) {
        let reason: String
        if let sqlite = error as? SQLiteConnection.SQLiteConnectionError {
            reason = "sqlite code=\(sqlite.code) category=\(sqlite.category.rawValue)"
        } else if error is ClipboardItemRow.DecodeError {
            reason = "undecodable row"
        } else {
            reason = String(describing: type(of: error))
        }
        ScopyLog.search.error("\(index, privacy: .public) index scan failed: \(reason, privacy: .public)")
    }

    // MARK: - SQL fragments

    /// Closes the position subquery and orders by pinned, earliest match position, recency, id.
    private static let earliestPositionOrderTail = """
            ) t
        WHERE plainPos > 0 OR notePos > 0
        ORDER BY is_pinned DESC,
                 CASE
                   WHEN plainPos > 0 AND notePos > 0 THEN CASE WHEN plainPos < notePos THEN plainPos ELSE notePos END
                   WHEN plainPos > 0 THEN plainPos
                   ELSE notePos
                 END ASC,
                 last_used_at DESC,
                 id ASC
        LIMIT ? OFFSET ?
    """

    /// `plainPos`, `notePos`, `plainLen` for a short token; ASCII tokens compare case-insensitively.
    private static func shortQueryPositionColumns(tokenLower: String) -> String {
        let useLower = tokenLower.canBeConverted(to: .ascii)
        let plainSearchExpr = useLower ? "lower(plain_text)" : "plain_text"
        let noteSearchExpr = useLower ? "lower(coalesce(note, ''))" : "coalesce(note, '')"
        return """
            instr(\(plainSearchExpr), ?) AS plainPos,
                   instr(\(noteSearchExpr), ?) AS notePos,
                   length(coalesce(plain_text, '')) AS plainLen
        """
    }

    private static func shortQueryOrderTail(sortMode: SearchSortMode) -> String {
        var sql = """
                ) t
            WHERE plainPos > 0 OR notePos > 0
            ORDER BY is_pinned DESC,
        """
        if sortMode == .recent {
            sql += " last_used_at DESC,"
        }
        sql += """
                     CASE
                       WHEN plainPos > 0 THEN plainPos
                       ELSE plainLen + 1 + notePos
                     END ASC,
        """
        if sortMode == .relevance {
            sql += " last_used_at DESC,"
        }
        sql += """
                     id ASC
            LIMIT ? OFFSET ?
        """
        return sql
    }

    private static func trigramCanMatch(_ tokens: [String]) -> Bool {
        !tokens.isEmpty && tokens.allSatisfy { $0.count >= 3 }
    }

    /// Each non-empty token as a quoted phrase, joined with `AND`.
    private static func trigramFTSQuery(tokens: [String]) -> String {
        tokens.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " AND ")
    }

    private static func jsonArray(_ strings: [String]) -> String {
        var json = "["
        json.reserveCapacity(strings.count * 40 + 2)
        for (i, string) in strings.enumerated() {
            if i > 0 { json.append(",") }
            json.append("\"")
            json.append(string)
            json.append("\"")
        }
        json.append("]")
        return json
    }

    /// 1-based code point position of the ASCII needle in the UTF-8 haystack, ignoring ASCII
    /// case; `lengthIfNoMatch` is the haystack's code point count when nothing matched.
    private static func instrASCIIInsensitiveUTF8(
        haystack: (ptr: UnsafePointer<UInt8>, length: Int)?,
        needleLower: [UInt8]
    ) -> (pos: Int, lengthIfNoMatch: Int) {
        guard let haystack else { return (pos: 0, lengthIfNoMatch: 0) }
        guard !needleLower.isEmpty else { return (pos: 1, lengthIfNoMatch: 0) }

        @inline(__always)
        func lowerASCII(_ b: UInt8) -> UInt8 {
            if b >= 65 && b <= 90 { return b | 0x20 }
            return b
        }

        let n0 = needleLower[0]
        let n1 = (needleLower.count >= 2) ? needleLower[1] : 0

        var i = 0
        var codepointPos = 1
        var prevLower: UInt8? = nil
        var prevPos = 0

        while i < haystack.length {
            let byte = haystack.ptr[i]
            if byte < 128 {
                let lower = lowerASCII(byte)

                if needleLower.count == 1 {
                    if lower == n0 { return (pos: codepointPos, lengthIfNoMatch: 0) }
                } else if let prevLower, prevLower == n0, lower == n1 {
                    return (pos: prevPos, lengthIfNoMatch: 0)
                }

                prevLower = lower
                prevPos = codepointPos

                i += 1
                codepointPos += 1
                continue
            }

            prevLower = nil

            let adv: Int
            switch byte {
            case 0xC0...0xDF: adv = 2
            case 0xE0...0xEF: adv = 3
            case 0xF0...0xF7: adv = 4
            default: adv = 1
            }

            i += adv
            codepointPos += 1
        }

        return (pos: 0, lengthIfNoMatch: codepointPos - 1)
    }

    private static func bind(_ params: [String], to stmt: SQLiteStatement) throws {
        var bindIndex: Int32 = 1
        for param in params {
            try stmt.bindText(param, at: bindIndex)
            bindIndex += 1
        }
    }

    private func runPage(_ sql: String, params: [String], window: PageWindow) throws -> Page {
        let stmt = try prepare(sql)
        defer { stmt.reset() }
        try Self.bind(params, to: stmt)
        try window.bind(to: stmt, at: Int32(params.count + 1))

        var items: [ClipboardStoredItem] = []
        items.reserveCapacity(window.limit + 1)
        while try stmt.step() {
            items.append(try ClipboardItemRow.decodeSummary(stmt))
        }
        return window.page(items)
    }
}
