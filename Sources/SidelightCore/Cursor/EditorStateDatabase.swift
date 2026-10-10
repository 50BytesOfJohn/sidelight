import Foundation
import SQLite3

/// The `state.vscdb` SQLite database VS Code–based editors such as Cursor keep their global state in: one
/// `ItemTable` of `key` → `value`. Opened read-only, one query at a time, so the editor's own use of it is unaffected.
public enum EditorStateDatabase {
    /// The value stored under `key` as text; `nil` when the database, the table or the key is missing, or the
    /// database is busy.
    public static func value(forKey key: String, in database: URL) -> String? {
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        guard
            sqlite3_open_v2(database.path(percentEncoded: false), &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else { return nil }
        sqlite3_busy_timeout(connection, 500)

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard
            sqlite3_prepare_v2(connection, "SELECT value FROM ItemTable WHERE key = ?1 LIMIT 1", -1, &statement, nil)
                == SQLITE_OK
        else { return nil }
        let bound = key.withCString { cKey in
            // SQLite copies the key (`SQLITE_TRANSIENT`), so it may outlive this closure.
            sqlite3_bind_text(statement, 1, cKey, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW,
            let bytes = sqlite3_column_blob(statement, 0)
        else { return nil }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        return String(data: data, encoding: .utf8)
    }
}
