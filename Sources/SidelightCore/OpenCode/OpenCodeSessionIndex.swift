import Foundation
import SQLite3

/// A session of OpenCode 2, as its session list keeps it: a title, the folder it runs in and when it last changed.
/// No messages, and no live status: OpenCode 2 knows which sessions are running only inside the process running
/// them, and what it stores (last outcome, recovery claims) says what happened, not what's happening.
public struct OpenCodeSession: Identifiable, Hashable, Sendable {
    /// OpenCode's session ID, `ses_…`, the session's durable identity in its database.
    public let id: String
    /// `nil` until OpenCode names it.
    public var title: String?
    /// The absolute folder the session runs in.
    public var directory: String
    /// Where ``directory`` sits inside its checkout, such as `src/api`; empty or `nil` at the checkout's root.
    public var subpath: String?
    /// The session it was forked from. A fork is a session of its own, not a subagent.
    public var forkedFrom: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String, title: String? = nil, directory: String, subpath: String? = nil, forkedFrom: String? = nil,
        createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.directory = directory
        self.subpath = subpath
        self.forkedFrom = forkedFrom
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The last folder of the checkout, rather than of a subfolder the session started in: `sidelight`, not `api`.
    public var project: String? {
        var root = directory
        if let subpath, !subpath.isEmpty, root.hasSuffix("/" + subpath) {
            root.removeLast(subpath.count + 1)
        }
        guard !root.isEmpty else { return nil }
        let name = URL(filePath: root).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}

/// Where OpenCode 2 keeps its sessions, and how to read them: the `session_v2` table of the SQLite database its CLI
/// opens. Opened read-only, one query at a time, without
/// OpenCode's own setup, which migrates and changes files. Only session metadata is read: never messages, events
/// or sign-ins.
///
/// OpenCode 1's `session` table and JSON files are a different format, which this doesn't read. Nothing here says
/// which OpenCode server, if any, has a session open, or resumes one.
public enum OpenCodeSessionIndex {
    public enum Failure: Error, Sendable {
        /// No database: OpenCode 2 isn't installed, hasn't run, or keeps it under a channel or path not looked at.
        case noDatabase
        /// The database has no session list this version can read: OpenCode 1, or a much newer OpenCode.
        case unsupported
        /// The database couldn't be read right now.
        case unreadable
    }

    /// Where the database is, as OpenCode's CLI decides it.
    public enum Location: Hashable, Sendable {
        case file(URL)
        /// `OPENCODE_DB=:memory:`: the sessions live only in OpenCode's process.
        case inMemory
        /// `OPENCODE_DB` is set but empty, which names OpenCode's data folder rather than a database.
        case dataFolder
    }

    /// The database OpenCode's CLI opens, given the environment Sidelight runs in: `OPENCODE_DB` when set (an
    /// absolute path, or one inside the data folder), else `opencode.db` in `$XDG_DATA_HOME/opencode`, by default
    /// `~/.local/share/opencode`. That file is shared by OpenCode's release, beta and dev builds; custom builds
    /// compiled for another channel keep `opencode-<channel>.db`, which can't be told from outside and isn't read.
    ///
    /// Apps opened from Finder don't see variables set in a shell profile, so overrides apply when Sidelight is
    /// started with them.
    public static func location(environment: [String: String], home: URL) -> Location {
        let dataRoot =
            environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? home.appending(path: ".local/share", directoryHint: .isDirectory)
        let data = dataRoot.appending(path: "opencode", directoryHint: .isDirectory)
        guard let override = environment["OPENCODE_DB"] else {
            return .file(data.appending(path: "opencode.db", directoryHint: .notDirectory))
        }
        if override == ":memory:" { return .inMemory }
        if override.isEmpty { return .dataFolder }
        let url =
            override.hasPrefix("/")
            ? URL(filePath: override, directoryHint: .notDirectory)
            : data.appending(path: override, directoryHint: .notDirectory)
        return .file(url.standardizedFileURL)
    }

    /// The database a released OpenCode uses without overrides.
    public static func defaultDatabase(home: URL) -> URL {
        home.appending(path: ".local/share/opencode/opencode.db", directoryHint: .notDirectory)
    }

    /// Top-level sessions that changed since `date`, newest first, at most `limit`. Forks are listed. Subagent
    /// sessions and archived ones are left out: Sidelight's choice, for a list of what's current. OpenCode's own
    /// session list includes archived sessions.
    public static func sessions(
        updatedSince date: Date, limit: Int = 200, in database: URL
    ) -> Result<[OpenCodeSession], Failure> {
        let path = database.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .failure(.noDatabase)
        }
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return .failure(.unreadable)
        }
        sqlite3_busy_timeout(connection, 500)
        sqlite3_exec(connection, "PRAGMA query_only = ON", nil, nil, nil)

        // A schema that can't be read is a database that can't be read, not one without a session list.
        guard let available = columns(of: "session_v2", in: connection) else { return .failure(.unreadable) }
        let required = ["id", "parent_id", "directory", "title", "time_created", "time_updated", "time_archived"]
        guard required.allSatisfy(available.contains) else { return .failure(.unsupported) }
        let subpath = available.contains("path") ? "path" : "NULL"
        let fork = available.contains("fork_session_id") ? "fork_session_id" : "NULL"
        // Times are integer milliseconds; anything else is a row this version can't date, so it's left out.
        let sql = """
            SELECT id, title, directory, \(subpath), \(fork), time_created, time_updated FROM session_v2
            WHERE parent_id IS NULL AND time_archived IS NULL
                AND typeof(time_updated) = 'integer' AND time_updated >= ?1
            ORDER BY time_updated DESC, id DESC LIMIT ?2
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
            return .failure(.unreadable)
        }
        sqlite3_bind_int64(statement, 1, milliseconds(date))
        sqlite3_bind_int64(statement, 2, Int64(max(limit, 0)))

        func text(_ position: Int32) -> String? {
            guard sqlite3_column_type(statement, position) == SQLITE_TEXT,
                let bytes = sqlite3_column_text(statement, position)
            else { return nil }
            return String(cString: bytes)
        }

        var sessions: [OpenCodeSession] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(statement) }
            guard let id = text(0), !id.isEmpty, let directory = text(2), directory.hasPrefix("/") else { continue }
            let updated = sqlite3_column_int64(statement, 6)
            let created =
                sqlite3_column_type(statement, 5) == SQLITE_INTEGER ? sqlite3_column_int64(statement, 5) : updated
            sessions.append(
                OpenCodeSession(
                    id: id,
                    title: text(1).flatMap(oneLine),
                    directory: directory,
                    subpath: text(3),
                    forkedFrom: text(4).flatMap { $0.isEmpty ? nil : $0 },
                    createdAt: Self.date(milliseconds: created),
                    updatedAt: Self.date(milliseconds: updated)
                ))
        }
        return step == SQLITE_DONE ? .success(sessions) : .failure(.unreadable)
    }

    /// The earliest whole millisecond at or after `date`.
    private static func milliseconds(_ date: Date) -> Int64 {
        let value = (date.timeIntervalSince1970 * 1000).rounded(.up)
        return Int64(exactly: value) ?? (value < 0 ? .min : .max)
    }

    private static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    /// Runs of whitespace and line breaks as single spaces; `nil` when nothing's left.
    private static func oneLine(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// `nil` when the schema couldn't be read; no columns when there's no such table.
    private static func columns(of table: String, in connection: OpaquePointer?) -> Set<String>? {
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
