import SQLite3
import XCTest
@testable import ScopyKit

/// Locks the ordered ids, `total`, and `hasMore` that every SQL search path returns, across sort
/// modes, filters, and paging, on a fixed fixture: CJK text, notes, pinned rows, three apps,
/// every item type, and `last_used_at` ties that fall back to the id order.
final class SearchSQLGoldenTests: XCTestCase {
    private struct Row {
        let number: Int
        let text: String
        var note: String?
        let app: String
        let type: ClipboardItemType
        let t: TimeInterval
        var pinned = false
    }

    private static let rows: [Row] = [
        Row(number: 1, text: "alpha one", app: "com.a", type: .text, t: 100),
        Row(number: 2, text: "ALPHA two with alphabet", app: "com.b", type: .rtf, t: 200),
        Row(number: 3, text: "beta alpha", note: "note alpha", app: "com.c", type: .html, t: 300),
        Row(number: 4, text: "pinned alpha", app: "com.a", type: .text, t: 50, pinned: true),
        Row(number: 5, text: "abc image", app: "com.b", type: .image, t: 150),
        Row(number: 6, text: "file path ab/alpha.txt", app: "com.c", type: .file, t: 250),
        Row(number: 7, text: "other thing", note: "ab alpha in note", app: "com.a", type: .other, t: 350),
        Row(number: 8, text: "学习数学公式推导", app: "com.a", type: .text, t: 120),
        Row(number: 9, text: "复习数学和公式", app: "com.b", type: .rtf, t: 220),
        Row(number: 10, text: "随便写写", note: "笔记里有数学公式", app: "com.c", type: .html, t: 320),
        Row(number: 11, text: "置顶的数学公式", app: "com.b", type: .text, t: 20, pinned: true),
        Row(number: 12, text: "xyzab zz", app: "com.c", type: .text, t: 400),
        Row(number: 13, text: "same time alpha a", app: "com.a", type: .text, t: 200),
        Row(number: 14, text: "same time alpha b", app: "com.a", type: .rtf, t: 200),
        Row(number: 15, text: "Ab mixed case one", app: "com.b", type: .html, t: 180),
        Row(number: 16, text: "数", app: "com.c", type: .text, t: 10),
    ]

    // Recent-sort (pinned, last used) groups that straddle page boundaries, with different "ab"
    // scores inside each group: the best row is read last at t = 300 and first at t = 200.
    private static let sameTimeRows: [Row] = [
        Row(number: 1, text: "xxab", app: "com.a", type: .text, t: 300),
        Row(number: 2, text: "xab", app: "com.a", type: .text, t: 300),
        Row(number: 3, text: "ab best", app: "com.a", type: .text, t: 300),
        Row(number: 4, text: "ab pinned", app: "com.a", type: .text, t: 10, pinned: true),
        Row(number: 5, text: "ab best", app: "com.a", type: .text, t: 200),
        Row(number: 6, text: "xxab", app: "com.a", type: .text, t: 200),
        Row(number: 7, text: "zzz", app: "com.a", type: .text, t: 250),
        Row(number: 8, text: "xab", app: "com.a", type: .text, t: 200),
        Row(number: 9, text: "xab", app: "com.a", type: .text, t: 100),
        Row(number: 10, text: "ab x", app: "com.a", type: .text, t: 100),
        Row(number: 11, text: "zz", note: "ab in the note", app: "com.a", type: .text, t: 50),
    ]
    private static let sameTimeRecentOrder = [4, 3, 2, 1, 5, 8, 6, 10, 9, 11]

    // Plain texts around the 4 KB prefix that the short-query path reads first: an "ab" score is
    // 19 minus the first match's UTF-16 offset in `plain + "\n" + note`.
    private static let prefixRows: [Row] = [
        Row(number: 1, text: "ab start", app: "com.a", type: .text, t: 100),
        Row(number: 2, text: String(repeating: "x", count: 5000) + "ab", app: "com.a", type: .text, t: 200),
        // The match spans the 4096-byte cut.
        Row(number: 3, text: String(repeating: "x", count: 4095) + "ab", app: "com.b", type: .text, t: 300),
        // Multibyte characters before the cut: it moves back to two ASCII bytes.
        Row(number: 4, text: String(repeating: "x", count: 4090) + "ééé" + "ab", app: "com.a", type: .text, t: 350),
        Row(number: 5, text: String(repeating: "x", count: 5000), note: "ab", app: "com.a", type: .text, t: 150),
        // No two ASCII bytes in the first 4 KB to cut between.
        Row(number: 6, text: String(repeating: "数", count: 2000) + "ab", app: "com.b", type: .text, t: 250),
        Row(number: 7, text: String(repeating: "x", count: 6000) + "ab", app: "com.a", type: .text, t: 50, pinned: true),
        Row(number: 8, text: "xab", app: "com.a", type: .text, t: 120),
        Row(number: 9, text: "xxab", app: "com.b", type: .text, t: 130),
        Row(number: 10, text: "zzz", app: "com.a", type: .text, t: 400),
        // "é" queries: a combining mark right after the cut, a match spanning it, decomposed forms.
        Row(number: 11, text: String(repeating: "x", count: 4094) + "é\u{323} é", app: "com.b", type: .text, t: 410),
        Row(number: 12, text: String(repeating: "x", count: 4095) + "é", app: "com.a", type: .text, t: 420),
        Row(number: 13, text: String(repeating: "x", count: 5000) + "e\u{301}", app: "com.a", type: .text, t: 430),
        Row(number: 14, text: "é first", app: "com.a", type: .text, t: 440),
        // A hit late in the prefix, and a row the prefix leaves undecided that outranks it.
        Row(number: 15, text: String(repeating: "x", count: 3999) + "ab", app: "com.a", type: .text, t: 460),
        Row(
            number: 16,
            text: String(repeating: "数", count: 1300) + "xx" + String(repeating: "数", count: 60) + "ab"
                + String(repeating: "数", count: 10),
            app: "com.b",
            type: .text,
            t: 470
        ),
    ]
    private static let prefixRelevanceOrder = [7, 1, 8, 9, 16, 6, 15, 4, 3, 2, 5]

