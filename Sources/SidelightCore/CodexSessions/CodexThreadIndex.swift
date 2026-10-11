import Foundation
import SQLite3

/// A Codex thread (a session) as Codex's state database lists it.
public struct CodexThreadRow: Hashable, Sendable {
    public var id: String
    public var rolloutPath: String
    public var cwd: String?
    /// The name Codex generated or the user gave it, such as `Release the app`.
    public var name: String?
    /// Usually the first prompt.
    public var title: String?
    /// `cli`, `vscode` (also the desktop app), `exec`, or a JSON object for subagents.
    public var source: String
    /// The client that started it: `codex-tui`, `Codex Desktop`, …; missing for older threads.
    public var originator: String?
    public var gitBranch: String?
    public var model: String?
    public var reasoningEffort: String?
    /// `nil` where this version of Codex doesn't record it.
    public var createdAt: Date?
    public var updatedAt: Date

    public init(
        id: String, rolloutPath: String, cwd: String? = nil, name: String? = nil, title: String? = nil,
        source: String = "cli", originator: String? = nil, gitBranch: String? = nil, model: String? = nil,
        reasoningEffort: String? = nil, createdAt: Date? = nil, updatedAt: Date
    ) {
        self.id = id
        self.rolloutPath = rolloutPath
        self.cwd = cwd
        self.name = name
        self.title = title
        self.source = source
        self.originator = originator
        self.gitBranch = gitBranch
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// A subagent's thread (an approval review, a code review, an agent another session spawned) rather than one
    /// someone started.
    public var isSubagent: Bool { source.hasPrefix("{") }

    /// Started by `codex exec`: a script or CI run rather than an interactive session.
    public var isExec: Bool { source == "exec" || originator == "codex_exec" }

    /// The session a spawned subagent works for, when its source says.
    public var parentThreadID: String? {
        guard isSubagent, let range = source.range(of: #""parent_thread_id":""#) else { return nil }
        let rest = source[range.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }

    /// The spawned subagent's nickname, such as `Franklin`.
    public var agentNickname: String? {
        guard isSubagent, let range = source.range(of: #""agent_nickname":""#) else { return nil }
        let rest = source[range.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }
}

/// Codex's state database, `~/.codex/state_<N>.sqlite`, where it indexes every thread with its title, folder and
/// branch. Opened read-only, one query at a time, so Codex's own use of it is unaffected.
///
/// Undocumented: columns this version doesn't have read as missing, and the newest `state_<N>` file is used, so a
/// schema bump that keeps the table's shape keeps working.
public enum CodexThreadIndex {
    public static var defaultCodexDirectory: URL {
        URL.homeDirectory.appending(path: ".codex", directoryHint: .isDirectory)
    }

    /// The state database with the highest version in `codexDirectory`.
    public static func databaseURL(in codexDirectory: URL = defaultCodexDirectory) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: codexDirectory.path(percentEncoded: false)))
        let newest = names?.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                let version = Int(name.dropFirst("state_".count).dropLast(".sqlite".count))
            else { return nil }
            return (version, name)
        }.max { $0.0 < $1.0 }
        return newest.map { codexDirectory.appending(path: $0.1) }
    }

    /// Threads not archived that changed since `date`, and those in `included` however long ago they changed (the
    /// ones a Codex process has open), at most `limit`; `nil` when the database can't be read. The included ones
    /// come first, so the limit never leaves them out, then the rest newest first.
    public static func threads(
        updatedSince date: Date, including included: Set<String> = [], limit: Int = 500, in database: URL
    ) -> [CodexThreadRow]? {
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        guard
            sqlite3_open_v2(database.path(percentEncoded: false), &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else { return nil }
        sqlite3_busy_timeout(connection, 500)

        let available = columns(of: "threads", in: connection)
        guard ["id", "rollout_path", "updated_at", "source"].allSatisfy(available.contains) else { return nil }
        let optional = [
            "cwd", "name", "title", "originator", "git_branch", "model", "reasoning_effort", "created_at",
            "updated_at_ms",
        ]
        let selected = ["id", "rollout_path", "updated_at", "source"] + optional.filter(available.contains)
        // Milliseconds where this version has them (indexed, and filled in by a trigger), seconds otherwise.
        let updated = available.contains("updated_at_ms") ? "updated_at_ms" : "updated_at * 1000"
        let archived = available.contains("archived") ? "archived = 0 AND" : ""
        let included = Array(included)
        let placeholders = included.indices.map { "?\($0 + 3)" }.joined(separator: ", ")
        let isIncluded = "id IN (\(placeholders))"
        let sql =
            included.isEmpty
            ? """
            SELECT \(selected.joined(separator: ", ")) FROM threads
            WHERE \(archived) \(updated) >= ?1 ORDER BY \(updated) DESC LIMIT ?2
            """
            : """
            SELECT \(selected.joined(separator: ", ")) FROM threads
            WHERE \(archived) (\(updated) >= ?1 OR \(isIncluded))
            ORDER BY \(isIncluded) DESC, \(updated) DESC LIMIT ?2
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(statement, 1, Int64(date.timeIntervalSince1970 * 1000))
        sqlite3_bind_int64(statement, 2, Int64(limit))
        for (position, id) in included.enumerated() {
            _ = id.withCString { text in
                // SQLite copies the text (`SQLITE_TRANSIENT`), so it may outlive this closure.
                sqlite3_bind_text(
                    statement, Int32(position + 3), text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        }

        let index = Dictionary(uniqueKeysWithValues: selected.enumerated().map { ($1, Int32($0)) })
        func text(_ column: String) -> String? {
            guard let position = index[column], let bytes = sqlite3_column_text(statement, position) else { return nil }
            let value = String(cString: bytes)
            return value.isEmpty ? nil : value
        }
        func integer(_ column: String) -> Int64? {
            guard let position = index[column], sqlite3_column_type(statement, position) != SQLITE_NULL else {
                return nil
            }
            return sqlite3_column_int64(statement, position)
        }

        var rows: [CodexThreadRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text("id"), let rolloutPath = text("rollout_path") else { continue }
            let updatedAt = integer("updated_at_ms").map { Double($0) / 1000 } ?? Double(integer("updated_at") ?? 0)
            rows.append(
                CodexThreadRow(
                    id: id, rolloutPath: rolloutPath, cwd: text("cwd"), name: text("name"), title: text("title"),
                    source: text("source") ?? "", originator: text("originator"), gitBranch: text("git_branch"),
                    model: text("model"), reasoningEffort: text("reasoning_effort"),
                    createdAt: integer("created_at").map { Date(timeIntervalSince1970: Double($0)) },
                    updatedAt: Date(timeIntervalSince1970: updatedAt)
                ))
        }
        return rows
    }

    private static func columns(of table: String, in connection: OpaquePointer?) -> Set<String> {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(connection, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { names.insert(String(cString: name)) }
        }
        return names
    }
}

/// Which Codex threads are loaded in a running Codex process right now. Codex keeps
/// `~/.codex/thread-writer-locks/<thread>.lock` open while a process (the CLI, the desktop app's or an IDE's
/// app-server) has the thread loaded, and closes it when the process lets go or exits. The file stays behind, so
/// whether a process holds it open is what counts.
public enum CodexThreadLocks {
    public static var defaultDirectory: URL {
        CodexThreadIndex.defaultCodexDirectory.appending(path: "thread-writer-locks", directoryHint: .isDirectory)
    }

    /// The process holding each loaded thread, by thread ID. Only `codex` processes are asked: the CLI and the
    /// app-servers the desktop app and editors run, all the same executable.
    public static func holders(in directory: URL = defaultDirectory, processes: [ProcessEntry]) -> [String: Int32] {
        var prefix = directory.path(percentEncoded: false)
        if !prefix.hasSuffix("/") { prefix += "/" }
        var holders: [String: Int32] = [:]
        for process in processes where process.name == "codex" {
            for path in ProcessTable.openFiles(of: process.pid, withPrefix: prefix) where path.hasSuffix(".lock") {
                let name = path.dropFirst(prefix.count).dropLast(".lock".count)
                if !name.isEmpty, !name.contains("/") { holders[String(name)] = process.pid }
            }
        }
        return holders
    }
}
