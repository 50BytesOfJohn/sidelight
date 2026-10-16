import Foundation

/// One container, as `docker container inspect` describes it through ``DockerCLI/inspect(_:)``'s template. Its
/// environment is never asked for, so secrets in it never reach Sidelight.
public struct DockerContainer: Identifiable, Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case created, running, paused, restarting, removing, exited, dead
        /// A state this version doesn't know, in Docker's own words.
        case other(String)

        public init(status: String) {
            self =
                switch status.lowercased() {
                case "created": .created
                case "running": .running
                case "paused": .paused
                case "restarting": .restarting
                case "removing": .removing
                case "exited": .exited
                case "dead": .dead
                default: .other(status)
                }
        }
    }

    public enum Health: Hashable, Sendable {
        /// The image has no healthcheck.
        case none
        case starting, healthy, unhealthy
    }

    /// The full ID.
    public var id: String
    /// Without the leading `/` Docker keeps.
    public var name: String
    public var image: String
    public var state: State
    public var health: Health
    /// `nil` for a container that never started.
    public var startedAt: Date?
    public var finishedAt: Date?
    public var exitCode: Int
    public var oomKilled: Bool
    public var restartCount: Int
    /// Its Compose project (`com.docker.compose.project`).
    public var project: String?
    /// Its Compose service (`com.docker.compose.service`).
    public var service: String?
    /// Published ports only, IPv4 and IPv6 bindings merged, by host port.
    public var ports: [DockerPort]

    public init(
        id: String, name: String, image: String = "", state: State, health: Health = .none, startedAt: Date? = nil,
        finishedAt: Date? = nil, exitCode: Int = 0, oomKilled: Bool = false, restartCount: Int = 0,
        project: String? = nil, service: String? = nil, ports: [DockerPort] = []
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.health = health
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.oomKilled = oomKilled
        self.restartCount = restartCount
        self.project = project
        self.service = service
        self.ports = ports
    }

    /// Its Compose service, or else its name.
    public var displayName: String { service ?? name }
    public var shortID: String { String(id.prefix(12)) }
}

/// A container port published on the host.
public struct DockerPort: Hashable, Sendable {
    public var hostPort: Int
    public var containerPort: Int
    /// `tcp`, `udp` or `sctp`.
    public var transport: String
    /// `0.0.0.0`, `127.0.0.1`, …: the first of a merged IPv4/IPv6 pair.
    public var hostIP: String

    public init(hostPort: Int, containerPort: Int, transport: String = "tcp", hostIP: String = "0.0.0.0") {
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.transport = transport
        self.hostIP = hostIP
    }

    /// Where a browser reaches it; `nil` for UDP and other transports.
    public var browserURL: URL? { transport == "tcp" ? URL(string: "http://localhost:\(hostPort)") : nil }
    /// `:3000`, or `:8080→80` when the container listens on another port.
    public var label: String { hostPort == containerPort ? ":\(hostPort)" : ":\(hostPort)→\(containerPort)" }
}

extension DockerContainer {
    /// The containers in the output of ``DockerCLI/inspect(_:)``, one per line. Lines that don't decode, or have no
    /// ID, are skipped.
    public static func list(inspectOutput: Data) -> [DockerContainer] {
        let decoder = JSONDecoder()
        return inspectOutput.split(separator: 0x0A).compactMap { line in
            (try? decoder.decode(Payload.self, from: Data(line)))?.container
        }
    }

    private struct Payload: Decodable {
        var container: DockerContainer?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            guard let id = container.lenient(String.self, "id"), !id.isEmpty else { return }
            let state = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("state"))
            let health = try? state?.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("Health"))
            let labels = container.lenient([String: String].self, "labels") ?? [:]
            var name = container.lenient(String.self, "name") ?? ""
            if name.hasPrefix("/") { name.removeFirst() }
            self.container = DockerContainer(
                id: id,
                name: name.isEmpty ? String(id.prefix(12)) : name,
                image: container.lenient(String.self, "image") ?? "",
                state: State(status: state?.lenient(String.self, "Status") ?? ""),
                health: Health(status: health?.lenient(String.self, "Status")),
                startedAt: Self.date(state?.lenient(String.self, "StartedAt")),
                finishedAt: Self.date(state?.lenient(String.self, "FinishedAt")),
                exitCode: state?.lenientInt64("ExitCode").flatMap { Int(exactly: $0) } ?? 0,
                oomKilled: state?.lenient(Bool.self, "OOMKilled") ?? false,
                restartCount: container.lenientInt64("restartCount").flatMap { Int(exactly: $0) } ?? 0,
                project: labels["com.docker.compose.project"].flatMap { $0.isEmpty ? nil : $0 },
                service: labels["com.docker.compose.service"].flatMap { $0.isEmpty ? nil : $0 },
                ports: DockerPort.published(container.lenient([String: [Binding]?].self, "ports") ?? [:]))
        }

        /// Docker writes `0001-01-01T00:00:00Z` for a moment that hasn't happened.
        private static func date(_ text: String?) -> Date? {
            guard let text, !text.hasPrefix("0001-"), let date = Date(iso8601: text) else { return nil }
            return date
        }
    }

    /// One host binding of a port, as inspect lists them.
    fileprivate struct Binding: Decodable {
        var hostIP: String
        var hostPort: Int?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            hostIP = container.lenient(String.self, "HostIp") ?? ""
            hostPort = container.lenient(String.self, "HostPort").flatMap { Int($0) }
        }
    }
}

extension DockerContainer.Health {
    init(status: String?) {
        self =
            switch status?.lowercased() {
            case "starting": .starting
            case "healthy": .healthy
            case "unhealthy": .unhealthy
            default: .none
            }
    }
}

extension DockerPort {
    /// The published ports in inspect's `NetworkSettings.Ports` (`"80/tcp": [{"HostIp", "HostPort"}]`, or `null`
    /// when unpublished): one per host port and transport, so an IPv4 and IPv6 pair shows once.
    fileprivate static func published(_ ports: [String: [DockerContainer.Binding]?]) -> [DockerPort] {
        var merged: [DockerPort] = []
        for (key, bindings) in ports.sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: "/", maxSplits: 1)
            guard let containerPort = parts.first.flatMap({ Int($0) }) else { continue }
            let transport = parts.count > 1 ? String(parts[1]) : "tcp"
            for binding in bindings ?? [] {
                guard let hostPort = binding.hostPort, hostPort > 0 else { continue }
                guard !merged.contains(where: { $0.hostPort == hostPort && $0.transport == transport }) else {
                    continue
                }
                merged.append(
                    DockerPort(
                        hostPort: hostPort, containerPort: containerPort, transport: transport,
                        hostIP: binding.hostIP))
            }
        }
        return merged.sorted { ($0.hostPort, $0.transport) < ($1.hostPort, $1.transport) }
    }
}
