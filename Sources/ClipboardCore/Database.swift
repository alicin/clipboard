import Foundation
import SQLite3

public struct DatabaseError: Error, CustomStringConvertible {
    public let description: String
}

enum SQLValue {
    case null
    case int(Int64)
    case real(Double)
    case text(String)

    static func optional(_ value: String?) -> SQLValue { value.map(SQLValue.text) ?? .null }
    static func optional(_ value: Int?) -> SQLValue { value.map { .int(Int64($0)) } ?? .null }
}

struct Row {
    fileprivate let values: [String: SQLValue]

    func string(_ column: String) -> String? {
        if case .text(let value) = values[column] { return value }
        return nil
    }

    func int64(_ column: String) -> Int64? {
        if case .int(let value) = values[column] { return value }
        return nil
    }

    func int(_ column: String) -> Int? { int64(column).map(Int.init) }

    func double(_ column: String) -> Double? {
        switch values[column] {
        case .real(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }
}

final class Database {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String, readOnly: Bool) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close_v2(handle)
            handle = nil
            throw DatabaseError(description: message)
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit { sqlite3_close_v2(handle) }

    private var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    func script(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError(description: "\(lastError) in: \(sql.prefix(120))")
        }
    }

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError(description: "\(lastError) in: \(sql.prefix(120))")
        }
        for (index, value) in params.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, position)
            case .int(let int): sqlite3_bind_int64(statement, position, int)
            case .real(let real): sqlite3_bind_double(statement, position, real)
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, Database.transient)
            }
        }
        return statement
    }

    func execute(_ sql: String, _ params: [SQLValue] = []) throws {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else {
            throw DatabaseError(description: "\(lastError) in: \(sql.prefix(120))")
        }
    }

    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [Row] {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        let count = sqlite3_column_count(statement)
        let names = (0..<count).map { String(cString: sqlite3_column_name(statement, $0)) }
        var rows: [Row] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else {
                throw DatabaseError(description: "\(lastError) in: \(sql.prefix(120))")
            }
            var values: [String: SQLValue] = [:]
            for index in 0..<count {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: values[names[Int(index)]] = .int(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: values[names[Int(index)]] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    values[names[Int(index)]] = .text(String(cString: sqlite3_column_text(statement, index)))
                default: values[names[Int(index)]] = .null
                }
            }
            rows.append(Row(values: values))
        }
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try script("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try script("COMMIT")
            return result
        } catch {
            try? script("ROLLBACK")
            throw error
        }
    }
}
