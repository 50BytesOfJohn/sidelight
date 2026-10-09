import Foundation

/// A notification from a coding agent ("finished", "needs input", …), received over local HTTP.
public struct AgentEvent: Identifiable, Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        case finished
        case waiting
        case other(String)

        public init(rawValue: String) {
            switch rawValue {
            case "finished": self = .finished
            case "waiting": self = .waiting
            default: self = .other(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .finished: "finished"
            case .waiting: "waiting"
            case .other(let value): value
            }
        }
    }

    public let id: UUID
    public let source: String
    public let status: Status
    public let message: String
    public let date: Date

    public init(id: UUID = UUID(), source: String, status: Status, message: String, date: Date) {
        self.id = id
        self.source = source
        self.status = status
        self.message = message
        self.date = date
    }

    /// The message, or the status when the agent didn't send one.
    public var summary: String { message.isEmpty ? status.rawValue : message }
}

extension AgentEvent {
    /// JSON body of `POST /event`: `{"source": "claude-code", "status": "finished", "message": "Done in repo"}`.
    /// Every field is optional.
    private struct Payload: Decodable {
        var source: String?
        var status: String?
        var message: String?
    }

    public init(json: Data, receivedAt date: Date) throws {
        let payload = try JSONDecoder().decode(Payload.self, from: json)
        self.init(
            source: payload.source ?? "?",
            status: Status(rawValue: payload.status ?? "?"),
            message: payload.message ?? "",
            date: date
        )
    }
}
