import Foundation
import CoreServices

// MARK: - Codex usage: `codex app-server` JSON-RPC (primary) / rollout jsonl (fallback)

final class CodexModel: ObservableObject {
    struct Window: Equatable { var usedPercent: Double; var resetsAt: Date?; var windowMins: Int }
    @Published var fiveHour: Window?
    @Published var weekly: Window?
    @Published var plan: String?
    @Published var resetCredits: Int?
    @Published var lifetimeTokens: Int64?
    @Published var todayTokens: Int64?
    @Published var sessionTokens: Int64?        // fallback only (rollout total_token_usage)
    @Published var daily: [Int64] = []          // last 14 days, oldest first
    @Published var source = "off"               // "app-server" | "rollout file" | "unavailable" | "off"
    @Published var lastUpdate: Date?

    private var child: ChildProcess?
    private var nextId = 10
    private var pending: [Int: String] = [:]
    private var timer: Timer?
    private var watchdog: DispatchWorkItem?
    private var fsStream: FSEventStreamRef?
    var enabled = false

    static func findCodex() -> String? {
        for p in ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", NSHomeDirectory() + "/.local/bin/codex"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    func start() {
        enabled = true
        guard child == nil else { return }
        source = "starting…"
        guard let path = Self.findCodex(),
              let c = ChildProcess.spawn(path, ["app-server"],
                                         onLine: { [weak self] l in self?.handle(l) },
                                         onExit: { [weak self] in DispatchQueue.main.async { self?.appServerDied() } })
        else { startFallback(); return }
        child = c
        c.send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["clientInfo": ["name": "sidelight", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"]]])
        c.send(["jsonrpc": "2.0", "method": "initialized"])
        readAll()
        // if app-server doesn't deliver rate limits in 15 s, use the rollout file
        let w = DispatchWorkItem { [weak self] in if self?.source != "app-server" { self?.startFallback() } }
        watchdog = w; DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: w)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.readAll() }
        timer?.tolerance = 5
    }

