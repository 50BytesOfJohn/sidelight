import Foundation
import Network

// MARK: - Agent events HTTP server (Network.framework)

struct AgentEvent: Identifiable { let id = UUID(); let source: String; let status: String; let message: String; let date: Date }

final class AgentServer: ObservableObject {
    @Published var events: [AgentEvent] = []
    @Published var listening = false
    /// events newer than this are "unread" (minimal widget badge); tapping the widget marks them seen
    @Published var lastSeen = Date()
    var unread: Int { events.filter { $0.date > lastSeen }.count }
    func markSeen() { lastSeen = Date() }
    private var listener: NWListener?
    init() {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 47821)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { [weak self] st in
                DispatchQueue.main.async { if case .ready = st { self?.listening = true } else if case .failed = st { self?.listening = false } }
            }
            l.newConnectionHandler = { [weak self] c in self?.handle(c) }
            l.start(queue: .main)
            listener = l
        } catch { Log.agents.error("listener failed: \(error)") }
    }
    private func handle(_ c: NWConnection) {
        c.start(queue: .main)
        var buf = Data()
        func readMore() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, err in
                if let data { buf.append(data) }
                if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
                    var len = 0
                    for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
                        len = max(0, min(1_000_000, Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0))
                    }
                    let body = buf[r.upperBound...]
                    if body.count >= len {
                        self.respond(c, head: head, body: Data(body.prefix(len))); return
                    }
                }
                if done || err != nil { c.cancel(); return }
                readMore()
            }
        }
        readMore()
    }
    private func respond(_ c: NWConnection, head: String, body: Data) {
        let first = head.split(separator: "\r\n").first.map(String.init) ?? ""
        var code = "404 Not Found"; var out = "{\"ok\":false}"
        if first.hasPrefix("POST /event") {
            if let j = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                let ev = AgentEvent(source: j["source"] as? String ?? "?", status: j["status"] as? String ?? "?",
                                    message: j["message"] as? String ?? "", date: Date())
                events.insert(ev, at: 0); if events.count > 10 { events.removeLast(events.count - 10) }
                code = "200 OK"; out = "{\"ok\":true}"
            } else { code = "400 Bad Request" }
        }
        let resp = "HTTP/1.1 \(code)\r\nContent-Type: application/json\r\nContent-Length: \(out.utf8.count)\r\nConnection: close\r\n\r\n\(out)"
        c.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in c.cancel() })
    }
}

