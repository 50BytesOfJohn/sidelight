import Foundation
import SQLite3

/// Reading other apps' SQLite databases: read-only, never writing, and waiting briefly while the app writes.
enum SQLiteReader {
    /// A read-only connection to `database`, or `nil` if it can't be opened. Close it with `sqlite3_close`.
    static func open(_ database: URL) -> OpaquePointer? {
        var connection: OpaquePointer?
        guard
            sqlite3_open_v2(database.path(percentEncoded: false), &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else {
            sqlite3_close(connection)
            return nil
        }
        sqlite3_busy_timeout(connection, 500)
        return connection
    }

    /// `table`'s column names: `nil` when the schema couldn't be read, none when there's no such table.
    static func columns(of table: String, in connection: OpaquePointer?) -> Set<String>? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(connection, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        var names = Set<String>()
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { names.insert(String(cString: name)) }
            step = sqlite3_step(statement)
        }
        return step == SQLITE_DONE ? names : nil
    }
}
