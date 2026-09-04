import XCTest
import SQLite3
@testable import ScopyKit

/// Text bound with a `-1` length uses C-string semantics, which silently truncates anything a
/// clipboard capture happens to contain past the first NUL. Storage must round-trip the bytes it
/// was given.
final class SQLiteTextFidelityTests: XCTestCase {
    func testTextBindingRoundTripsEmbeddedNULAndEmptyStrings() throws {
        let connection = try SQLiteConnection(
            path: ":memory:",
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        )
        defer { connection.close() }

        try connection.execute("CREATE TABLE text_fidelity (value TEXT)")

        let values = [
            "a\u{0}b",
            "\u{0}leading",
            "trailing\u{0}",
            "",
            "plain ascii",
            "多字节\u{0}文本",
            "emoji 🧪\u{0}tail"
        ]

        let insert = try connection.prepare("INSERT INTO text_fidelity (value) VALUES (?)")
        for value in values {
            insert.reset()
            try insert.bindText(value, at: 1)
            XCTAssertFalse(try insert.step())
        }

        let select = try connection.prepare("SELECT value FROM text_fidelity ORDER BY rowid")
        var readBack: [String] = []
        while try select.step() {
            readBack.append(select.columnText(0) ?? "<null>")
        }

        XCTAssertEqual(readBack, values)
        XCTAssertEqual(readBack.first?.unicodeScalars.count, 3)
    }

    func testNullTextStaysDistinctFromEmptyText() throws {
        let connection = try SQLiteConnection(
            path: ":memory:",
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        )
        defer { connection.close() }

        try connection.execute("CREATE TABLE text_nullability (value TEXT)")
        let insert = try connection.prepare("INSERT INTO text_nullability (value) VALUES (?)")
        try insert.bindText(nil, at: 1)
        XCTAssertFalse(try insert.step())
        insert.reset()
        try insert.bindText("", at: 1)
        XCTAssertFalse(try insert.step())

        let select = try connection.prepare("SELECT value FROM text_nullability ORDER BY rowid")
        XCTAssertTrue(try select.step())
        XCTAssertNil(select.columnText(0))
        XCTAssertTrue(try select.step())
        XCTAssertEqual(select.columnText(0), "")
    }
}
