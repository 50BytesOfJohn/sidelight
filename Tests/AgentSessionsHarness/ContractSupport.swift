import AppKit
import Observation
import SidelightCore
import SwiftUI
import os

struct MockApplication {
    let bundleIdentifier: String?
    let localizedName: String?
}

final class MockWorkspace {
    static let shared = MockWorkspace()
    var installed: Set<String> = [AgentSessionOpener.cursorBundleID, CodexSessionOpener.appBundleID]
    var events: [String] = []
    var folderSucceeds = true
    var appSucceeds = true
    func urlForApplication(withBundleIdentifier id: String) -> URL? {
        installed.contains(id) ? URL(filePath: "/synthetic/\(id).app") : nil
    }
    @discardableResult
    func open(_ url: URL) -> Bool {
        events.append("url:\(url.scheme ?? "none")")
        return true
    }
    func open(
        _ urls: [URL], withApplicationAt app: URL, configuration: NSWorkspace.OpenConfiguration
    ) async throws -> Bool {
        events.append("folder:\(urls.first!.lastPathComponent)")
        if !folderSucceeds { throw CocoaError(.fileReadUnknown) }
        return true
    }
    func openApplication(at app: URL, configuration: NSWorkspace.OpenConfiguration) async throws -> Bool {
        events.append("application:\(app.lastPathComponent)")
        if !appSucceeds { throw CocoaError(.fileReadUnknown) }
        return true
    }
}

enum MockHost {
    static var host: MockApplication?
    static var events: [String] = []
    static func app(of pid: Int32) -> MockApplication? { host }
    static func bringForward(
        _ app: MockApplication, pid: Int32, cwd: String?, title: String, opensFolder: Bool, log: Logger
    ) async -> Bool {
        events.append("\(app.localizedName ?? "App"):\(opensFolder):\(cwd ?? "none")")
        return true
    }
    static func copy(_ text: String) { fatalError("Clipboard is outside these tests") }
}

enum MockSound {
    static func beep() { fatalError("Unexpected beep") }
}

enum Log {
    static let codexSessions = Logger(subsystem: "app.getsidelight.harness", category: "codex")
    static let claudeSessions = Logger(subsystem: "app.getsidelight.harness", category: "claude")
    static let cursor = Logger(subsystem: "app.getsidelight.harness", category: "cursor")
}

@Observable final class ClaudeSessionsService {
    var sessions: [ClaudeSession] = []
    var registryExists = true
    var hasLoaded = true
}

@Observable final class CodexSessionsService {
    var sessions: [CodexSession] = []
    var codexFound = true
    var hasLoaded = true
}

// One controlled read seam lets an old cancelled read finish after a newer generation.
// The actual service's scheduling, cancellation and publication bodies are unchanged.
enum ControlledRead {
    static var result: Result<[CursorChat], CursorChatIndex.Failure> = .success([])
    static var holdNext = false
    static var pending: CheckedContinuation<Result<[CursorChat], CursorChatIndex.Failure>, Never>?
    static func read() async -> Result<[CursorChat], CursorChatIndex.Failure> {
        if holdNext {
            holdNext = false
            return await withCheckedContinuation { pending = $0 }
        }
        return result
    }
}

struct ProviderLogo: View {
    let provider: AgentProvider
    let size: CGFloat
    var body: some View { Color.clear.frame(width: size, height: size) }
}

// Content's actual branching is inspected without inventing a parallel decision function.
// This leaf substitutes the unrelated list rendering, checked separately in the real app.
struct AgentSessionList: View {
    let sessions: [AgentSession]
    let limit: Int
    let settings: AgentSessionsSettings
    let now: Date
    let problems: [String]
    var isCompact = false
    var body: some View { Text("Contract list") }
}