    private struct Filter {
        let label: String
        var app: String?
        var type: ClipboardItemType?
        var types: Set<ClipboardItemType>?
    }

    private static let filters: [Filter] = [
        Filter(label: "-"),
        Filter(label: "app=com.a", app: "com.a"),
        Filter(label: "type=text", type: .text),
        Filter(label: "types=rtf,html", types: [.rtf, .html]),
        // `typeFilters` wins over `typeFilter`.
        Filter(label: "app=com.b type=image types=text,rtf", app: "com.b", type: .image, types: [.text, .rtf]),
    ]

    private static func uuid(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012X", number))!
    }

    private static func number(_ id: UUID) -> String {
        String(Int(id.uuidString.suffix(12), radix: 16) ?? -1)
    }

    func testEverySQLPathMatchesGolden() async throws {
        let dbPath = try makeFixtureDatabase()
        var lines: [String] = []

        // Empty, exact, regex, and forced fuzzy+ queries run on SQL paths that never consult
        // the in-memory indexes: listing, FTS, trigram and instr substring, the recent cache.
        let sqlEngine = SearchEngineImpl(dbPath: dbPath)
        try await sqlEngine.open()
        for (mode, query, force) in [
            (SearchMode.exact, "", false),
            (.fuzzy, "", false),
            (.exact, "alpha", false),
            (.exact, "Alpha One", false),
            (.exact, "数学公式", false),
            (.exact, "数学 公式", false),
            (.exact, "ab", false),
            (.regex, "al.ha", false),
            (.fuzzyPlus, "alpha", true),
            (.fuzzyPlus, "alpha one", true),
        ] {
            lines += try await record(sqlEngine, group: "sql", mode: mode, query: query, force: force)
        }
        await sqlEngine.close()

        // Short fuzzy queries before any index exists scan the table.
        let scanEngine = SearchEngineImpl(dbPath: dbPath)
        try await scanEngine.open()
        for (mode, query) in [(SearchMode.fuzzy, "ab"), (.fuzzy, "数"), (.fuzzy, "数学"), (.fuzzyPlus, "ab")] {
            lines += try await record(scanEngine, group: "scan", mode: mode, query: query)
        }
        await scanEngine.close()

        #if DEBUG
        // With the short index built, ASCII and safe non-ASCII bigram candidates share the
        // Swift matcher; a single non-ASCII character still scans.
        let shortEngine = SearchEngineImpl(dbPath: dbPath)
        try await shortEngine.open()
        await shortEngine.debugStartShortQueryIndexBuild(force: true)
        await shortEngine.debugAwaitShortQueryIndexBuild()
        let shortHealth = await shortEngine.debugShortQueryIndexHealth()
        XCTAssertTrue(shortHealth.isBuilt)
        for query in ["ab", "数学", "数"] {
            lines += try await record(shortEngine, group: "short", mode: .fuzzy, query: query)
        }
        await shortEngine.close()
        #endif

        // Longer fuzzy queries rank in the full index and fetch the page's rows by id.
        let fullEngine = SearchEngineImpl(dbPath: dbPath)
        try await fullEngine.open()
        for (mode, query) in [(SearchMode.fuzzy, "alpha"), (.fuzzyPlus, "alpha"), (.fuzzy, "数学公式")] {
            lines += try await record(fullEngine, group: "full", mode: mode, query: query)
        }
        await fullEngine.close()

        let actual = lines.joined(separator: "\n")
        XCTAssertEqual(actual, Self.golden, "Actual:\n\(actual)")
    }

    func testRecentShortQueryPagesKeepSameTimeRowsInScoreOrder() async throws {
        let dbPath = try makeFixtureDatabase(Self.sameTimeRows)

        let scanEngine = SearchEngineImpl(dbPath: dbPath)
        try await scanEngine.open()
        try await assertRecentWindows(scanEngine, path: "scan")
        await scanEngine.close()

        #if DEBUG
        let shortEngine = SearchEngineImpl(dbPath: dbPath)
        try await shortEngine.open()
        await shortEngine.debugStartShortQueryIndexBuild(force: true)
        await shortEngine.debugAwaitShortQueryIndexBuild()
        let shortHealth = await shortEngine.debugShortQueryIndexHealth()
        XCTAssertTrue(shortHealth.isBuilt)
        try await assertRecentWindows(shortEngine, path: "short")
        await shortEngine.close()
        #endif

        // A longer query builds the full index, which then serves the short query.
        let fullEngine = SearchEngineImpl(dbPath: dbPath)
        try await fullEngine.open()
        _ = try await fullEngine.search(request: SearchRequest(query: "abc", mode: .fuzzy))
        #if DEBUG
        let fullHealth = await fullEngine.debugFullIndexHealth()
        XCTAssertTrue(fullHealth.isBuilt)
        #endif
        try await assertRecentWindows(fullEngine, path: "full")
        await fullEngine.close()
    }

