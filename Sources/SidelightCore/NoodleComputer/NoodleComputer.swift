import Foundation

/// One computer in Noodle Computer (Linux, Local Mac or Windows), as its `noodle-computer` tool describes it to apps
/// outside Noodle. Each app sees only computers the person lent it or it created.
///
/// The tool is new and its output isn't a documented format, so it's read leniently: a field that's missing or of
/// another type reads as unknown rather than dropping the computer.
public struct NoodleComputer: Identifiable, Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case running
        case starting
        case stopping
        case stopped
        /// Fetching a newer image; it restarts afterwards.
        case upgrading
        /// A Local Mac waiting to be approved or set up.
        case needsSetup
        /// It failed to start.
        case needsAttention
        /// A state this version doesn't know, in Noodle Computer's own words.
        case other(String)
    }

    public var id: UUID
    public var name: String
    /// What the person keeps it for.
    public var description: String?
    /// `Desktop`, `Shell`, `Local Mac`, `Windows`, …
    public var kind: String
    public var state: State
    /// An SF Symbols name.
    public var symbol: String
    /// One of Noodle's icon gradients, by index.
    public var colour: Int
    /// A picture the person chose instead of the symbol.
    public var icon: Data?
    /// It has a desktop to show; otherwise it opens in its terminal.
    public var hasDesktop: Bool

    public init(
        id: UUID, name: String, description: String? = nil, kind: String, state: State,
        symbol: String = "desktopcomputer", colour: Int = 0, icon: Data? = nil, hasDesktop: Bool = true
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.kind = kind
        self.state = state
        self.symbol = symbol
        self.colour = colour
        self.icon = icon
        self.hasDesktop = hasDesktop
    }

    /// Opens the computer in Noodle Computer, on its desktop or in its terminal, and starts it if it's stopped. The
    /// link carries no authority: Noodle Computer opens any of the person's own computers this way.
    public var openURL: URL {
        var components = URLComponents()
        components.scheme = "noodlecomputer"
        components.host = id.uuidString.lowercased()
        components.queryItems = [URLQueryItem(name: "view", value: hasDesktop ? "web" : "terminal")]
        return components.url!
    }

    /// The computers in the output of `noodle-computer list` (or `borrow`): `{"computers": [...]}`. `nil` for output
    /// that isn't such a list. Entries without an ID or name are skipped.
    public static func list(json: Data) -> [NoodleComputer]? {
        (try? JSONDecoder().decode(ListPayload.self, from: json))?.computers.compactMap(\.computer)
    }

    private struct ListPayload: Decodable {
        var computers: [Payload]
    }

    private struct Payload: Decodable {
        var computer: NoodleComputer?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            guard let id = container.lenient(String.self, "id").flatMap(UUID.init(uuidString:)),
                let name = container.lenient(String.self, "name")
            else { return }
            let description = container.lenient(String.self, "description")
            computer = NoodleComputer(
                id: id,
                name: name,
                description: description.flatMap { $0.isEmpty ? nil : $0 },
                kind: container.lenient(String.self, "kind") ?? "",
                state: State(label: container.lenient(String.self, "state") ?? ""),
                symbol: container.lenient(String.self, "symbol") ?? "desktopcomputer",
                colour: container.lenientInt64("colour").flatMap { Int(exactly: $0) } ?? 0,
                icon: container.lenient(Data.self, "icon"),
                hasDesktop: container.lenient(Bool.self, "hasWebDisplay") ?? true
            )
        }
    }
}

extension NoodleComputer.State {
    /// Noodle Computer reports states by their label in its window (`Running`, `Starting…`), not a stable code.
    public init(label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let word = trimmed.replacing("…", with: "").replacing("...", with: "").lowercased()
        self =
            switch word {
            case "running": .running
            case "starting": .starting
            case "stopping": .stopping
            case "stopped": .stopped
            case "upgrading", "updating": .upgrading
            case "approval required", "setup required": .needsSetup
            case "needs attention": .needsAttention
            default: .other(trimmed)
            }
    }

    /// Starting, stopping or upgrading: worth checking on again soon.
    public var isChanging: Bool {
        switch self {
        case .starting, .stopping, .upgrading: true
        default: false
        }
    }

    /// Noodle Computer starts it when it's opened or asked to.
    public var canStart: Bool {
        switch self {
        case .stopped, .needsAttention, .needsSetup: true
        default: false
        }
    }
}

/// Why `noodle-computer` couldn't answer, from the message it prints on standard error.
public enum NoodleComputerProblem: Error, Hashable, Sendable {
    /// Settings › Agents › Allow agents is off in Noodle Computer.
    case agentsOff
    /// The person didn't let Sidelight in, or removed it in Noodle Computer's settings.
    case notAllowed
    /// The person was asked to lend a computer and didn't.
    case notLent
    /// Every computer the person has is already lent.
    case nothingToLend
    /// Anything else, in the tool's own words.
    case failed(String)

    public init(message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "noodle-computer: "
        let message = trimmed.hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : trimmed
        self =
            if message.contains("not accepting agents") || message.contains("Agents are turned off") {
                .agentsOff
            } else if message.contains("was not allowed") || message.contains("access was removed") {
                .notAllowed
            } else if message.contains("Nothing was lent") {
                .notLent
            } else if message.contains("nothing else to lend") {
                .nothingToLend
            } else {
                .failed(message.isEmpty ? "Noodle Computer didn't answer." : message)
            }
    }
}
