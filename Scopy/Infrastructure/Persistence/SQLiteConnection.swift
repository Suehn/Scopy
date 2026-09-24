import Foundation
import SQLite3

final class SQLiteConnection {
    struct SQLiteConnectionError: Error, LocalizedError {
        enum Operation: String, Sendable {
            case open, exec, prepare, bind, step
        }

        enum Category: String, Sendable {
            case busy, full, corrupt, readonly, ioerr, constraint, interrupt, other
        }

        let operation: Operation
        /// SQLite extended result code, e.g. 1555 for SQLITE_CONSTRAINT_PRIMARYKEY.
        let code: Int32
        let message: String

        var category: Category {
            switch code & 0xFF {
            case SQLITE_BUSY, SQLITE_LOCKED: return .busy
            case SQLITE_FULL: return .full
            case SQLITE_CORRUPT, SQLITE_NOTADB: return .corrupt
            case SQLITE_READONLY: return .readonly
            case SQLITE_IOERR: return .ioerr
            case SQLITE_CONSTRAINT: return .constraint
            case SQLITE_INTERRUPT: return .interrupt
            default: return .other
            }
        }

        var errorDescription: String? {
            "SQLite \(operation.rawValue) failed (code \(code)): \(message)"
        }
    }

    /// Builds the error for a failed call and records it. The code and category are public so
    /// release logs can tell BUSY/FULL/CORRUPT apart; the message may echo SQL or data and stays
    /// private. Interrupts are the search engine's normal cancellation path and are not logged.
    static func failure(
        _ operation: SQLiteConnectionError.Operation,
        status: Int32,
        db: OpaquePointer?,
        message: String? = nil
    ) -> SQLiteConnectionError {
        let extended = db.map { sqlite3_extended_errcode($0) } ?? status
        let code = (extended & 0xFF) == (status & 0xFF) ? extended : status
        let message = message
            ?? db.map { String(cString: sqlite3_errmsg($0)) }
            ?? String(cString: sqlite3_errstr(status))
        let error = SQLiteConnectionError(operation: operation, code: code, message: message)
        if error.category != .interrupt {
            ScopyLog.persistence.error(
                "SQLite \(operation.rawValue, privacy: .public) failed code=\(code, privacy: .public) category=\(error.category.rawValue, privacy: .public) message=\(message, privacy: .private)"
            )
        }
        return error
    }

    fileprivate static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func openFlags(for path: String, readOnly: Bool) -> Int32 {
        var flags: Int32 = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        if path.hasPrefix("file:") {
            flags |= SQLITE_OPEN_URI
        }
        return flags
    }

    private(set) var handle: OpaquePointer?
    let path: String

    init(path: String, flags: Int32) throws {
        self.path = path

        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let error = Self.failure(.open, status: rc == SQLITE_OK ? SQLITE_CANTOPEN : rc, db: db)
            if let db {
                sqlite3_close(db)
            }
            throw error
        }
        self.handle = db
    }

    deinit {
        close()
    }

    func close() {
        guard let db = handle else { return }
        sqlite3_close(db)
        handle = nil
    }

    func execute(_ sql: String) throws {
        guard let db = handle else {
            throw Self.failure(.exec, status: SQLITE_MISUSE, db: nil, message: "Database is not open")
        }

        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) }
            sqlite3_free(errMsg)
            throw Self.failure(.exec, status: rc, db: db, message: message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let db = handle else {
            throw Self.failure(.prepare, status: SQLITE_MISUSE, db: nil, message: "Database is not open")
        }

        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw Self.failure(.prepare, status: rc == SQLITE_OK ? SQLITE_MISUSE : rc, db: db)
        }

        return SQLiteStatement(connection: self, statement: stmt)
    }

    func walCheckpointPassive() {
        guard let db = handle else { return }
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
    }

    /// Checkpoints and truncates the WAL. Unlike the passive mode this actually shrinks the
    /// `-wal` file once no reader is behind, which is what an oversized WAL needs.
    func walCheckpointTruncate() {
        guard let db = handle else { return }
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }

    /// Frees the page cache and other heap memory this connection can release.
    func releaseMemory() {
        guard let db = handle else { return }
        sqlite3_db_release_memory(db)
    }

    func changeCount() -> Int {
        guard let db = handle else { return 0 }
        return Int(sqlite3_changes(db))
    }
}

