import Foundation
import Network
import Observation
import SidelightCore
import os

/// Local HTTP endpoint that coding agents (Claude Code hooks, scripts) post status events to.
///
/// `POST http://127.0.0.1:47821/event` with `{"source": …, "status": "finished" | "waiting" | …, "message": …}`.
/// Bound to the loopback interface only.
@Observable
final class AgentEventServer {
    static let port: UInt16 = 47821
    static let historyLimit = 10
    static let requestTimeout: Duration = .seconds(5)

    /// Newest first.
    private(set) var events: [AgentEvent] = []
    private(set) var isListening = false
    /// Events newer than this count as unread.
    private(set) var lastSeenDate = Date.now

    @ObservationIgnored private var listener: NWListener?

    var unreadCount: Int { events.count { $0.date > lastSeenDate } }
    var latestEvent: AgentEvent? { events.first }

    func markAllSeen() {
        lastSeenDate = .now
    }

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerStateChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            Log.agents.error("Can't create the agent event listener: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isListening = false
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            isListening = true
            Log.agents.info("Listening for agent events on 127.0.0.1:\(Self.port)")
        case .failed(let error):
            isListening = false
            Log.agents.error("Agent event listener failed: \(error)")
        case .cancelled:
            isListening = false
        default:
            break
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
        Task {
            try? await Task.sleep(for: Self.requestTimeout)
            connection.cancel()
        }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] content, _, isComplete, error in
            MainActor.assumeIsolated {
                var buffer = buffer
                if let content { buffer.append(content) }
                switch HTTPRequest.parse(buffer) {
                case .complete(let request):
                    self?.send(self?.response(to: request) ?? .error(.notFound), on: connection)
                case .invalid:
                    self?.send(.error(.badRequest), on: connection)
                case .incomplete where isComplete || error != nil:
                    connection.cancel()
                case .incomplete:
                    self?.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func response(to request: HTTPRequest) -> HTTPResponse {
        guard request.path == "/event" else { return .error(.notFound) }
        guard request.method == "POST" else { return .error(.methodNotAllowed) }
        do {
            record(try AgentEvent(json: request.body, receivedAt: .now))
            return .ok()
        } catch {
            Log.agents.error("Rejected an agent event with an invalid body: \(error)")
            return .error(.badRequest)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func record(_ event: AgentEvent) {
        events.insert(event, at: 0)
        if events.count > Self.historyLimit { events.removeLast(events.count - Self.historyLimit) }
    }
}
