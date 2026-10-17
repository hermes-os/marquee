//
//  SQLiteConnection.swift
//  Marquee
//
//  Thin wrapper around the system sqlite3 C API.
//  No external dependencies. macOS 12+ compatible.
//

import Foundation
import SQLite3

// MARK: - Binding value

enum SQLValue {
    case text(String)
    case int(Int)
    case double(Double)
    case blob(Data)
    case null
}

// MARK: - Connection

final class SQLiteConnection {

    private var db: OpaquePointer?

    init(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw CatalogStoreError.ioFailure("open: \(msg)")
        }
        self.db = opened
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit { sqlite3_close(db) }

    // MARK: - Schema version

    var userVersion: Int {
        get throws {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else {
                throw CatalogStoreError.ioFailure("PRAGMA user_version")
            }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    func setUserVersion(_ v: Int) throws {
        try execute("PRAGMA user_version = \(v)")
    }

    // MARK: - Execute (no results)

    func execute(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errmsg)
        if rc != SQLITE_OK {
            let msg = errmsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errmsg)
            throw CatalogStoreError.ioFailure(msg)
        }
    }

    // MARK: - Run (with bindings, no results)

    func run(_ sql: String, _ bindings: [SQLValue]) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindAll(stmt, bindings)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw CatalogStoreError.ioFailure(errorMessage())
        }
    }

    // MARK: - Run many (prepare once, step many)

    /// Runs the same statement once per row in `rows`, sharing a single
    /// prepared statement. Returns when all rows have stepped to
    /// `SQLITE_DONE`. The first failing row throws and the statement is
    /// finalized; callers wrap this in a transaction so partial work
    /// rolls back.
    func runMany(_ sql: String, _ rows: [[SQLValue]]) throws {
        guard !rows.isEmpty else { return }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for bindings in rows {
            try bindAll(stmt, bindings)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else {
                throw CatalogStoreError.ioFailure("step: \(errorMessage())")
            }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
    }

    // MARK: - Transaction primitives

    /// Issues `BEGIN IMMEDIATE` so the connection acquires the SQLite
    /// write lock up-front instead of on the first write. This makes
    /// write contention surface immediately rather than mid-transaction.
    func beginImmediate() throws { try execute("BEGIN IMMEDIATE") }

    func commit() throws { try execute("COMMIT") }

    func rollback() throws { try execute("ROLLBACK") }

    // MARK: - Query (with bindings, mapped results)

    func query<T>(
        _ sql: String,
        _ bindings: [SQLValue] = [],
        map: (Statement) throws -> T
    ) throws -> [T] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindAll(stmt, bindings)
        var results: [T] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            try results.append(map(Statement(stmt)))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else {
            throw CatalogStoreError.ioFailure("query: \(errorMessage())")
        }
        return results
    }

    func queryOne<T>(
        _ sql: String,
        _ bindings: [SQLValue] = [],
        map: (Statement) throws -> T
    ) throws -> T? {
        try query(sql, bindings, map: map).first
    }

    func queryCount(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindAll(stmt, bindings)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW else {
            throw CatalogStoreError.ioFailure("count: \(errorMessage())")
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Internals

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let s = stmt else {
            throw CatalogStoreError.ioFailure("prepare: \(errorMessage())")
        }
        return s
    }

    private func bindAll(_ stmt: OpaquePointer, _ values: [SQLValue]) throws {
        for (i, val) in values.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch val {
            case .text(let s):
                rc = sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .int(let n):
                rc = sqlite3_bind_int64(stmt, idx, Int64(n))
            case .double(let d):
                rc = sqlite3_bind_double(stmt, idx, d)
            case .blob(let data):
                rc = data.withUnsafeBytes {
                    sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(data.count), Self.transient)
                }
            case .null:
                rc = sqlite3_bind_null(stmt, idx)
            }
            guard rc == SQLITE_OK else {
                throw CatalogStoreError.ioFailure("bind \(idx): \(errorMessage())")
            }
        }
    }

    private func errorMessage() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

// MARK: - Row reader

struct Statement {
    fileprivate let raw: OpaquePointer

    fileprivate init(_ raw: OpaquePointer) { self.raw = raw }

    func text(_ col: Int32) -> String {
        sqlite3_column_text(raw, col).map { String(cString: $0) } ?? ""
    }

    func optionalText(_ col: Int32) -> String? {
        guard sqlite3_column_type(raw, col) != SQLITE_NULL else { return nil }
        return text(col)
    }

    func int(_ col: Int32) -> Int {
        Int(sqlite3_column_int64(raw, col))
    }

    func optionalInt(_ col: Int32) -> Int? {
        guard sqlite3_column_type(raw, col) != SQLITE_NULL else { return nil }
        return int(col)
    }

    func double(_ col: Int32) -> Double {
        sqlite3_column_double(raw, col)
    }

    func optionalDouble(_ col: Int32) -> Double? {
        guard sqlite3_column_type(raw, col) != SQLITE_NULL else { return nil }
        return double(col)
    }

    func date(_ col: Int32) -> Date {
        Date(timeIntervalSince1970: double(col))
    }

    func optionalDate(_ col: Int32) -> Date? {
        guard sqlite3_column_type(raw, col) != SQLITE_NULL else { return nil }
        return date(col)
    }

    func bool(_ col: Int32) -> Bool {
        int(col) != 0
    }
}