    func stop() {
        enabled = false
        timer?.invalidate(); timer = nil
        child?.killGroup(); child = nil
        if let s = fsStream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); fsStream = nil }
        source = "off"
    }

    /// READ-ONLY methods only. Never call account/rateLimitResetCredit/consume, login/logout, thread/turn start, …
    private func readAll() {
        guard let c = child else { return }
        for m in ["account/rateLimits/read", "account/usage/read"] {
            nextId += 1; pending[nextId] = m
            c.send(["jsonrpc": "2.0", "id": nextId, "method": m])
        }
    }

    private func appServerDied() {
        child = nil
        if source != "off" { startFallback() }
        // try app-server again in 5 min
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            guard let self, self.enabled, self.child == nil else { return }
            self.start()
        }
    }

    private func handle(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        DispatchQueue.main.async { self.dispatch(obj) }
    }

    private func dispatch(_ obj: [String: Any]) {
        if let id = obj["id"] as? Int, let method = pending.removeValue(forKey: id), let result = obj["result"] as? [String: Any] {
            switch method {
            case "account/rateLimits/read":
                if let rl = result["rateLimits"] as? [String: Any] { applyRateLimits(rl, camel: true) }
                if let rc = result["rateLimitResetCredits"] as? [String: Any] { resetCredits = rc["availableCount"] as? Int }
                markAppServer()
            case "account/usage/read":
                if let sum = result["summary"] as? [String: Any] { lifetimeTokens = (sum["lifetimeTokens"] as? NSNumber)?.int64Value }
                if let b = result["dailyUsageBuckets"] as? [[String: Any]] { applyBuckets(b) }
            default: break
            }
        } else if let method = obj["method"] as? String, let params = obj["params"] as? [String: Any] {
            if method == "account/rateLimits/updated", let rl = params["rateLimits"] as? [String: Any] { applyRateLimits(rl, camel: true); markAppServer() }
            if method == "account/updated", let p = params["planType"] as? String { plan = p }
        }
    }

    private func markAppServer() {
        source = "app-server"; lastUpdate = Date(); watchdog?.cancel()
        if let s = fsStream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); fsStream = nil }
    }

    private func applyRateLimits(_ rl: [String: Any], camel: Bool) {
        func win(_ d: Any?) -> Window? {
            guard let d = d as? [String: Any] else { return nil }
            let used = (d[camel ? "usedPercent" : "used_percent"] as? NSNumber)?.doubleValue ?? 0
            let reset = (d[camel ? "resetsAt" : "resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let mins = (d[camel ? "windowDurationMins" : "window_minutes"] as? NSNumber)?.intValue ?? 0
            return Window(usedPercent: used, resetsAt: reset, windowMins: mins)
        }
        fiveHour = win(rl["primary"]); weekly = win(rl["secondary"])
        if let p = rl[camel ? "planType" : "plan_type"] as? String { plan = p }
    }

    private func applyBuckets(_ b: [[String: Any]]) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        var map: [String: Int64] = [:]
        for x in b { if let d = x["startDate"] as? String, let t = (x["tokens"] as? NSNumber)?.int64Value { map[d] = t } }
        let cal = Calendar.current; let today = cal.startOfDay(for: Date())
        daily = (0..<14).reversed().map { i in map[f.string(from: cal.date(byAdding: .day, value: -i, to: today)!)] ?? 0 }
        todayTokens = map[f.string(from: today)] ?? 0
    }

    // MARK: fallback: newest ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl, last "token_count" line; watched via FSEvents

    private var sessionsDir: String { NSHomeDirectory() + "/.codex/sessions" }

    private func startFallback() {
        parseRollout()
        guard fsStream == nil else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            let me = Unmanaged<CodexModel>.fromOpaque(info!).takeUnretainedValue()
            DispatchQueue.main.async { if me.source != "app-server" { me.parseRollout() } }
        }
        if let s = FSEventStreamCreate(nil, cb, &ctx, [sessionsDir] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
                                       FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) {
            FSEventStreamSetDispatchQueue(s, .main); FSEventStreamStart(s); fsStream = s
        }
    }

    private func newestRollout() -> String? {
        let fm = FileManager.default
        func sortedDirs(_ p: String) -> [String] { ((try? fm.contentsOfDirectory(atPath: p)) ?? []).filter { Int($0) != nil }.sorted(by: >) }
        for y in sortedDirs(sessionsDir) { for m in sortedDirs("\(sessionsDir)/\(y)") { for d in sortedDirs("\(sessionsDir)/\(y)/\(m)") {
            let dir = "\(sessionsDir)/\(y)/\(m)/\(d)"
            let files = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
            let newest = files.map { "\(dir)/\($0)" }.max { a, b in
                ((try? fm.attributesOfItem(atPath: a)[.modificationDate] as? Date) ?? .distantPast) <
                ((try? fm.attributesOfItem(atPath: b)[.modificationDate] as? Date) ?? .distantPast) }
            if let newest { return newest }
        } } }
        return nil
    }

    func parseRollout() {
        guard let path = newestRollout(), let h = FileHandle(forReadingAtPath: path) else { source = "unavailable"; return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 512_000 ? size - 512_000 : 0)
        let data = h.readDataToEndOfFile()
        let needle = Data("\"type\":\"token_count\"".utf8)
        // last line containing token_count with rate_limits
        for line in data.split(separator: 0x0A).reversed() where line.range(of: needle) != nil {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any], let rl = payload["rate_limits"] as? [String: Any] else { continue }
            applyRateLimits(rl, camel: false)
            if let info = payload["info"] as? [String: Any], let tot = info["total_token_usage"] as? [String: Any] {
                sessionTokens = (tot["total_tokens"] as? NSNumber)?.int64Value
            }
            source = "rollout file"; lastUpdate = Date(); return
        }
        source = "unavailable"
    }
}
