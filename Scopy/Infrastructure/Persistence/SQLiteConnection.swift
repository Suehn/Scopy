import Foundation
import SQLite3

final class SQLiteConnection {
    enum SQLiteConnectionError: Error, LocalizedError {
        case openFailed(String)
        case execFailed(String)
        case prepareFailed(String)
        case bindFailed(String)
        case stepFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let msg): return "SQLite open failed: \(msg)"
            case .execFailed(let msg): return "SQLite exec failed: \(msg)"
            case .prepareFailed(let msg): return "SQLite prepare failed: \(msg)"
            case .bindFailed(let msg): return "SQLite bind failed: \(msg)"
            case .stepFailed(let msg): return "SQLite step failed: \(msg)"
            }
        }
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
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "code=\(rc)"
            if let db {
                sqlite3_close(db)
            }
            throw SQLiteConnectionError.openFailed(message)
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

    func errorMessage() -> String {
        guard let db = handle else { return "Database is not open" }
        return String(cString: sqlite3_errmsg(db))
    }

    func execute(_ sql: String) throws {
        guard let db = handle else {
            throw SQLiteConnectionError.execFailed("Database is not open")
        }

        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? errorMessage()
            sqlite3_free(errMsg)
            throw SQLiteConnectionError.execFailed(message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let db = handle else {
            throw SQLiteConnectionError.prepareFailed("Database is not open")
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteConnectionError.prepareFailed(errorMessage())
        }

        return SQLiteStatement(connection: self, statement: stmt)
    }

    func walCheckpointPassive() {
        guard let db = handle else { return }
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
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
        guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
            throw SQLiteConnection.SQLiteConnectionError.bindFailed(connection.errorMessage())
        }
    }

    func bindText(_ value: String?, at index: Int32) throws {
        guard let value else {
            try bindNull(index)
            return
        }

        guard sqlite3_bind_text(statement, index, value, -1, SQLiteConnection.sqliteTransient) == SQLITE_OK else {
            throw SQLiteConnection.SQLiteConnectionError.bindFailed(connection.errorMessage())
        }
    }

    func bindInt(_ value: Int, at index: Int32) throws {
        guard sqlite3_bind_int(statement, index, Int32(value)) == SQLITE_OK else {
            throw SQLiteConnection.SQLiteConnectionError.bindFailed(connection.errorMessage())
        }
    }

    func bindInt64(_ value: Int64, at index: Int32) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw SQLiteConnection.SQLiteConnectionError.bindFailed(connection.errorMessage())
        }
    }

    func bindDouble(_ value: Double, at index: Int32) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw SQLiteConnection.SQLiteConnectionError.bindFailed(connection.errorMessage())
        }
    }

    func bindBlob(_ data: Data?, at index: Int32) throws {
        guard let data else {
            try bindNull(index)
            return
        }

        let bytes = (data as NSData).bytes
        guard sqlite3_bind_blob(statement, index, bytes, Int32(data.count), SQLiteConnection.sqliteTransient) == SQLITE_OK else {
            throw SQLiteConnection.SQLiteConnectionError.bindFailed(connection.errorMessage())
        }
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
            throw SQLiteConnection.SQLiteConnectionError.stepFailed(connection.errorMessage())
        }
    }

    func columnText(_ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: ptr)
    }

    func columnInt(_ index: Int32) -> Int {
        Int(sqlite3_column_int(statement, index))
    }

    func columnIntOptional(_ index: Int32) -> Int? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL {
            return nil
        }
        return Int(sqlite3_column_int(statement, index))
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
