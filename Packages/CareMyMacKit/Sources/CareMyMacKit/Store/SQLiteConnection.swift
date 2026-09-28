import Foundation
import SQLite3

public enum StoreError: Error, Equatable, CustomStringConvertible {
    case sqlite(code: Int32, message: String)
    /// The database was written by a newer CareMyMac build.
    case unsupportedSchemaVersion(Int32)
    case notFound
    case codec(String)
    case fileSystem(String)

    public var description: String {
        switch self {
        case .sqlite(let code, let message): "SQLite error \(code): \(message)"
        case .unsupportedSchemaVersion(let version): "Unsupported history database version \(version)"
        case .notFound: "Item not found"
        case .codec(let message): "Could not encode or decode stored data: \(message)"
        case .fileSystem(let message): "Could not create the history database: \(message)"
        }
    }
}

/// Thin wrapper over one sqlite3 connection with a prepared-statement cache. Thread-confined.
final class SQLiteConnection {
    private let db: OpaquePointer
    private var cache: [String: OpaquePointer] = [:]

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(code))
            sqlite3_close_v2(handle)
            throw StoreError.sqlite(code: code, message: message)
        }
        db = handle
    }

    deinit {
        for statement in cache.values {
            sqlite3_finalize(statement)
        }
        sqlite3_close_v2(db)
    }

    /// Rows changed by the most recent INSERT/UPDATE/DELETE.
    var changes: Int { Int(sqlite3_changes(db)) }

    /// Runs one or more parameterless statements.
    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard code == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errstr(code))
            sqlite3_free(errorMessage)
            throw StoreError.sqlite(code: code, message: message)
        }
    }

    /// Runs `body` with a cached prepared statement, resetting it afterwards so no read
    /// transaction stays open.
    func withStatement<T>(_ sql: String, _ body: (SQLiteStatement) throws -> T) throws -> T {
        let handle = try prepared(sql)
        defer {
            sqlite3_reset(handle)
            sqlite3_clear_bindings(handle)
        }
        return try body(SQLiteStatement(handle: handle, db: db))
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let cached = cache[sql] { return cached }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil)
        guard code == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw StoreError.sqlite(code: code, message: String(cString: sqlite3_errmsg(db)))
        }
        cache[sql] = statement
        return statement
    }
}

struct SQLiteStatement {
    let handle: OpaquePointer
    let db: OpaquePointer

    /// SQLITE_TRANSIENT: sqlite copies bound text/blob before the call returns.
    private var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    // Parameter indexes are 1-based, like sqlite.

    func bind(_ value: Int64?, at index: Int32) throws {
        try check(value.map { sqlite3_bind_int64(handle, index, $0) } ?? sqlite3_bind_null(handle, index))
    }

    func bind(_ value: Double?, at index: Int32) throws {
        try check(value.map { sqlite3_bind_double(handle, index, $0) } ?? sqlite3_bind_null(handle, index))
    }

    func bind(_ value: String?, at index: Int32) throws {
        try check(value.map { sqlite3_bind_text(handle, index, $0, -1, transient) } ?? sqlite3_bind_null(handle, index))
    }

    func bind(_ value: Data, at index: Int32) throws {
        let code = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(handle, index, buffer.baseAddress, Int32(buffer.count), transient)
        }
        try check(code)
    }

    /// Steps once; true when a row is available.
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        case let code: throw StoreError.sqlite(code: code, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Steps until done (statements without result rows).
    func run() throws {
        while try step() {}
    }

    // Column indexes are 0-based, like sqlite.

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }
    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func optionalDouble(_ column: Int32) -> Double? { isNull(column) ? nil : double(column) }

    func text(_ column: Int32) -> String? {
        sqlite3_column_text(handle, column).map { String(cString: $0) }
    }

    func blob(_ column: Int32) -> Data {
        // sqlite docs: fetch the pointer first, then its size.
        guard let bytes = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, column)))
    }

    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else {
            throw StoreError.sqlite(code: code, message: String(cString: sqlite3_errmsg(db)))
        }
    }
}
