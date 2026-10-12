import Foundation
import SQLite3

/// A chat in the Cursor editor or its Agents window, as Cursor's chat list keeps it: a name, the workspace it
/// belongs to and when it last changed. No messages, and no live status: Cursor stores whether a chat was
/// generating, but not in a way that says it still is.
public struct CursorChat: Identifiable, Hashable, Sendable {
    /// Cursor's composer ID, the chat's durable identity on this Mac.
    public let id: String
    /// The name Cursor generated or the user gave it.
    public var name: String?
    /// The folder of the workspace it was started in, when the workspace is a single folder.
    public var workspacePath: String?
    public var createdAt: Date?
    public var updatedAt: Date

    public init(
        id: String, name: String? = nil, workspacePath: String? = nil, createdAt: Date? = nil, updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.workspacePath = workspacePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The last folder of the workspace: `sidelight`.
    public var project: String? {
        guard let workspacePath, !workspacePath.isEmpty else { return nil }
        let name = URL(filePath: workspacePath).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}

/// Cursor's chat list: the `composerHeaders` table of its global `state.vscdb`, one small row per chat, which
/// Cursor 3 keeps for its sidebar and Agents window. Opened read-only, one query at a time, so Cursor's own use of
/// it is unaffected. Chat bodies live elsewhere in the database and are never read.
///
/// Undocumented, so it's read leniently: a field that's missing or changes type reads as unknown, and a row whose
/// details don't decode is skipped rather than failing the list.
public enum CursorChatIndex {
    public static let defaultDatabase = CursorSignIn.appStateDatabase

    public typealias Failure = SessionIndexFailure

    /// Chats that changed since `date`, newest first, at most `limit`. Archived chats, subagents, empty drafts and
    /// ephemeral chats are left out, as Cursor's own list leaves them out.
    public static func chats(
        updatedSince date: Date, limit: Int = 200, in database: URL = defaultDatabase
    ) -> Result<[CursorChat], Failure> {
        guard FileManager.default.fileExists(atPath: database.path(percentEncoded: false)) else {
            return .failure(.noDatabase)
        }
        guard let connection = SQLiteReader.open(database) else { return .failure(.unreadable) }
        defer { sqlite3_close(connection) }

        // A schema that can't be read is a database that can't be read, not one without a chat list.
        guard let available = SQLiteReader.columns(of: "composerHeaders", in: connection) else {
            return .failure(.unreadable)
        }
        guard ["composerId", "value", "lastUpdatedAt"].allSatisfy(available.contains) else {
            return .failure(.unsupported)
        }
        let hasCreated = available.contains("createdAt")
        let updated =
            hasCreated
            ? "COALESCE(\(milliseconds("lastUpdatedAt")), \(milliseconds("createdAt")))" : milliseconds("lastUpdatedAt")
        let created = hasCreated ? ", \(milliseconds("createdAt"))" : ""
        let flags = ["isArchived", "isSubagent"].filter(available.contains).map { "COALESCE(\($0), 0) = 0 AND " }
        // The time is filtered, ordered and returned as the same value, so a row is never kept for one reading of
        // its time and dated by another. No SQL `LIMIT`: rows hidden in their JSON or that don't decode are only
        // skipped below, and mustn't take the place of chats that would be listed.
        let sql = """
            SELECT composerId, value, \(updated)\(created) FROM composerHeaders
            WHERE \(flags.joined())\(updated) >= ?1 ORDER BY 3 DESC
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
            return .failure(.unreadable)
        }
        sqlite3_bind_double(statement, 1, cutoff(date))

        // As a double, so a fraction of a millisecond isn't dropped from a time SQL compared and ordered with it.
        func time(_ position: Int32) -> Double? {
            guard position < sqlite3_column_count(statement), sqlite3_column_type(statement, position) != SQLITE_NULL
            else { return nil }
            return sqlite3_column_double(statement, position)
        }

        var chats: [CursorChat] = []
        var step = SQLITE_DONE
        while chats.count < limit {
            step = sqlite3_step(statement)
            guard step == SQLITE_ROW else { break }
            guard let idBytes = sqlite3_column_text(statement, 0),
                let valueBytes = sqlite3_column_blob(statement, 1),
                let updatedAt = time(2)
            else { continue }
            let id = String(cString: idBytes)
            let value = Data(bytes: valueBytes, count: Int(sqlite3_column_bytes(statement, 1)))
            guard !id.isEmpty, let header = try? JSONDecoder().decode(Header.self, from: value),
                !header.isHidden
            else { continue }
            chats.append(
                CursorChat(
                    id: id,
                    name: header.name.flatMap(oneLine),
                    workspacePath: header.workspacePath,
                    createdAt: (time(3) ?? header.createdAt.map(Double.init)).map(Date.init(millisecondsSince1970:)),
                    updatedAt: Date(millisecondsSince1970: updatedAt)
                ))
        }
        // A row still waiting means the limit was reached, not that the read failed.
        return step == SQLITE_ROW || step == SQLITE_DONE ? .success(chats) : .failure(.unreadable)
    }

    /// One row's `value`: the chat's header as JSON.
    struct Header: Decodable {
        var name: String?
        var workspacePath: String?
        var createdAt: Int64?
        var isHidden: Bool

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            name = container.lenient(String.self, "name")
            createdAt = container.lenientInt64("createdAt")
            let workspace = try? container.nestedContainer(
                keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("workspaceIdentifier"))
            let uri = try? workspace?.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("uri"))
            // Only local folders: a remote workspace's path means nothing on this Mac.
            let scheme = uri?.lenient(String.self, "scheme")
            workspacePath = scheme == nil || scheme == "file" ? uri?.lenient(String.self, "fsPath") : nil
            isHidden = ["isArchived", "isDraft", "isEphemeral", "isSubagent"].contains {
                container.lenient(Bool.self, $0) == true
            }
        }
    }

    /// The smallest time in milliseconds that `Date(millisecondsSince1970:)` turns into `date` or later, so the query
    /// keeps exactly the rows that are returned dated at or after `date`, whatever rounding the conversion does. NaN,
    /// which SQLite binds as NULL and so matches nothing, when no time is that late.
    ///
    /// Later times never make earlier dates, so it's a binary search over every double in order: at most 64 steps.
    private static func cutoff(_ date: Date) -> Double {
        func isLate(_ milliseconds: Double) -> Bool { Date(millisecondsSince1970: milliseconds) >= date }
        // Every date compares as at or after a NaN date; no time should count as late enough for one.
        guard !date.timeIntervalSinceReferenceDate.isNaN, isLate(.infinity) else { return .nan }
        guard !isLate(-.infinity) else { return -.infinity }
        // Doubles as unsigned integers in the same order: negative ones reversed below the positive ones.
        func key(_ value: Double) -> UInt64 {
            value.sign == .minus ? ~value.bitPattern : value.bitPattern | (1 << 63)
        }
        func value(_ key: UInt64) -> Double {
            Double(bitPattern: key & (1 << 63) != 0 ? key & ~(1 << 63) : ~key)
        }
        var early = key(-.infinity)
        var late = key(.infinity)
        while late - early > 1 {
            let middle = early + (late - early) / 2
            if isLate(value(middle)) { late = middle } else { early = middle }
        }
        return value(late)
    }

    /// Runs of whitespace and line breaks as single spaces; `nil` when nothing's left.
    private static func oneLine(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// SQL for a column's value as milliseconds: a number, or text of digits only, as SQLite stores numbers in
    /// columns without a type. Anything else is NULL rather than the zero SQLite would make of it.
    private static func milliseconds(_ column: String) -> String {
        """
        CASE WHEN typeof(\(column)) IN ('integer', 'real') THEN \(column) \
        WHEN typeof(\(column)) = 'text' AND \(column) GLOB '[0-9]*' AND \(column) NOT GLOB '*[^0-9]*' \
        THEN CAST(\(column) AS INTEGER) END
        """
    }
}