    func testRelevanceShortQueryPagesAgreeAcrossThePrefixCut() async throws {
        let dbPath = try makeFixtureDatabase(Self.prefixRows)
        var engines: [(String, SearchEngineImpl)] = []
        let scanEngine = SearchEngineImpl(dbPath: dbPath)
        try await scanEngine.open()
        engines.append(("scan", scanEngine))
        #if DEBUG
        let shortEngine = SearchEngineImpl(dbPath: dbPath)
        try await shortEngine.open()
        await shortEngine.debugStartShortQueryIndexBuild(force: true)
        await shortEngine.debugAwaitShortQueryIndexBuild()
        let shortHealth = await shortEngine.debugShortQueryIndexHealth()
        XCTAssertTrue(shortHealth.isBuilt)
        engines.append(("short", shortEngine))
        #endif
        // A full pass builds the full index, which then serves the short queries.
        let fullEngine = SearchEngineImpl(dbPath: dbPath)
        try await fullEngine.open()
        _ = try await fullEngine.search(request: SearchRequest(query: "abc", mode: .fuzzy, forceFullFuzzy: true))
        #if DEBUG
        let fullHealth = await fullEngine.debugFullIndexHealth()
        XCTAssertTrue(fullHealth.isBuilt)
        #endif
        engines.append(("full", fullEngine))

        // The full index's String scorer is every path's reference, on every window and filter.
        var reference: [String: [String]] = [:]
        for (path, engine) in engines.reversed() {
            for query in ["ab", "é"] {
                var pages: [String] = []
                for limit in 1...3 {
                    for offset in 0...Self.prefixRows.count {
                        let result = try await engine.search(
                            request: SearchRequest(query: query, mode: .fuzzy, sortMode: .relevance, limit: limit, offset: offset)
                        )
                        let ids = result.items.map { Self.number($0.id) }.joined(separator: ",")
                        pages.append("\(query) limit \(limit) offset \(offset): [\(ids)] more=\(result.hasMore)")
                    }
                }
                for app in ["com.a", "com.b"] {
                    let result = try await engine.search(
                        request: SearchRequest(query: query, mode: .fuzzy, sortMode: .relevance, appFilter: app, limit: 50)
                    )
                    pages.append("\(query) \(app): [\(result.items.map { Self.number($0.id) }.joined(separator: ","))]")
                }
                if let expected = reference[query] {
                    XCTAssertEqual(pages, expected, "\(path) \(query)")
                } else {
                    reference[query] = pages
                }
            }
            await engine.close()
        }

        // And "ab" against the order its scores give.
        let order = Self.prefixRelevanceOrder
        func ids(_ numbers: some Sequence<Int>) -> String { numbers.map(String.init).joined(separator: ",") }
        var expected: [String] = []
        for limit in 1...3 {
            for offset in 0...Self.prefixRows.count {
                expected.append("ab limit \(limit) offset \(offset): [\(ids(order.dropFirst(offset).prefix(limit)))] more=\(offset + limit < order.count)")
            }
        }
        for app in ["com.a", "com.b"] {
            expected.append("ab \(app): [\(ids(order.filter { Self.prefixRows[$0 - 1].app == app }))]")
        }
        XCTAssertEqual(reference["ab"], expected)
    }

    func testRecentShortQueryNextPageRestartsAfterACommit() async throws {
        let dbPath = try makeFixtureDatabase(Self.sameTimeRows)
        let engine = SearchEngineImpl(dbPath: dbPath)
        try await engine.open()
        func page(offset: Int) async throws -> [String] {
            try await engine.search(
                request: SearchRequest(query: "ab", mode: .fuzzy, sortMode: .recent, limit: 2, offset: offset)
            ).items.map { Self.number($0.id) }
        }

        let first = try await page(offset: 0)
        XCTAssertEqual(first, ["4", "3"])
        // Row 11, the oldest hit, is used again and becomes the newest unpinned row.
        let writer = try SQLiteConnection(path: dbPath, flags: SQLITE_OPEN_READWRITE)
        try writer.execute("UPDATE clipboard_items SET last_used_at = 1000 WHERE id = '\(Self.uuid(11).uuidString)'")
        try writer.execute("UPDATE scopy_meta SET mutation_seq = mutation_seq + 1 WHERE id = 1")
        writer.close()
        let second = try await page(offset: 2)
        XCTAssertEqual(second, ["3", "2"], "the next page must come from the committed order")
        await engine.close()
    }

    // ASCII words that the short index's bigrams narrow, beside what a substring of whole
    // characters must not lose to them: canonical stand-ins for ";" (U+037E), "`" (U+1FEF) and "K"
    // (the Kelvin sign), combining marks, joiners, ignorables, ligatures and CR LF. A lone ";" or
    // "`" lets a row with only the stand-in pass the full index's character filter.
    private static let bigramPieces = [
        "config", "CONFIG", "con", "fig", "Con fig", "co;nf", "co\u{37E}nf", "a`b", "a\u{1FEF}b",
        "\u{212A}ey", "key", "KEY", "ke\u{301}y", "k\u{200D}ey", "ke\u{AD}y", "e\u{200B}y", "c\u{307}on",
        "\u{130}on", "\u{FB01}g", "\r\n", " ", "-", "x", "ion", "数据", ";", "`",
    ]

    func testFuzzyPlusFullIndexFindsTheSameRowsThroughTheShortIndexBigrams() async throws {
        #if DEBUG
        var state: UInt64 = 1
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        func piece() -> String { Self.bigramPieces[next(Self.bigramPieces.count)] }
        let rows = (1...400).map { number in
            Row(
                number: number,
                text: (0..<next(12)).map { _ in piece() }.joined(),
                note: next(4) == 0 ? piece() + piece() : nil,
                app: "com.a",
                type: .text,
                t: TimeInterval(next(40))
            )
        }
        let dbPath = try makeFixtureDatabase(rows)

        // Below the short index's corpus size, only a forced build creates it.
        let plainEngine = SearchEngineImpl(dbPath: dbPath)
        try await plainEngine.open()
        let bigramEngine = SearchEngineImpl(dbPath: dbPath)
        try await bigramEngine.open()
        await bigramEngine.debugStartShortQueryIndexBuild(force: true)
        await bigramEngine.debugAwaitShortQueryIndexBuild()
        let plainHealth = await plainEngine.debugShortQueryIndexHealth()
        let bigramHealth = await bigramEngine.debugShortQueryIndexHealth()
        XCTAssertFalse(plainHealth.isBuilt)
        XCTAssertTrue(bigramHealth.isBuilt)

        let queries = [
            "config", "con", "fig", "onf", "nfi", "co;nf", "o;n", "a`b", "key", "ion", "con fig", "fig con",
            "a key", "co fig", "数据 config", "x con",
        ]
        var matchedQueries = 0
        // Fuzzy mode and fuzzy+ words under three characters match as subsequences: no bigram applies.
        for mode in [SearchMode.fuzzyPlus, .fuzzy] {
            for query in queries {
                for sortMode in [SearchSortMode.relevance, .recent] {
                    let request = SearchRequest(query: query, mode: mode, sortMode: sortMode, limit: 500, offset: 0)
                    let label = "\(mode) \"\(query)\" \(sortMode)"
                    let plain = try await plainEngine.search(request: request)
                    let narrowed = try await bigramEngine.search(request: request)
                    XCTAssertEqual(narrowed.items.map(\.id), plain.items.map(\.id), label)
                    XCTAssertEqual(narrowed.total, plain.total, label)
                    XCTAssertEqual(narrowed.hasMore, plain.hasMore, label)
                    if !plain.items.isEmpty { matchedQueries += 1 }
                }
            }
        }
        XCTAssertGreaterThan(matchedQueries, 2 * queries.count)
        await plainEngine.close()
        await bigramEngine.close()
        #endif
    }

