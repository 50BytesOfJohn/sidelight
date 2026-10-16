import Foundation

/// Which Docker context a widget shows. Also what connections are kept by: one for each context in use.
public enum DockerContextChoice: Hashable, Sendable, Codable {
    /// Whichever the CLI uses now (`docker context use`).
    case current
    case named(String)
}

/// How Sidelight asks the `docker` CLI for things. Every command reads; none starts, stops or changes anything, and
/// none asks the daemon for more than containers and their stats.
public enum DockerCLI {
    /// Where Docker Desktop, OrbStack, Colima (through Homebrew) and others put `docker`, in the order they're
    /// searched. Apps opened from Finder get a minimal `PATH`, and a login shell is never run to find it.
    public static var searchDirectories: [URL] {
        let home = URL.homeDirectory
        return [
            home.appending(path: ".docker/bin", directoryHint: .isDirectory),
            URL(filePath: "/opt/homebrew/bin", directoryHint: .isDirectory),
            URL(filePath: "/usr/local/bin", directoryHint: .isDirectory),
            home.appending(path: ".orbstack/bin", directoryHint: .isDirectory),
            URL(filePath: "/Applications/Docker.app/Contents/Resources/bin", directoryHint: .isDirectory),
            URL(filePath: "/Applications/OrbStack.app/Contents/MacOS/xbin", directoryHint: .isDirectory),
            home.appending(path: ".local/bin", directoryHint: .isDirectory),
        ]
    }

    public static func locate(fileManager: FileManager = .default) -> URL? {
        ExecutableLocator.find("docker", in: searchDirectories, fileManager: fileManager)
    }

    /// `command` for `context`: with `--context NAME` in front for a named one.
    public static func arguments(_ command: [String], context: DockerContextChoice) -> [String] {
        switch context {
        case .current: command
        case .named(let name): ["--context", name] + command
        }
    }

    /// Every container's full ID, running or not. Unlike `docker ps --format`, it doesn't work out sizes.
    public static let listIDs = ["ps", "-aq", "--no-trunc"]

    /// One line of JSON per container. `State` and `Labels` come whole: CLI 29 runs templates against a plain map,
    /// where `{{.State.Health}}` fails the whole command for a container without a healthcheck. The environment is
    /// left out, so secrets in it never reach Sidelight.
    public static let inspectTemplate =
        #"{"id":{{json .Id}},"name":{{json .Name}},"image":{{json .Config.Image}},"state":{{json .State}},"#
        + #""restartCount":{{json .RestartCount}},"labels":{{json .Config.Labels}},"#
        + #""ports":{{json .NetworkSettings.Ports}}}"#

    public static func inspect(_ ids: [String]) -> [String] {
        ["container", "inspect", "--format", inspectTemplate] + ids
    }

    /// The container events that change what the widget shows. `exec_*` are left out: healthchecks fire them on
    /// every probe.
    public static let watchedEvents = [
        "create", "start", "restart", "die", "pause", "unpause", "destroy", "rename", "health_status", "oom",
    ]

    /// A line for each container event from `since` on, replaying any since then, then live. What's printed doesn't
    /// matter: any line means "read again".
    public static func events(since: Date) -> [String] {
        ["events", "--filter", "type=container"] + watchedEvents.flatMap { ["--filter", "event=\($0)"] }
            + ["--format", "{{.Action}}", "--since", String(Int(since.timeIntervalSince1970.rounded(.down)))]
    }

    /// CPU and memory of `ids`, once. Streaming `docker stats` writes terminal escape codes even with `--format`.
    public static func stats(_ ids: [String]) -> [String] {
        [
            "stats", "--no-stream", "--no-trunc", "--format",
            #"{"id":{{json .ID}},"cpu":{{json .CPUPerc}},"mem":{{json .MemUsage}},"memPerc":{{json .MemPerc}}}"#,
        ] + ids
    }

    /// Reads files only, never the daemon.
    public static let listContexts = ["context", "ls", "--format", "{{json .}}"]
}

/// One Docker context: where the CLI finds a daemon.
public struct DockerContext: Identifiable, Hashable, Sendable {
    public var name: String
    /// `unix:///Users/…/.docker/run/docker.sock`, `ssh://…`, …
    public var endpoint: String?
    public var isCurrent: Bool
    /// Why the CLI can't use it, in its own words.
    public var error: String?

    public init(name: String, endpoint: String? = nil, isCurrent: Bool = false, error: String? = nil) {
        self.name = name
        self.endpoint = endpoint
        self.isCurrent = isCurrent
        self.error = error
    }

    public var id: String { name }

    /// `Docker Desktop`, `OrbStack` or `Colima` for theirs; otherwise the name.
    public var displayName: String {
        switch name {
        case "desktop-linux": "Docker Desktop"
        case "orbstack": "OrbStack"
        case "colima": "Colima"
        case _ where name.hasPrefix("colima-"): "Colima"
        default: name
        }
    }

