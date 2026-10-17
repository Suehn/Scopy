import Foundation
import SQLite3

/// Reads the leading bytes of one text or blob column row by row through SQLite's incremental
/// blob I/O, which reads only the pages holding those bytes; a column read loads the whole value,
/// every overflow page included. Use it inside the caller's read transaction and close it there.
final class SQLiteBlobReader {
    private let connection: SQLiteConnection
    private let table: String
    private let column: String
    private var blob: OpaquePointer?

    init(connection: SQLiteConnection, table: String, column: String) {
        self.connection = connection
        self.table = table
        self.column = column
    }

    deinit {
        close()
    }

    func close() {
        if let blob {
            sqlite3_blob_close(blob)
        }
        blob = nil
    }

    /// Copies up to `buffer.count` leading bytes of the row's value into `buffer`; returns how many
    /// it copied and the value's length, or nil when the row is gone or the value is neither text
    /// nor blob.
    func readPrefix(rowID: Int64, into buffer: UnsafeMutableRawBufferPointer) -> (copied: Int, length: Int)? {
        guard let db = connection.handle else { return nil }
        // A failed reopen aborts the handle, so the next row opens a new one.
        if blob == nil || sqlite3_blob_reopen(blob, rowID) != SQLITE_OK {
            close()
            guard sqlite3_blob_open(db, "main", table, column, rowID, 0, &blob) == SQLITE_OK else {
                close()
                return nil
            }
        }
        let length = Int(sqlite3_blob_bytes(blob))
        let copied = min(length, buffer.count)
        guard copied == 0 || sqlite3_blob_read(blob, buffer.baseAddress, Int32(copied), 0) == SQLITE_OK else {
            close()
            return nil
        }
        return (copied, length)
    }
}
