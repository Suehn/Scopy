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
        // With the short index built, ASCII candidates rank in Swift and non-ASCII bigram
        // candidates rank in SQL; a single non-ASCII character still scans.
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

    private func makeFixtureDatabase() throws -> String {
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
            for row in Self.rows {
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