    /// The socket of a `unix://` endpoint, to watch for a runtime coming up.
    public var socketURL: URL? {
        guard let endpoint, endpoint.hasPrefix("unix://") else { return nil }
        let path = String(endpoint.dropFirst("unix://".count))
        return path.isEmpty ? nil : URL(filePath: path, directoryHint: .notDirectory)
    }

    /// The contexts in the output of ``DockerCLI/listContexts``, one JSON object per line.
    public static func list(output: Data) -> [DockerContext] {
        let decoder = JSONDecoder()
        return output.split(separator: 0x0A).compactMap { line in
            (try? decoder.decode(Payload.self, from: Data(line)))?.context
        }
    }

    private struct Payload: Decodable {
        var context: DockerContext?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            guard let name = container.lenient(String.self, "Name"), !name.isEmpty else { return }
            func text(_ key: String) -> String? {
                container.lenient(String.self, key).flatMap { $0.isEmpty ? nil : $0 }
            }
            context = DockerContext(
                name: name, endpoint: text("DockerEndpoint"),
                isCurrent: container.lenient(Bool.self, "Current") ?? false,
                error: text("Error"))
        }
    }
}

/// One container's CPU and memory, from ``DockerCLI/stats(_:)``.
public struct DockerStats: Hashable, Sendable {
    public var cpuPercent: Double?
    public var memoryBytes: Int64?
    public var memoryPercent: Double?

    public init(cpuPercent: Double? = nil, memoryBytes: Int64? = nil, memoryPercent: Double? = nil) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.memoryPercent = memoryPercent
    }

    /// By full container ID. `--` and other odd values read as unknown.
    public static func list(output: Data) -> [String: DockerStats] {
        let decoder = JSONDecoder()
        var stats: [String: DockerStats] = [:]
        for line in output.split(separator: 0x0A) {
            guard let payload = try? decoder.decode(Payload.self, from: Data(line)) else { continue }
            stats[payload.id] = payload.stats
        }
        return stats
    }

    private struct Payload: Decodable {
        var id: String
        var stats: DockerStats

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            guard let id = container.lenient(String.self, "id"), !id.isEmpty else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "No ID"))
            }
            self.id = id
            let memory = container.lenient(String.self, "mem")?.split(separator: "/").first.map(String.init)
            stats = DockerStats(
                cpuPercent: DockerStats.percent(container.lenient(String.self, "cpu")),
                memoryBytes: memory.flatMap(DockerStats.bytes),
                memoryPercent: DockerStats.percent(container.lenient(String.self, "memPerc")))
        }
    }

    /// `0.54%` → 0.54.
    static func percent(_ text: String?) -> Double? {
        guard let text else { return nil }
        let number = text.trimmingCharacters(in: .whitespaces).replacing("%", with: "")
        guard let value = Double(number), value.isFinite else { return nil }
        return value
    }

    /// `18.99MiB`, `512kB`, `1.2GB`, `0B` → bytes.
    static func bytes(_ text: String) -> Int64? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let unitStart = text.firstIndex(where: { $0.isLetter }) else { return nil }
        guard let value = Double(text[..<unitStart]), value.isFinite, value >= 0 else { return nil }
        let multiplier: Double? =
            switch text[unitStart...].lowercased() {
            case "b": 1
            case "kib": 1024
            case "mib": 1024 * 1024
            case "gib": 1024 * 1024 * 1024
            case "tib": 1024 * 1024 * 1024 * 1024
            case "kb": 1e3
            case "mb": 1e6
            case "gb": 1e9
            case "tb": 1e12
            default: nil
            }
        return multiplier.map { Int64(value * $0) }
    }
}

/// Why `docker` couldn't answer, from what it printed on standard error.
public enum DockerProblem: Error, Hashable, Sendable {
    /// No daemon at the context's endpoint: Docker Desktop, OrbStack or Colima isn't running.
    case notRunning
    /// The widget's context doesn't exist (any more).
    case contextMissing(String)
    case permissionDenied
    /// It didn't answer in time; Docker Desktop can hang while it starts.
    case timedOut
    /// Anything else, in the CLI's own words.
    case failed(String)

    public init(message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        if let match = trimmed.firstMatch(of: /context "([^"]+)"(?:: context not found| does not exist)/) {
            self = .contextMissing(String(match.1))
        } else if lowercased.contains("permission denied") {
            self = .permissionDenied
        } else if lowercased.contains("cannot connect to the docker daemon")
            || lowercased.contains("failed to connect to the docker api")
            || lowercased.contains("is the docker daemon running") || lowercased.contains("connection refused")
            || (lowercased.contains("no such file or directory") && lowercased.contains(".sock"))
        {
            self = .notRunning
        } else {
            let line = trimmed.split(separator: "\n").first.map(String.init) ?? ""
            self = .failed(line.isEmpty ? "Docker didn't answer." : String(line.prefix(300)))
        }
    }
}