    /// Every window, in deepening order, has the reference order's rows, `hasMore`, and a total that
    /// is exact on the last page and otherwise exact or unknown.
    private func assertRecentWindows(_ engine: SearchEngineImpl, path: String) async throws {
        let expected = Self.sameTimeRecentOrder
        for limit in 1...3 {
            for offset in 0..<expected.count {
                let result = try await engine.search(
                    request: SearchRequest(query: "ab", mode: .fuzzy, sortMode: .recent, limit: limit, offset: offset)
                )
                let window = "\(path) limit \(limit) offset \(offset)"
                XCTAssertEqual(
                    result.items.map { Self.number($0.id) },
                    expected.dropFirst(offset).prefix(limit).map(String.init),
                    window
                )
                XCTAssertEqual(result.hasMore, offset + limit < expected.count, window)
                if result.hasMore {
                    XCTAssertTrue([-1, expected.count].contains(result.total), window)
                } else {
                    XCTAssertEqual(result.total, expected.count, window)
                }
            }
        }
    }

    private func record(
        _ engine: SearchEngineImpl,
        group: String,
        mode: SearchMode,
        query: String,
        force: Bool = false
    ) async throws -> [String] {
        var lines: [String] = []
        for sort in [SearchSortMode.relevance, .recent] {
            for filter in Self.filters {
                var windows: [String] = []
                for (limit, offset) in [(50, 0), (2, 1)] {
                    let result = try await engine.search(
                        request: SearchRequest(
                            query: query,
                            mode: mode,
                            sortMode: sort,
                            appFilter: filter.app,
                            typeFilter: filter.type,
                            typeFilters: filter.types,
                            forceFullFuzzy: force,
                            limit: limit,
                            offset: offset
                        )
                    )
                    let ids = result.items.map { Self.number($0.id) }.joined(separator: ",")
                    windows.append("[\(ids)] total=\(result.total) more=\(result.hasMore ? 1 : 0)")
                }
                lines.append("\(group) \(mode) \(sort) \"\(query)\" \(filter.label) => \(windows.joined(separator: " | "))")
            }
        }
        return lines
    }

    private func makeFixtureDatabase(_ rows: [Row] = SearchSQLGoldenTests.rows) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-sql-golden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clipboard.db").path

        let connection = try SQLiteConnection(path: path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        defer { connection.close() }
        try SQLiteMigrations.migrateIfNeeded(connection)

        do {
            let insert = try connection.prepare(
                """
                INSERT INTO clipboard_items
                    (id, type, content_hash, plain_text, note, app_bundle_id, created_at, last_used_at,
                     use_count, is_pinned, size_bytes)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                """
            )
            for row in rows {
                insert.reset()
                try insert.bindText(Self.uuid(row.number).uuidString, at: 1)
                try insert.bindText(row.type.rawValue, at: 2)
                try insert.bindText("hash-\(row.number)", at: 3)
                try insert.bindText(row.text, at: 4)
                try insert.bindText(row.note, at: 5)
                try insert.bindText(row.app, at: 6)
                try insert.bindDouble(row.t, at: 7)
                try insert.bindDouble(row.t, at: 8)
                try insert.bindInt(row.pinned ? 1 : 0, at: 9)
                try insert.bindInt(row.text.utf8.count, at: 10)
                XCTAssertFalse(try insert.step())
            }
        }
        return path
    }

