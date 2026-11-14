import Foundation
import SQLite3

public enum DatabaseError: Error, Equatable {
    case open(String)
    case sqlite(code: Int32, message: String)
}

// SQLITE_TRANSIENT is a C macro the importer can't see; -1 tells SQLite to copy the bound bytes.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class Database {
    fileprivate let handle: OpaquePointer

    public init(path: String, readOnly: Bool) throws(DatabaseError) {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var raw: OpaquePointer?
        let rc = sqlite3_open_v2(path, &raw, flags, nil)
        guard rc == SQLITE_OK, let raw else {
            let message = raw.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(rc))
            sqlite3_close(raw)
            throw .open(message)
        }
        handle = raw
        do {
            try exec("PRAGMA busy_timeout=50")
            if !readOnly {
                try exec("PRAGMA journal_mode=WAL")
                try exec("PRAGMA synchronous=NORMAL")
            }
        } catch {
            sqlite3_close(raw)
            throw error
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    public func exec(_ sql: String) throws(DatabaseError) {
        let rc = sqlite3_exec(handle, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw lastError(rc) }
    }

    public func prepare(_ sql: String) throws(DatabaseError) -> Statement {
        var raw: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &raw, nil)
        guard rc == SQLITE_OK, let raw else { throw lastError(rc) }
        return Statement(raw, database: self)
    }

    public func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        try exec("COMMIT")
    }

    fileprivate func lastError(_ code: Int32) -> DatabaseError {
        .sqlite(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }
}

public final class Statement {
    private let stmt: OpaquePointer
    // Keeps the connection open until every statement is finalized.
    private let database: Database

    fileprivate init(_ stmt: OpaquePointer, database: Database) {
        self.stmt = stmt
        self.database = database
    }

    deinit {
        sqlite3_finalize(stmt)
    }

    public func bind(_ i: Int32, _ v: Int64?) {
        if let v { sqlite3_bind_int64(stmt, i, v) } else { sqlite3_bind_null(stmt, i) }
    }

    public func bind(_ i: Int32, _ v: Double?) {
        if let v { sqlite3_bind_double(stmt, i, v) } else { sqlite3_bind_null(stmt, i) }
    }

    public func bind(_ i: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(stmt, i, v, -1, sqliteTransient) } else { sqlite3_bind_null(stmt, i) }
    }

    public func bind(_ i: Int32, _ v: Data?) {
        guard let v else {
            sqlite3_bind_null(stmt, i)
            return
        }
        // An empty Data has no base address, which would otherwise bind as NULL instead of a zero-length blob.
        if v.isEmpty {
            sqlite3_bind_zeroblob(stmt, i, 0)
            return
        }
        _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32($0.count), sqliteTransient) }
    }

    /// Returns true when a row is available, false when the statement is done.
    public func step() throws(DatabaseError) -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw database.lastError(rc)
        }
    }

    public func int64(_ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }

    public func double(_ col: Int32) -> Double { sqlite3_column_double(stmt, col) }

    public func string(_ col: Int32) -> String {
        sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
    }

    public func data(_ col: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(stmt, col) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, col)))
    }

    public func isNull(_ col: Int32) -> Bool { sqlite3_column_type(stmt, col) == SQLITE_NULL }

    public func reset() {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }
}
