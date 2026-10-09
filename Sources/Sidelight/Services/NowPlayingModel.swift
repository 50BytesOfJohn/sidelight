import Cocoa

// MARK: - Now Playing via `media-control stream`

final class NowPlayingModel: ObservableObject {
    @Published var available = true
    @Published var title = ""
    @Published var artist = ""
    @Published var playing = false
    @Published var artwork: NSImage?
    private var state: [String: Any] = [:]
    private var proc: ChildProcess?
    private var buffer = Data()

    init() { start() }
    static func findTool() -> String? {
        for p in ["/opt/homebrew/bin/media-control", "/usr/local/bin/media-control"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }
    func start() {
        guard let tool = Self.findTool() else { available = false; return }
        guard let p = ChildProcess.spawn(tool, ["stream"], onLine: { [weak self] line in self?.ingest(line) },
                                         onExit: { [weak self] in DispatchQueue.main.async { self?.available = false } }) else { available = false; return }
        proc = p
    }
    /// media-control (perl) spawns a 2nd perl; it runs in its own process group so killpg takes both.
    func stop() { proc?.killGroup() }
    private func ingest(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return }
        let diff = obj["diff"] as? Bool ?? false
        DispatchQueue.main.async { self.apply(payload, diff: diff) }
    }
    private func apply(_ payload: [String: Any], diff: Bool) {
        let oldArt = state["artworkData"] as? String
        if diff { for (k, v) in payload { if v is NSNull { state.removeValue(forKey: k) } else { state[k] = v } } } else { state = payload }
        title = state["title"] as? String ?? ""
        artist = state["artist"] as? String ?? ""
        playing = (state["playing"] as? Bool) ?? ((state["playbackRate"] as? Double ?? 0) > 0)
        let art = state["artworkData"] as? String
        if art != oldArt { artwork = art.flatMap { Data(base64Encoded: $0) }.flatMap { NSImage(data: $0) } }
    }
}

