import Foundation
import SQLite3

/// The search engine's read-only SQLite connection and every query it runs. Owned by the engine
/// actor and never shared. SQL checks the executing task's cancellation through a progress
/// callback, so cancelling a search that awaits an index or builds evidence cannot interrupt
/// another search. The connection also keeps FTS scans away from repository write transactions.
final class SearchReadStore {
    struct Page {
        let items: [ClipboardStoredItem]
        /// `-1` when a further page may exist.
        let total: Int
        let hasMore: Bool

        static let empty = Page(items: [], total: 0, hasMore: false)
    }

    /// The optional row filters every listing query supports; `typeFilters` wins over `typeFilter`.
    struct Filters: Equatable {
        let appFilter: String?
        let typeFilter: ClipboardItemType?
        /// Sorted, so equal sets compare and bind equally.
        let typeFilters: [ClipboardItemType]?

        init(_ request: SearchRequest) {
            appFilter = request.appFilter
            typeFilter = request.typeFilter
            typeFilters = request.typeFilters?.sorted { $0.rawValue < $1.rawValue }
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

        /// The same restriction as a rowid subquery that the filter columns' indexes answer, for
        /// scans that must not read rows: `app_bundle_id` lies behind the text's overflow pages.
        func appendAsRowIDSubquery(to sql: inout String, params: inout [String]) {
            var restriction = ""
            append(to: &restriction, params: &params)
            guard !restriction.isEmpty else { return }
            sql += " AND rowid IN (SELECT rowid FROM clipboard_items WHERE 1 = 1\(restriction))"
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

    /// Where a recent short-query scan stands; scans stop only between (pinned, last used) groups.
    private enum RecencyScanPosition {
        case start
        case after(isPinned: Bool, lastUsedAt: Double)
        case end
    }

    /// What the previous recent short-query page left: the ranked hits after it and where its
    /// scan stopped. The next page of the same query continues there while nothing was committed.
    private struct ShortQueryContinuation {
        let tokenLower: String
        let filters: Filters
        let mutationSeq: Int64
        let nextOffset: Int
        let hits: [SearchRankKey]
        let position: RecencyScanPosition
    }

    /// The previous relevance short query's scores, which every page of the same query reuses while
    /// nothing was committed: the rows its prefixes or full reads decided, and the rows still
    /// undecided, best bound first.
    private struct RelevanceScores {
        let tokenLower: String
        let filters: Filters
        let mutationSeq: Int64
        var hits: [SearchRankKey]
        var undecided: ArraySlice<(rowID: Int64, bound: SearchRankKey)>
    }

    private let dbPath: String
    private var connection: SQLiteConnection?
    private var statementCache: [String: CachedStatement] = [:]
    private var statementCacheLRU: [String] = []
    private let statementCacheLimit = 32
    private var shortQueryContinuation: ShortQueryContinuation?
    private var relevanceScores: RelevanceScores?

    init(dbPath: String) {
        self.dbPath = dbPath
    }

    var isOpen: Bool { connection != nil }

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
        shortQueryContinuation = nil
        relevanceScores = nil
        connection?.close()
        connection = nil
    }

    /// Drops cached statements and the connection's page cache.
    func trimMemory() {
        statementCache = [:]
        statementCacheLRU = []
        shortQueryContinuation = nil
        relevanceScores = nil
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
            // Maps up to 1 GiB, so reads past 256 MB of a large history skip the page-cache copy.
            try conn.execute("PRAGMA mmap_size = 1073741824")
        } catch {
            conn.close()
            throw error
        }
        // Every scan observes the task executing SQLite, including detached index builds.
        sqlite3_progress_handler(conn.handle, 1_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
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

    /// The sequence and every read in `body` belong to one SQLite snapshot. The closure is
    /// synchronous: the engine cannot reenter this connection while the transaction is open.
    func withReadSnapshot<Value>(_ body: (Int64) throws -> Value) throws -> Value {
        guard let connection else { throw SearchEngineImpl.SearchError.databaseNotOpen }
        return try Self.withReadSnapshot(connection: connection, body)
    }

    private static func withReadSnapshot<Value>(
        connection: SQLiteConnection,
        _ body: (Int64) throws -> Value
    ) throws -> Value {
        try connection.execute("BEGIN DEFERRED")
        do {
            let statement = try connection.prepare("SELECT mutation_seq FROM scopy_meta WHERE id = 1")
            guard try statement.step() else { throw ClipboardItemRow.DecodeError.invalidRow }
            let mutationSeq = statement.columnInt64(0)
            statement.reset()
            let value = try body(mutationSeq)
            try connection.execute("COMMIT")
            return value
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
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

    /// The trigram index supplies candidates and Swift decides substring membership, with the
    /// canonical equivalence the full index uses, in both sort modes; ASCII tokens are decided on the
    /// row's bytes, and a field is lowercased only when they cannot be. The tokenizer folds case but
    /// compares code points, so each token is looked up in its composed and decomposed forms; only a
    /// single word that mixes both forms is missed. Never scan the table: a non-ASCII query without
    /// trigram hits would lowercase every row (seconds on a real history).
    func searchTrigram(tokens: [String], sortMode: SearchSortMode, filters: Filters, window: PageWindow) throws -> Page {
        let tokens = tokens.filter { !$0.isEmpty }.map { $0.lowercased() }
        guard let primary = tokens.first else { return .empty }
        var sql = """
            SELECT clipboard_items.id, clipboard_items.last_used_at, clipboard_items.is_pinned,
                   clipboard_items.plain_text, clipboard_items.note
            FROM clipboard_fts_trigram
            JOIN clipboard_items ON clipboard_items.rowid = clipboard_fts_trigram.rowid
            WHERE clipboard_fts_trigram MATCH ?
        """
        var params = [Self.trigramFTSQuery(tokens: tokens)]
        filters.append(to: &sql, params: &params)
        if sortMode == .recent {
            sql += " ORDER BY clipboard_items.is_pinned DESC, clipboard_items.last_used_at DESC, clipboard_items.id ASC"
        }
        let stmt = try prepare(sql)
        defer { stmt.reset() }
        try Self.bind(params, to: stmt)

        let matchers = tokens.map { LoweredTextMatcher(charactersOf: $0) }
        let keepCount = window.offset + window.limit + 1
        var selector = TopKSelector<SearchRankKey>(capacity: keepCount) { lhs, rhs in
            SearchRankKey.isBetter(lhs, than: rhs, sortMode: sortMode)
        }
        var recentIDs: [UUID] = []
        var matchedCount = 0
        while try stmt.step() {
            try Task.checkCancellation()
            guard let idString = stmt.columnText(0), let id = UUID(uuidString: idString) else { continue }
            var row = LoweredRowText(plain: Self.bytes(stmt.columnTextBytes(3)), note: Self.bytes(stmt.columnTextBytes(4)))
            let plainPos = row.firstOffset(of: primary, matcher: matchers[0], inNote: false)
            let notePos = row.firstOffset(of: primary, matcher: matchers[0], inNote: true)
            guard plainPos != nil || notePos != nil else { continue }
            var matchesEveryToken = true
            for index in tokens.indices.dropFirst()
            where row.firstOffset(of: tokens[index], matcher: matchers[index], inNote: false) == nil
                && row.firstOffset(of: tokens[index], matcher: matchers[index], inNote: true) == nil {
                matchesEveryToken = false
                break
            }
            guard matchesEveryToken else { continue }

            if sortMode == .recent {
                if matchedCount >= window.offset { recentIDs.append(id) }
                matchedCount += 1
                // Already in final recency order: stop after the next reachable page is known.
                if recentIDs.count > window.limit { break }
            } else {
                let position = min(plainPos ?? Int.max, notePos ?? Int.max)
                selector.offer(SearchRankKey(
                    isPinned: stmt.columnInt(2) != 0,
                    lastUsedAt: Date(timeIntervalSince1970: stmt.columnDouble(1)),
                    score: -position,
                    id: id
                ))
            }
        }
        if sortMode == .recent {
            return try fetchPage(recentIDs[...], window: window)
        }
        return try rankedPage(selector.sortedElements(), window: window)
    }

    // MARK: - Short queries (one or two characters)

    /// The same matcher and UTF-16 position scores as the full index, over either all rows or
    /// the short index's conservative candidates. Each row's normalized text is released at once.
    func searchShortQuerySubstring(
        tokenLower: String,
        candidateIDStrings: [String]? = nil,
        sortMode: SearchSortMode,
        filters: Filters,
        window: PageWindow
    ) throws -> Page {
        let tokenLower = tokenLower.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tokenLower.isEmpty else { return .empty }
        if let candidateIDStrings, candidateIDStrings.isEmpty { return .empty }
        let matcher = ShortQueryMatcher(tokenLower: tokenLower)
        if sortMode == .recent {
            return try newestMatchesPage(
                matcher,
                tokenLower: tokenLower,
                candidateIDStrings: candidateIDStrings,
                filters: filters,
                window: window
            )
        }

        return try bestMatchesPage(
            matcher,
            tokenLower: tokenLower,
            candidateIDStrings: candidateIDStrings,
            filters: filters,
            window: window
        )
    }

    /// The candidates' rows from the covering recency index, without reading the table: the
    /// recency columns lie behind the text's overflow pages. Filters are rowid subqueries.
    private func candidateRowsSQL(
        candidateIDStrings: [String]?,
        filters: Filters,
        keyset: String = "",
        params: inout [String]
    ) -> String {
        var sql = "SELECT rowid, id, is_pinned, last_used_at FROM clipboard_items INDEXED BY idx_recent_order WHERE 1 = 1"
        sql += keyset
        if let candidateIDStrings {
            sql += " AND id IN (SELECT value FROM json_each(?))"
            params.append(Self.jsonArray(candidateIDStrings))
        }
        filters.appendAsRowIDSubquery(to: &sql, params: &params)
        return sql + " ORDER BY is_pinned DESC, last_used_at DESC, id ASC"
    }

    /// Scores every candidate from the first bytes of its plain text where they decide it. A hit
    /// there outranks, pinned state aside, every row with no hit as early, so a row is read in full
    /// only while the best score it can still have would enter the window. Later pages of the same
    /// query start from the scores the earlier pages left.
    private func bestMatchesPage(
        _ matcher: ShortQueryMatcher,
        tokenLower: String,
        candidateIDStrings: [String]?,
        filters: Filters,
        window: PageWindow
    ) throws -> Page {
        let mutationSeq = try fetchMutationSeq()
        var scores: RelevanceScores
        if let previous = relevanceScores,
           previous.tokenLower == tokenLower,
           previous.filters == filters,
           previous.mutationSeq == mutationSeq {
            scores = previous
        } else {
            let (hits, undecided) = try prefixScores(matcher, candidateIDStrings: candidateIDStrings, filters: filters)
            scores = RelevanceScores(
                tokenLower: tokenLower,
                filters: filters,
                mutationSeq: mutationSeq,
                hits: hits,
                undecided: undecided[...]
            )
        }
        // Released while the scores change, so they are not copied; a cancelled page drops them.
        relevanceScores = nil

        let keepCount = window.offset + window.limit + 1
        var selector = TopKSelector<SearchRankKey>(capacity: keepCount) { lhs, rhs in
            SearchRankKey.isBetter(lhs, than: rhs, sortMode: .relevance)
        }
        selector.reserveCapacity(min(keepCount, 8192))
        for hit in scores.hits {
            selector.offer(hit)
        }
        let text = try prepare("SELECT plain_text, note FROM clipboard_items WHERE rowid = ?")
        defer { text.reset() }
        while let row = scores.undecided.first {
            try Task.checkCancellation()
            // Later rows have no better bound, and the weakest kept hit only improves.
            guard selector.wouldKeep(row.bound) else { break }
            scores.undecided.removeFirst()
            text.reset()
            try text.bindInt64(row.rowID, at: 1)
            guard try text.step(), let score = matcher.score(text, plainColumn: 0, noteColumn: 1) else { continue }
            let hit = SearchRankKey(isPinned: row.bound.isPinned, lastUsedAt: row.bound.lastUsedAt, score: score, id: row.bound.id)
            selector.offer(hit)
            scores.hits.append(hit)
        }
        relevanceScores = scores
        return try rankedPage(selector.sortedElements(), window: window)
    }

    /// Every candidate's score where its plain text's first bytes decide it, and the others with
    /// the best score each can have, best first.
    private func prefixScores(
        _ matcher: ShortQueryMatcher,
        candidateIDStrings: [String]?,
        filters: Filters
    ) throws -> (hits: [SearchRankKey], undecided: [(rowID: Int64, bound: SearchRankKey)]) {
        guard let connection else { throw SearchEngineImpl.SearchError.databaseNotOpen }
        var params: [String] = []
        let rows = try prepare(candidateRowsSQL(candidateIDStrings: candidateIDStrings, filters: filters, params: &params))
        defer { rows.reset() }
        try Self.bind(params, to: rows)

        var hits: [SearchRankKey] = []
        var undecided: [(rowID: Int64, bound: SearchRankKey)] = []
        let prefixReader = SQLiteBlobReader(connection: connection, table: "clipboard_items", column: "plain_text")
        defer { prefixReader.close() }
        var prefix = [UInt8](repeating: 0, count: ShortQueryMatcher.prefixBytes)
        while try rows.step() {
            try Task.checkCancellation()
            guard let idString = rows.columnText(1), let id = UUID(uuidString: idString) else { continue }
            let rowID = rows.columnInt64(0)
            let verdict = prefix.withUnsafeMutableBytes { buffer -> ShortQueryMatcher.PrefixVerdict in
                guard let read = prefixReader.readPrefix(rowID: rowID, into: buffer) else { return .scoreAtMost(matcher.baseScore) }
                let bytes = UnsafeBufferPointer(start: buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), count: read.copied)
                return matcher.prefixVerdict(bytes, isWholeValue: read.copied == read.length)
            }
            let isPinned = rows.columnInt(2) != 0
            let lastUsedAt = Date(timeIntervalSince1970: rows.columnDouble(3))
            switch verdict {
            case .score(let score):
                hits.append(SearchRankKey(isPinned: isPinned, lastUsedAt: lastUsedAt, score: score, id: id))
            case .scoreAtMost(let bound):
                undecided.append((rowID, SearchRankKey(isPinned: isPinned, lastUsedAt: lastUsedAt, score: bound, id: id)))
            }
        }
        undecided.sort { SearchRankKey.isBetter($0.bound, than: $1.bound, sortMode: .relevance) }
        return (hits, undecided)
    }

    /// Recency decides before the score, so rows are read newest first until the window and one
    /// more hit are in and the next row starts another (pinned, last used) group. A page that
    /// starts where the previous page of the same query ended continues that scan.
    private func newestMatchesPage(
        _ matcher: ShortQueryMatcher,
        tokenLower: String,
        candidateIDStrings: [String]?,
        filters: Filters,
        window: PageWindow
    ) throws -> Page {
        let mutationSeq = try fetchMutationSeq()
        // `hits` are ranked from `firstRank` on.
        var firstRank = 0
        var hits: [SearchRankKey] = []
        var position = RecencyScanPosition.start
        if let previous = shortQueryContinuation,
           previous.tokenLower == tokenLower,
           previous.filters == filters,
           previous.mutationSeq == mutationSeq,
           previous.nextOffset == window.offset {
            firstRank = previous.nextOffset
            hits = previous.hits
            position = previous.position
        }

        let neededHits = window.offset + window.limit + 1 - firstRank
        if hits.count < neededHits {
            let scanned = hits.count
            position = try scanNewest(
                matcher,
                after: position,
                candidateIDStrings: candidateIDStrings,
                filters: filters,
                until: neededHits,
                into: &hits
            )
            // Earlier groups rank first, so only the new groups need ordering.
            hits[scanned...].sort { SearchRankKey.isBetter($0, than: $1, sortMode: .recent) }
        }

        let pageStart = min(window.offset - firstRank, hits.count)
        let nextStart = min(pageStart + window.limit, hits.count)
        shortQueryContinuation = ShortQueryContinuation(
            tokenLower: tokenLower,
            filters: filters,
            mutationSeq: mutationSeq,
            nextOffset: window.offset + window.limit,
            hits: Array(hits[nextStart...]),
            position: position
        )
        return try fetchPage(hits[pageStart...].map(\.id)[...], window: window)
    }

    /// Appends the hits of whole (pinned, last used) groups after `position` until `hits` holds
    /// `count` and the next row starts another group, and returns where the scan stopped. Only
    /// visited rows' text is read, in the scan's read transaction.
    private func scanNewest(
        _ matcher: ShortQueryMatcher,
        after position: RecencyScanPosition,
        candidateIDStrings: [String]?,
        filters: Filters,
        until count: Int,
        into hits: inout [SearchRankKey]
    ) throws -> RecencyScanPosition {
        var keyset = ""
        switch position {
        case .start: break
        case .after: keyset = " AND (is_pinned, last_used_at) < (?, ?)"
        case .end: return .end
        }
        var params: [String] = []
        let order = try prepare(
            candidateRowsSQL(candidateIDStrings: candidateIDStrings, filters: filters, keyset: keyset, params: &params)
        )
        defer { order.reset() }
        var firstParam: Int32 = 1
        if case .after(let isPinned, let lastUsedAt) = position {
            try order.bindInt(isPinned ? 1 : 0, at: 1)
            try order.bindDouble(lastUsedAt, at: 2)
            firstParam = 3
        }
        try Self.bind(params, to: order, from: firstParam)
        let text = try prepare("SELECT plain_text, note FROM clipboard_items WHERE rowid = ?")
        defer { text.reset() }

        var group: (isPinned: Bool, lastUsedAt: Double)?
        while try order.step() {
            try Task.checkCancellation()
            let isPinned = order.columnInt(2) != 0
            let lastUsedAt = order.columnDouble(3)
            // Every row of a group is scored: the score orders rows used at the same time.
            if hits.count >= count, let group, group != (isPinned, lastUsedAt) {
                return .after(isPinned: group.isPinned, lastUsedAt: group.lastUsedAt)
            }
            group = (isPinned, lastUsedAt)

            text.reset()
            try text.bindInt64(order.columnInt64(0), at: 1)
            guard try text.step(), let idString = order.columnText(1), let id = UUID(uuidString: idString),
                  let score = matcher.score(text, plainColumn: 0, noteColumn: 1) else { continue }
            hits.append(SearchRankKey(
                isPinned: isPinned,
                lastUsedAt: Date(timeIntervalSince1970: lastUsedAt),
                score: score,
                id: id
            ))
        }
        return .end
    }

    /// One short query's byte matcher and its `String` fallback, as the full index scores it.
    private struct ShortQueryMatcher {
        enum PrefixVerdict {
            case score(Int)
            case scoreAtMost(Int)
        }

        /// How much of a plain text `prefixVerdict` reads first.
        static let prefixBytes = 4096

        let scorer: FuzzyMatcher.Scorer
        let matcher: LoweredTextMatcher?
        let baseScore: Int
        /// The most lowered UTF-16 units a match spans: its canonical decomposition's.
        private let maxMatchUnits: Int

        init(tokenLower: String) {
            scorer = FuzzyMatcher.Scorer(queryLower: tokenLower, mode: .fuzzy)
            matcher = FuzzyMatcher.prepare(queryLower: tokenLower).substringMatcher
            let needleUnits = tokenLower.utf16.count
            baseScore = needleUnits * 10 - (needleUnits - 1)
            maxMatchUnits = tokenLower.decomposedStringWithCanonicalMapping.utf16.count
        }

        /// The row's score when the leading bytes of its plain text decide it, else the best score
        /// it can still have. The bytes are cut between two ASCII characters (not after a carriage
        /// return), where no character spans the cut, so a hit before it is the text's first.
        func prefixVerdict(_ bytes: UnsafeBufferPointer<UInt8>, isWholeValue: Bool) -> PrefixVerdict {
            guard let matcher, let prefix = Self.decidablePrefix(bytes, isWholeValue: isWholeValue) else {
                return .scoreAtMost(baseScore)
            }
            switch matcher.firstMatch(in: prefix) {
            case .hit(let offset):
                return .score(baseScore - offset)
            case .undecided:
                return .scoreAtMost(baseScore)
            case .miss:
                // A match the prefix misses starts at most `maxMatchUnits` before its end; a note
                // match starts after the whole plain text.
                guard let units = LoweredTextMatcher.loweredUTF16Length(of: prefix) else { return .scoreAtMost(baseScore) }
                return .scoreAtMost(baseScore - max(0, units - maxMatchUnits))
            }
        }

        private static func decidablePrefix(_ bytes: UnsafeBufferPointer<UInt8>, isWholeValue: Bool) -> UnsafeBufferPointer<UInt8>? {
            if isWholeValue { return bytes }
            var end = bytes.count - 1
            while end > 0 {
                if bytes[end] < 0x80, bytes[end - 1] < 0x80, bytes[end - 1] != 0x0D {
                    return UnsafeBufferPointer(rebasing: bytes[..<end])
                }
                end -= 1
            }
            return nil
        }

        /// The row's score for `plain + "\n" + note`, or nil when it does not match.
        func score(_ row: SQLiteStatement, plainColumn: Int32, noteColumn: Int32) -> Int? {
            switch matcher.map({
                SearchReadStore.combinedMatch(
                    $0,
                    plain: SearchReadStore.bytes(row.columnTextBytes(plainColumn)),
                    note: SearchReadStore.bytes(row.columnTextBytes(noteColumn))
                )
            }) {
            case .hit(let offset):
                return baseScore - offset
            case .miss:
                return nil
            case .undecided, nil:
                var combined = row.columnText(plainColumn) ?? ""
                if let note = row.columnText(noteColumn), !note.isEmpty {
                    combined.append("\n")
                    combined.append(note)
                }
                return scorer.score(textLower: combined.lowercased())
            }
        }
    }

    /// The matcher's verdict on `plain + "\n" + note`, as the scorer joins them, without joining.
    private static func combinedMatch(
        _ matcher: LoweredTextMatcher,
        plain: UnsafeBufferPointer<UInt8>,
        note: UnsafeBufferPointer<UInt8>
    ) -> LoweredTextMatcher.Outcome {
        let plainOutcome = matcher.firstMatch(in: plain)
        guard plainOutcome == .miss, !note.isEmpty else { return plainOutcome }
        let noteOutcome = matcher.firstMatch(in: note)
        guard case .hit(let offset) = noteOutcome else { return noteOutcome }
        guard let plainUnits = LoweredTextMatcher.loweredUTF16Length(of: plain) else { return .undecided }
        return .hit(utf16Offset: plainUnits + 1 + offset)
    }

    private static func bytes(_ column: (ptr: UnsafePointer<UInt8>, length: Int)?) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: column?.ptr, count: column?.length ?? 0)
    }

    /// One row's plain text and note as SQLite bytes; a field is decoded and lowercased only for a
    /// token the byte matcher leaves undecided.
    private struct LoweredRowText {
        let plain: UnsafeBufferPointer<UInt8>
        let note: UnsafeBufferPointer<UInt8>
        private var plainLower: String?
        private var noteLower: String?

        init(plain: UnsafeBufferPointer<UInt8>, note: UnsafeBufferPointer<UInt8>) {
            self.plain = plain
            self.note = note
        }

        /// The token's first `String.range(of:)` hit in the lowercased field, as a UTF-16 offset.
        mutating func firstOffset(of token: String, matcher: LoweredTextMatcher?, inNote: Bool) -> Int? {
            switch matcher?.firstMatch(in: inNote ? note : plain) {
            case .hit(let offset): return offset
            case .miss: return nil
            case .undecided, nil: break
            }
            let text = inNote ? Self.lowered(note, cache: &noteLower) : Self.lowered(plain, cache: &plainLower)
            return FuzzyMatcher.firstOffset(of: token, in: text, matcher: nil)
        }

        private static func lowered(_ bytes: UnsafeBufferPointer<UInt8>, cache: inout String?) -> String {
            if let cache { return cache }
            let text = String(decoding: bytes, as: UTF8.self).lowercased()
            cache = text
            return text
        }
    }

    private func rankedPage(_ hits: [SearchRankKey], window: PageWindow) throws -> Page {
        try fetchPage(hits.dropFirst(window.offset).map(\.id)[...], window: window)
    }

    /// Fetches the window's rows; one more id than the window decides `hasMore`. The scan decided the
    /// window, so a row deleted before this fetch shortens the page without ending pagination.
    private func fetchPage(_ ids: ArraySlice<UUID>, window: PageWindow) throws -> Page {
        let hasMore = ids.count > window.limit
        let items = try fetchItemsByIDs(Array(ids.prefix(window.limit)))
        return Page(items: items, total: hasMore ? -1 : window.offset + items.count, hasMore: hasMore)
    }

    // MARK: - Index scans (a private connection each, off the engine actor)

    /// Every row's short-index fields; `nil` when the task is cancelled or the scan fails. A row
    /// that cannot be decoded fails the scan: an index missing rows must not pass as complete.
    static func loadShortQueryIndex(dbPath: String, reserveSlots: Int) -> ShortQueryIndexSnapshot? {
        guard let conn = try? openConnection(dbPath: dbPath) else { return nil }
        defer { conn.close() }

        do {
            return try withReadSnapshot(connection: conn) { mutationSeq in
                var index = ShortQueryIndex(reserveSlots: reserveSlots)
                let stmt = try conn.prepare("SELECT id, type, content_hash, plain_text, note FROM clipboard_items")
                defer { stmt.reset() }
                var row = 0
                while try stmt.step() {
                    if row % 256 == 0 { try Task.checkCancellation() }
                    row += 1

                    guard let idString = stmt.columnText(0),
                          let id = UUID(uuidString: idString),
                          let typeRaw = stmt.columnText(1),
                          let type = ClipboardItemType(rawValue: typeRaw) else {
                        throw ClipboardItemRow.DecodeError.invalidRow
                    }
                    index.upsert(
                        id: id,
                        type: type,
                        contentHash: stmt.columnText(2) ?? "",
                        plainText: stmt.columnText(3) ?? "",
                        note: stmt.columnText(4)
                    )
                }
                try Task.checkCancellation()
                return ShortQueryIndexSnapshot(index: index, source: .database, mutationSeq: mutationSeq)
            }
        } catch {
            if !Task.isCancelled, !(error is CancellationError) { logScanFailure("short", error) }
            return nil
        }
    }

    /// Every row's summary and its SQLite position, from one read transaction. A decode or
    /// cancellation failure cannot publish an index with missing rows as a complete snapshot.
    static func loadFullIndex(dbPath: String, reserveSlots: Int) -> FullIndexSnapshot? {
        guard let conn = try? openConnection(dbPath: dbPath) else { return nil }
        defer { conn.close() }

        do {
            return try withReadSnapshot(connection: conn) { mutationSeq in
                let index = try buildFullIndex(connection: conn, reserveSlots: reserveSlots)
                return FullIndexSnapshot(index: index, source: .database, mutationSeq: mutationSeq)
            }
        } catch {
            if !Task.isCancelled, !(error is CancellationError) { logScanFailure("full", error) }
            return nil
        }
    }

    /// Called inside the query's existing transaction when a bounded journal cannot advance a
    /// detached snapshot. The same scan also supplies ordinary background index builds.
    func buildFullIndex() throws -> FullFuzzyIndex {
        guard let connection else { throw SearchEngineImpl.SearchError.databaseNotOpen }
        return try Self.buildFullIndex(connection: connection, reserveSlots: 0)
    }

    private static func buildFullIndex(connection: SQLiteConnection, reserveSlots: Int) throws -> FullFuzzyIndex {
        var index = FullFuzzyIndex(reserveSlots: reserveSlots)
        let stmt = try connection.prepare("SELECT \(ClipboardItemRow.summaryColumns) FROM clipboard_items")
        defer { stmt.reset() }
        var row = 0
        while try stmt.step() {
            if row % 512 == 0 { try Task.checkCancellation() }
            row += 1
            index.append(IndexedItem(from: try ClipboardItemRow.decodeSummary(stmt)))
        }
        try Task.checkCancellation()
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

    private static func trigramCanMatch(_ tokens: [String]) -> Bool {
        !tokens.isEmpty && tokens.allSatisfy { $0.count >= 3 }
    }

    /// Each non-empty token as a quoted phrase, joined with `AND`.
    private static func trigramFTSQuery(tokens: [String]) -> String {
        tokens.map { token in
            var forms = [token]
            for form in [token.precomposedStringWithCanonicalMapping, token.decomposedStringWithCanonicalMapping]
            where !forms.contains(where: { $0.unicodeScalars.elementsEqual(form.unicodeScalars) }) {
                forms.append(form)
            }
            let phrases = forms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            return phrases.count == 1 ? phrases[0] : "(" + phrases.joined(separator: " OR ") + ")"
        }
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

    private static func bind(_ params: [String], to stmt: SQLiteStatement, from first: Int32 = 1) throws {
        var bindIndex = first
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
