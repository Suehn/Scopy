import XCTest
import SQLite3
@testable import ScopyKit

final class SQLiteIntegerWidthTests: XCTestCase {
    func testSwiftIntBindingAndReadingPreserveLargeOrdinaryAndNullableValues() throws {
        let connection = try SQLiteConnection(
            path: ":memory:",
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        )
        defer { connection.close() }

        try connection.execute(
            "CREATE TABLE integer_width (required_value INTEGER NOT NULL, optional_value INTEGER)"
        )

        let justAboveInt32 = Int(Int32.max) + 1
        let fiveGiB = 5 * 1024 * 1024 * 1024
        let rows: [(Int, Int?)] = [
            (0, nil),
            (1, 50),
            (Int(Int32.max), justAboveInt32),
            (justAboveInt32, fiveGiB),
            (fiveGiB, Int.max)
        ]

        let insert = try connection.prepare(
            "INSERT INTO integer_width (required_value, optional_value) VALUES (?, ?)"
        )
        for row in rows {
            insert.reset()
            try insert.bindInt(row.0, at: 1)
            if let optionalValue = row.1 {
                try insert.bindInt(optionalValue, at: 2)
            } else {
                try insert.bindNull(2)
            }
            XCTAssertFalse(try insert.step())
        }

        let select = try connection.prepare(
            "SELECT required_value, optional_value FROM integer_width ORDER BY rowid"
        )
        for expected in rows {
            XCTAssertTrue(try select.step())
            XCTAssertEqual(select.columnInt(0), expected.0)
            XCTAssertEqual(select.columnIntOptional(1), expected.1)
        }
        XCTAssertFalse(try select.step())
    }
}