final class SQLiteStatement {
    private unowned let connection: SQLiteConnection
    private let statement: OpaquePointer

    fileprivate init(connection: SQLiteConnection, statement: OpaquePointer) {
        self.connection = connection
        self.statement = statement
    }

    deinit {
        sqlite3_finalize(statement)
    }

    func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    func bindNull(_ index: Int32) throws {
        let rc = sqlite3_bind_null(statement, index)
        guard rc == SQLITE_OK else { throw failure(.bind, status: rc) }
    }

    func bindText(_ value: String?, at index: Int32) throws {
        guard var text = value else {
            try bindNull(index)
            return
        }

        // Bind by explicit UTF-8 byte count. A `-1` length uses C-string semantics and would
        // silently truncate clipboard text at the first embedded NUL.
        //
        // Native Swift strings already hold contiguous UTF-8, so the common path binds straight
        // out of the string's own storage and only a bridged string pays for a copy.
        let status = text.withUTF8 { buffer -> Int32 in
            // An empty string still has to bind as text, not NULL, so it needs a valid pointer.
            let empty: CChar = 0
            return withUnsafePointer(to: empty) { fallback in
                let bytes = buffer.baseAddress
                    .map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) } ?? fallback
                return sqlite3_bind_text64(
                    statement,
                    index,
                    bytes,
                    sqlite3_uint64(buffer.count),
                    SQLiteConnection.sqliteTransient,
                    UInt8(SQLITE_UTF8)
                )
            }
        }
        guard status == SQLITE_OK else { throw failure(.bind, status: status) }
    }

    func bindInt(_ value: Int, at index: Int32) throws {
        let rc = sqlite3_bind_int64(statement, index, Int64(value))
        guard rc == SQLITE_OK else { throw failure(.bind, status: rc) }
    }

    func bindInt64(_ value: Int64, at index: Int32) throws {
        let rc = sqlite3_bind_int64(statement, index, value)
        guard rc == SQLITE_OK else { throw failure(.bind, status: rc) }
    }

    func bindDouble(_ value: Double, at index: Int32) throws {
        let rc = sqlite3_bind_double(statement, index, value)
        guard rc == SQLITE_OK else { throw failure(.bind, status: rc) }
    }

    func bindBlob(_ data: Data?, at index: Int32) throws {
        guard let data else {
            try bindNull(index)
            return
        }

        let bytes = (data as NSData).bytes
        let rc = sqlite3_bind_blob(statement, index, bytes, Int32(data.count), SQLiteConnection.sqliteTransient)
        guard rc == SQLITE_OK else { throw failure(.bind, status: rc) }
    }

    @discardableResult
    func step() throws -> Bool {
        let rc = sqlite3_step(statement)
        switch rc {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw failure(.step, status: rc)
        }
    }

    private func failure(
        _ operation: SQLiteConnection.SQLiteConnectionError.Operation,
        status: Int32
    ) -> SQLiteConnection.SQLiteConnectionError {
        SQLiteConnection.failure(operation, status: status, db: connection.handle)
    }

    func columnText(_ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(statement, index) else { return nil }
        // Read by stored byte count, not C-string semantics, so text containing NUL round-trips.
        let length = Int(sqlite3_column_bytes(statement, index))
        return String(decoding: UnsafeBufferPointer(start: ptr, count: length), as: UTF8.self)
    }

    func columnTextBytes(_ index: Int32) -> (ptr: UnsafePointer<UInt8>, length: Int)? {
        guard let ptr = sqlite3_column_text(statement, index) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, index))
        return (ptr: ptr, length: length)
    }

    func columnInt(_ index: Int32) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }

    func columnIntOptional(_ index: Int32) -> Int? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL {
            return nil
        }
        return Int(sqlite3_column_int64(statement, index))
    }

    func columnInt64(_ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func columnDouble(_ index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    func columnBlobData(_ index: Int32) -> Data? {
        let blobBytes = sqlite3_column_blob(statement, index)
        let blobSize = sqlite3_column_bytes(statement, index)
        guard let bytes = blobBytes, blobSize > 0 else { return nil }
        return Data(bytes: bytes, count: Int(blobSize))
    }
}