    private static let golden = """
    sql exact relevance "" - => [4,11,12,7,10,3,6,9,2,13,14,15,5,8,1,16] total=16 more=0 | [11,12] total=-1 more=1
    sql exact relevance "" app=com.a => [4,7,13,14,8,1] total=6 more=0 | [7,13] total=-1 more=1
    sql exact relevance "" type=text => [4,11,12,13,8,1,16] total=7 more=0 | [11,12] total=-1 more=1
    sql exact relevance "" types=rtf,html => [10,3,9,2,14,15] total=6 more=0 | [3,9] total=-1 more=1
    sql exact relevance "" app=com.b type=image types=text,rtf => [11,9,2] total=3 more=0 | [9,2] total=3 more=0
    sql exact recent "" - => [4,11,12,7,10,3,6,9,2,13,14,15,5,8,1,16] total=16 more=0 | [11,12] total=-1 more=1
    sql exact recent "" app=com.a => [4,7,13,14,8,1] total=6 more=0 | [7,13] total=-1 more=1
    sql exact recent "" type=text => [4,11,12,13,8,1,16] total=7 more=0 | [11,12] total=-1 more=1
    sql exact recent "" types=rtf,html => [10,3,9,2,14,15] total=6 more=0 | [3,9] total=-1 more=1
    sql exact recent "" app=com.b type=image types=text,rtf => [11,9,2] total=3 more=0 | [9,2] total=3 more=0
    sql fuzzy relevance "" - => [4,11,12,7,10,3,6,9,2,13,14,15,5,8,1,16] total=16 more=0 | [11,12] total=-1 more=1
    sql fuzzy relevance "" app=com.a => [4,7,13,14,8,1] total=6 more=0 | [7,13] total=-1 more=1
    sql fuzzy relevance "" type=text => [4,11,12,13,8,1,16] total=7 more=0 | [11,12] total=-1 more=1
    sql fuzzy relevance "" types=rtf,html => [10,3,9,2,14,15] total=6 more=0 | [3,9] total=-1 more=1
    sql fuzzy relevance "" app=com.b type=image types=text,rtf => [11,9,2] total=3 more=0 | [9,2] total=3 more=0
    sql fuzzy recent "" - => [4,11,12,7,10,3,6,9,2,13,14,15,5,8,1,16] total=16 more=0 | [11,12] total=-1 more=1
    sql fuzzy recent "" app=com.a => [4,7,13,14,8,1] total=6 more=0 | [7,13] total=-1 more=1
    sql fuzzy recent "" type=text => [4,11,12,13,8,1,16] total=7 more=0 | [11,12] total=-1 more=1
    sql fuzzy recent "" types=rtf,html => [10,3,9,2,14,15] total=6 more=0 | [3,9] total=-1 more=1
    sql fuzzy recent "" app=com.b type=image types=text,rtf => [11,9,2] total=3 more=0 | [9,2] total=3 more=0
    sql exact relevance "alpha" - => [4,3,1,2,13,14,6,7] total=8 more=0 | [3,1] total=-1 more=1
    sql exact relevance "alpha" app=com.a => [4,1,13,14,7] total=5 more=0 | [1,13] total=-1 more=1
    sql exact relevance "alpha" type=text => [4,1,13] total=3 more=0 | [1,13] total=3 more=0
    sql exact relevance "alpha" types=rtf,html => [3,2,14] total=3 more=0 | [2,14] total=3 more=0
    sql exact relevance "alpha" app=com.b type=image types=text,rtf => [2] total=1 more=0 | [] total=1 more=0
    sql exact recent "alpha" - => [4,7,3,6,2,13,14,1] total=8 more=0 | [7,3] total=-1 more=1
    sql exact recent "alpha" app=com.a => [4,7,13,14,1] total=5 more=0 | [7,13] total=-1 more=1
    sql exact recent "alpha" type=text => [4,13,1] total=3 more=0 | [13,1] total=3 more=0
    sql exact recent "alpha" types=rtf,html => [3,2,14] total=3 more=0 | [2,14] total=3 more=0
    sql exact recent "alpha" app=com.b type=image types=text,rtf => [2] total=1 more=0 | [] total=1 more=0
    sql exact relevance "Alpha One" - => [1] total=1 more=0 | [] total=1 more=0
    sql exact relevance "Alpha One" app=com.a => [1] total=1 more=0 | [] total=1 more=0
    sql exact relevance "Alpha One" type=text => [1] total=1 more=0 | [] total=1 more=0
    sql exact relevance "Alpha One" types=rtf,html => [] total=0 more=0 | [] total=1 more=0
    sql exact relevance "Alpha One" app=com.b type=image types=text,rtf => [] total=0 more=0 | [] total=1 more=0
    sql exact recent "Alpha One" - => [1] total=1 more=0 | [] total=1 more=0
    sql exact recent "Alpha One" app=com.a => [1] total=1 more=0 | [] total=1 more=0
    sql exact recent "Alpha One" type=text => [1] total=1 more=0 | [] total=1 more=0
    sql exact recent "Alpha One" types=rtf,html => [] total=0 more=0 | [] total=1 more=0
    sql exact recent "Alpha One" app=com.b type=image types=text,rtf => [] total=0 more=0 | [] total=1 more=0
    sql exact relevance "数学公式" - => [11,8,10] total=3 more=0 | [8,10] total=3 more=0
    sql exact relevance "数学公式" app=com.a => [8] total=1 more=0 | [] total=1 more=0
    sql exact relevance "数学公式" type=text => [11,8] total=2 more=0 | [8] total=2 more=0
    sql exact relevance "数学公式" types=rtf,html => [10] total=1 more=0 | [] total=1 more=0
    sql exact relevance "数学公式" app=com.b type=image types=text,rtf => [11] total=1 more=0 | [] total=1 more=0
    sql exact recent "数学公式" - => [11,10,8] total=3 more=0 | [10,8] total=3 more=0
    sql exact recent "数学公式" app=com.a => [8] total=1 more=0 | [] total=1 more=0
    sql exact recent "数学公式" type=text => [11,8] total=2 more=0 | [8] total=2 more=0
    sql exact recent "数学公式" types=rtf,html => [10] total=1 more=0 | [] total=1 more=0
    sql exact recent "数学公式" app=com.b type=image types=text,rtf => [11] total=1 more=0 | [] total=1 more=0
    sql exact relevance "数学 公式" - => [11,9,8,10] total=4 more=0 | [9,8] total=-1 more=1
    sql exact relevance "数学 公式" app=com.a => [8] total=1 more=0 | [] total=1 more=0
    sql exact relevance "数学 公式" type=text => [11,8] total=2 more=0 | [8] total=2 more=0
    sql exact relevance "数学 公式" types=rtf,html => [9,10] total=2 more=0 | [10] total=2 more=0
    sql exact relevance "数学 公式" app=com.b type=image types=text,rtf => [11,9] total=2 more=0 | [9] total=2 more=0
    sql exact recent "数学 公式" - => [11,10,9,8] total=4 more=0 | [10,9] total=-1 more=1
    sql exact recent "数学 公式" app=com.a => [8] total=1 more=0 | [] total=1 more=0
    sql exact recent "数学 公式" type=text => [11,8] total=2 more=0 | [8] total=2 more=0
    sql exact recent "数学 公式" types=rtf,html => [10,9] total=2 more=0 | [9] total=2 more=0
    sql exact recent "数学 公式" app=com.b type=image types=text,rtf => [11,9] total=2 more=0 | [9] total=2 more=0
    sql exact relevance "ab" - => [12,7,6,2,15,5] total=6 more=0 | [7,6] total=-1 more=1
    sql exact relevance "ab" app=com.a => [7] total=1 more=0 | [] total=1 more=0
    sql exact relevance "ab" type=text => [12] total=1 more=0 | [] total=1 more=0
    sql exact relevance "ab" types=rtf,html => [2,15] total=2 more=0 | [15] total=2 more=0
    sql exact relevance "ab" app=com.b type=image types=text,rtf => [2] total=1 more=0 | [] total=1 more=0
    sql exact recent "ab" - => [12,7,6,2,15,5] total=6 more=0 | [7,6] total=-1 more=1
    sql exact recent "ab" app=com.a => [7] total=1 more=0 | [] total=1 more=0
    sql exact recent "ab" type=text => [12] total=1 more=0 | [] total=1 more=0
    sql exact recent "ab" types=rtf,html => [2,15] total=2 more=0 | [15] total=2 more=0
    sql exact recent "ab" app=com.b type=image types=text,rtf => [2] total=1 more=0 | [] total=1 more=0
    sql regex relevance "al.ha" - => [4,7,3,6,2,13,14,1] total=8 more=0 | [7,3] total=-1 more=1
    sql regex relevance "al.ha" app=com.a => [4,7,13,14,1] total=5 more=0 | [7,13] total=-1 more=1
    sql regex relevance "al.ha" type=text => [4,13,1] total=3 more=0 | [13,1] total=3 more=0
    sql regex relevance "al.ha" types=rtf,html => [3,2,14] total=3 more=0 | [2,14] total=3 more=0
    sql regex relevance "al.ha" app=com.b type=image types=text,rtf => [2] total=1 more=0 | [] total=1 more=0
    sql regex recent "al.ha" - => [4,7,3,6,2,13,14,1] total=8 more=0 | [7,3] total=-1 more=1
    sql regex recent "al.ha" app=com.a => [4,7,13,14,1] total=5 more=0 | [7,13] total=-1 more=1
    sql regex recent "al.ha" type=text => [4,13,1] total=3 more=0 | [13,1] total=3 more=0
    sql regex recent "al.ha" types=rtf,html => [3,2,14] total=3 more=0 | [2,14] total=3 more=0
    sql regex recent "al.ha" app=com.b type=image types=text,rtf => [2] total=1 more=0 | [] total=1 more=0
    sql fuzzyPlus relevance "alpha" - => [4,2,1,7,3,13,14,6] total=8 more=0 | [2,1] total=-1 more=1
    sql fuzzyPlus relevance "alpha" app=com.a => [4,1,7,13,14] total=5 more=0 | [1,7] total=-1 more=1
    sql fuzzyPlus relevance "alpha" type=text => [4,1,13] total=3 more=0 | [1,13] total=3 more=0
    sql fuzzyPlus relevance "alpha" types=rtf,html => [2,3,14] total=3 more=0 | [3,14] total=3 more=0
    sql fuzzyPlus relevance "alpha" app=com.b type=image types=text,rtf => [2] total=1 more=0 | [] total=1 more=0
    sql fuzzyPlus recent "alpha" - => [4,7,3,6,2,13,14,1] total=8 more=0 | [7,3] total=-1 more=1
    sql fuzzyPlus recent "alpha" app=com.a => [4,7,13,14,1] total=5 more=0 | [7,13] total=-1 more=1
    sql fuzzyPlus recent "alpha" type=text => [4,13,1] total=3 more=0 | [13,1] total=3 more=0
    sql fuzzyPlus recent "alpha" types=rtf,html => [3,2,14] total=3 more=0 | [2,14] total=3 more=0
    sql fuzzyPlus recent "alpha" app=com.b type=image types=text,rtf => [2] total=1 more=0 | [] total=1 more=0
    sql fuzzyPlus relevance "alpha one" - => [1] total=1 more=0 | [] total=1 more=0
    sql fuzzyPlus relevance "alpha one" app=com.a => [1] total=1 more=0 | [] total=1 more=0
    sql fuzzyPlus relevance "alpha one" type=text => [1] total=1 more=0 | [] total=1 more=0
    sql fuzzyPlus relevance "alpha one" types=rtf,html => [] total=0 more=0 | [] total=1 more=0
    sql fuzzyPlus relevance "alpha one" app=com.b type=image types=text,rtf => [] total=0 more=0 | [] total=1 more=0
    sql fuzzyPlus recent "alpha one" - => [1] total=1 more=0 | [] total=1 more=0
    sql fuzzyPlus recent "alpha one" app=com.a => [1] total=1 more=0 | [] total=1 more=0
    sql fuzzyPlus recent "alpha one" type=text => [1] total=1 more=0 | [] total=1 more=0
    sql fuzzyPlus recent "alpha one" types=rtf,html => [] total=0 more=0 | [] total=1 more=0
    sql fuzzyPlus recent "alpha one" app=com.b type=image types=text,rtf => [] total=0 more=0 | [] total=1 more=0
    scan fuzzy relevance "ab" - => [15,5,12,6,7,2] total=6 more=0 | [5,12] total=-1 more=1
    scan fuzzy relevance "ab" app=com.a => [7] total=1 more=0 | [] total=1 more=0
    scan fuzzy relevance "ab" type=text => [12] total=1 more=0 | [] total=1 more=0
    scan fuzzy relevance "ab" types=rtf,html => [15,2] total=2 more=0 | [2] total=2 more=0
    scan fuzzy relevance "ab" app=com.b type=image types=text,rtf => [2] total=1 more=0 | [] total=1 more=0
    scan fuzzy recent "ab" - => [12,7,6,2,15,5] total=6 more=0 | [7,6] total=-1 more=1
    scan fuzzy recent "ab" app=com.a => [7] total=1 more=0 | [] total=1 more=0
    scan fuzzy recent "ab" type=text => [12] total=1 more=0 | [] total=1 more=0
    scan fuzzy recent "ab" types=rtf,html => [2,15] total=2 more=0 | [15] total=2 more=0
    scan fuzzy recent "ab" app=com.b type=image types=text,rtf => [2] total=1 more=0 | [] total=1 more=0
    scan fuzzy relevance "数" - => [11,16,9,8,10] total=5 more=0 | [16,9] total=-1 more=1
    scan fuzzy relevance "数" app=com.a => [8] total=1 more=0 | [] total=1 more=0
    scan fuzzy relevance "数" type=text => [11,16,8] total=3 more=0 | [16,8] total=3 more=0
    scan fuzzy relevance "数" types=rtf,html => [9,10] total=2 more=0 | [10] total=2 more=0
    scan fuzzy relevance "数" app=com.b type=image types=text,rtf => [11,9] total=2 more=0 | [9] total=2 more=0
    scan fuzzy recent "数" - => [11,10,9,8,16] total=5 more=0 | [10,9] total=-1 more=1
    scan fuzzy recent "数" app=com.a => [8] total=1 more=0 | [] total=1 more=0
    scan fuzzy recent "数" type=text => [11,8,16] total=3 more=0 | [8,16] total=3 more=0
    scan fuzzy recent "数" types=rtf,html => [10,9] total=2 more=0 | [9] total=2 more=0
    scan fuzzy recent "数" app=com.b type=image types=text,rtf => [11,9] total=2 more=0 | [9] total=2 more=0
    scan fuzzy relevance "数学" - => [11,9,8,10] total=4 more=0 | [9,8] total=-1 more=1
    scan fuzzy relevance "数学" app=com.a => [8] total=1 more=0 | [] total=1 more=0
    scan fuzzy relevance "数学" type=text => [11,8] total=2 more=0 | [8] total=2 more=0
    scan fuzzy relevance "数学" types=rtf,html => [9,10] total=2 more=0 | [10] total=2 more=0
    scan fuzzy relevance "数学" app=com.b type=image types=text,rtf => [11,9] total=2 more=0 | [9] total=2 more=0
    scan fuzzy recent "数学" - => [11,10,9,8] total=4 more=0 | [10,9] total=-1 more=1
    scan fuzzy recent "数学" app=com.a => [8] total=1 more=0 | [] total=1 more=0
    scan fuzzy recent "数学" type=text => [11,8] total=2 more=0 | [8] total=2 more=0
    scan fuzzy recent "数学" types=rtf,html => [10,9] total=2 more=0 | [9] total=2 more=0
    scan fuzzy recent "数学" app=com.b type=image types=text,rtf => [11,9] total=2 more=0 | [9] total=2 more=0
    scan fuzzyPlus relevance "ab" - => [15,5,12,6,7,2] total=6 more=0 | [5,12] total=-1 more=1
    scan fuzzyPlus relevance "ab" app=com.a => [7] total=1 more=0 | [] total=1 more=0
    scan fuzzyPlus relevance "ab" type=text => [12] total=1 more=0 | [] total=1 more=0
    scan fuzzyPlus relevance "ab" types=rtf,html => [15,2] total=2 more=0 | [2] total=2 more=0
    scan fuzzyPlus relevance "ab" app=com.b type=image types=text,rtf => [2] total=1 more=0 | [] total=1 more=0
    scan fuzzyPlus recent "ab" - => [12,7,6,2,15,5] total=6 more=0 | [7,6] total=-1 more=1
    scan fuzzyPlus recent "ab" app=com.a => [7] total=1 more=0 | [] total=1 more=0
    scan fuzzyPlus recent "ab" type=text => [12] total=1 more=0 | [] total=1 more=0
    scan fuzzyPlus recent "ab" types=rtf,html => [2,15] total=2 more=0 | [15] total=2 more=0
    scan fuzzyPlus recent "ab" app=com.b type=image types=text,rtf => [2] total=1 more=0 | [] total=1 more=0
    short fuzzy relevance "ab" - => [15,5,12,6,7,2] total=6 more=0 | [5,12] total=-1 more=1
    short fuzzy relevance "ab" app=com.a => [7] total=1 more=0 | [] total=1 more=0
    short fuzzy relevance "ab" type=text => [12] total=1 more=0 | [] total=1 more=0
    short fuzzy relevance "ab" types=rtf,html => [15,2] total=2 more=0 | [2] total=2 more=0
    short fuzzy relevance "ab" app=com.b type=image types=text,rtf => [2] total=1 more=0 | [] total=1 more=0
    short fuzzy recent "ab" - => [12,7,6,2,15,5] total=6 more=0 | [7,6] total=-1 more=1
    short fuzzy recent "ab" app=com.a => [7] total=1 more=0 | [] total=1 more=0
    short fuzzy recent "ab" type=text => [12] total=1 more=0 | [] total=1 more=0
    short fuzzy recent "ab" types=rtf,html => [2,15] total=2 more=0 | [15] total=2 more=0
    short fuzzy recent "ab" app=com.b type=image types=text,rtf => [2] total=1 more=0 | [] total=1 more=0
    short fuzzy relevance "数学" - => [11,9,8,10] total=4 more=0 | [9,8] total=-1 more=1
    short fuzzy relevance "数学" app=com.a => [8] total=1 more=0 | [] total=1 more=0
    short fuzzy relevance "数学" type=text => [11,8] total=2 more=0 | [8] total=2 more=0
    short fuzzy relevance "数学" types=rtf,html => [9,10] total=2 more=0 | [10] total=2 more=0
    short fuzzy relevance "数学" app=com.b type=image types=text,rtf => [11,9] total=2 more=0 | [9] total=2 more=0
    short fuzzy recent "数学" - => [11,10,9,8] total=4 more=0 | [10,9] total=-1 more=1
    short fuzzy recent "数学" app=com.a => [8] total=1 more=0 | [] total=1 more=0
    short fuzzy recent "数学" type=text => [11,8] total=2 more=0 | [8] total=2 more=0
    short fuzzy recent "数学" types=rtf,html => [10,9] total=2 more=0 | [9] total=2 more=0
    short fuzzy recent "数学" app=com.b type=image types=text,rtf => [11,9] total=2 more=0 | [9] total=2 more=0
    short fuzzy relevance "数" - => [11,16,9,8,10] total=5 more=0 | [16,9] total=-1 more=1
    short fuzzy relevance "数" app=com.a => [8] total=1 more=0 | [] total=1 more=0
    short fuzzy relevance "数" type=text => [11,16,8] total=3 more=0 | [16,8] total=3 more=0
    short fuzzy relevance "数" types=rtf,html => [9,10] total=2 more=0 | [10] total=2 more=0
    short fuzzy relevance "数" app=com.b type=image types=text,rtf => [11,9] total=2 more=0 | [9] total=2 more=0
    short fuzzy recent "数" - => [11,10,9,8,16] total=5 more=0 | [10,9] total=-1 more=1
    short fuzzy recent "数" app=com.a => [8] total=1 more=0 | [] total=1 more=0
    short fuzzy recent "数" type=text => [11,8,16] total=3 more=0 | [8,16] total=3 more=0
    short fuzzy recent "数" types=rtf,html => [10,9] total=2 more=0 | [9] total=2 more=0
    short fuzzy recent "数" app=com.b type=image types=text,rtf => [11,9] total=2 more=0 | [9] total=2 more=0
    full fuzzy relevance "alpha" - => [4,2,1,3,7,13,14,6] total=8 more=0 | [2,1] total=8 more=1
    full fuzzy relevance "alpha" app=com.a => [4,1,7,13,14] total=5 more=0 | [1,7] total=5 more=1
    full fuzzy relevance "alpha" type=text => [4,1,13] total=3 more=0 | [1,13] total=3 more=0
    full fuzzy relevance "alpha" types=rtf,html => [2,3,14] total=3 more=0 | [3,14] total=3 more=0
    full fuzzy relevance "alpha" app=com.b type=image types=text,rtf => [2] total=1 more=0 | [] total=1 more=0
    full fuzzy recent "alpha" - => [4,7,3,6,2,13,14,1] total=8 more=0 | [7,3] total=8 more=1
    full fuzzy recent "alpha" app=com.a => [4,7,13,14,1] total=5 more=0 | [7,13] total=5 more=1
    full fuzzy recent "alpha" type=text => [4,13,1] total=3 more=0 | [13,1] total=3 more=0
    full fuzzy recent "alpha" types=rtf,html => [3,2,14] total=3 more=0 | [2,14] total=3 more=0
    full fuzzy recent "alpha" app=com.b type=image types=text,rtf => [2] total=1 more=0 | [] total=1 more=0
    full fuzzyPlus relevance "alpha" - => [4,2,1,3,13,14,6,7] total=8 more=0 | [2,1] total=8 more=1
    full fuzzyPlus relevance "alpha" app=com.a => [4,1,13,14,7] total=5 more=0 | [1,13] total=5 more=1
    full fuzzyPlus relevance "alpha" type=text => [4,1,13] total=3 more=0 | [1,13] total=3 more=0
    full fuzzyPlus relevance "alpha" types=rtf,html => [2,3,14] total=3 more=0 | [3,14] total=3 more=0
    full fuzzyPlus relevance "alpha" app=com.b type=image types=text,rtf => [2] total=1 more=0 | [] total=1 more=0
    full fuzzyPlus recent "alpha" - => [4,7,3,6,2,13,14,1] total=8 more=0 | [7,3] total=8 more=1
    full fuzzyPlus recent "alpha" app=com.a => [4,7,13,14,1] total=5 more=0 | [7,13] total=5 more=1
    full fuzzyPlus recent "alpha" type=text => [4,13,1] total=3 more=0 | [13,1] total=3 more=0
    full fuzzyPlus recent "alpha" types=rtf,html => [3,2,14] total=3 more=0 | [2,14] total=3 more=0
    full fuzzyPlus recent "alpha" app=com.b type=image types=text,rtf => [2] total=1 more=0 | [] total=1 more=0
    full fuzzy relevance "数学公式" - => [11,8,9,10] total=4 more=0 | [8,9] total=4 more=1
    full fuzzy relevance "数学公式" app=com.a => [8] total=1 more=0 | [] total=1 more=0
    full fuzzy relevance "数学公式" type=text => [11,8] total=2 more=0 | [8] total=2 more=0
    full fuzzy relevance "数学公式" types=rtf,html => [9,10] total=2 more=0 | [10] total=2 more=0
    full fuzzy relevance "数学公式" app=com.b type=image types=text,rtf => [11,9] total=2 more=0 | [9] total=2 more=0
    full fuzzy recent "数学公式" - => [11,10,9,8] total=4 more=0 | [10,9] total=4 more=1
    full fuzzy recent "数学公式" app=com.a => [8] total=1 more=0 | [] total=1 more=0
    full fuzzy recent "数学公式" type=text => [11,8] total=2 more=0 | [8] total=2 more=0
    full fuzzy recent "数学公式" types=rtf,html => [10,9] total=2 more=0 | [9] total=2 more=0
    full fuzzy recent "数学公式" app=com.b type=image types=text,rtf => [11,9] total=2 more=0 | [9] total=2 more=0
    """
}
