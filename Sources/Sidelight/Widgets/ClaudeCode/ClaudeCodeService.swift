import Foundation
import Observation
import SidelightCore
import os

/// Claude plan limits (the 5-hour session and the week), from whichever of these is newest:
///
/// - The status line bridge (`Resources/claude-code-statusline.sh`) saves Claude Code's status line input after
///   every response. Live, but the user has to point Claude Code's `statusLine` setting at it.
/// - Claude Code caches what `/usage` last fetched in `~/.claude.json`. No setup, but only as fresh as the last
///   time someone opened `/usage`.
/// - Opt-in: every ``refreshInterval``, Sidelight asks Anthropic itself, signed in as Claude Code is. The only
///   source that also sees usage from claude.ai and other devices while Claude Code is idle.
///
/// Both files are watched, so without the opt-in nothing runs while Claude Code is idle.
@Observable
final class ClaudeCodeService: DataService {
    static let statusLineFileURL = URL.applicationSupportDirectory.appending(
        path: "Sidelight/Claude Code/status-line.json", directoryHint: .notDirectory)
    static let stateFileURL = URL.homeDirectory.appending(path: ".claude.json", directoryHint: .notDirectory)
    /// Claude Code writes its state file several times in a row; read it once that settles.
    static let reloadDelay: Duration = .milliseconds(500)

    /// The bridge script in the app bundle; `nil` when running outside one.
    static var bridgeScriptURL: URL? { Bundle.main.url(forResource: "claude-code-statusline", withExtension: "sh") }

    /// Saved by the status line bridge; `nil` until it has run once.
    private(set) var statusLineUsage: ClaudeCodeUsage?
    private(set) var accountState: ClaudeCodeAccountState?
    /// Both files have been read at least once.
    private(set) var hasLoaded = false
    /// The last usage fetched from Anthropic.
    private(set) var anthropicUsage: ClaudeCodeUsage?
    /// Why the last fetch from Anthropic failed; `nil` after a success.
    private(set) var anthropicProblem: ClaudeCodeFetchProblem?

    /// How often to fetch usage from Anthropic; `nil` not to. Set from the widgets' settings.
    var refreshInterval: Duration? {
        get { schedule.interval }
        set {
            guard newValue != schedule.interval else { return }
            if newValue == nil {
                anthropicUsage = nil
                anthropicProblem = nil
            }
            schedule.interval = newValue
        }
    }

    var usage: ClaudeCodeUsage? {
        ClaudeCodeUsage.newest(ClaudeCodeUsage.newest(statusLineUsage, accountState?.usage), anthropicUsage)
    }
    var plan: String? { accountState?.plan }

    /// Hears how Claude Code's sign-in is doing.
    @ObservationIgnored private let accounts: AccountAccess
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var watchers: [FileWatcher] = []
    @ObservationIgnored private let reload = CoalescedReload()
    @ObservationIgnored private var stateFileModificationDate: Date?
    @ObservationIgnored private let schedule = FetchSchedule(minimumManualGap: .seconds(30), tolerance: .seconds(10))

    init(accounts: AccountAccess) {
        self.accounts = accounts
    }

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        // The watcher needs the directory to exist before the bridge first writes to it.
        do {
            try FileManager.default.createDirectory(
                at: Self.statusLineFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            Log.claudeCode.error("Can't create the status line directory: \(error)")
        }
        watchers = [Self.statusLineFileURL, Self.stateFileURL].compactMap { url in
            FileWatcher(file: url) { [weak self] in self?.scheduleReload() }
        }
        scheduleReload(after: .zero)
        schedule.start { [weak self] in await self?.fetchFromAnthropic() }
    }

    func stop() {
        isEnabled = false
        watchers = []
        reload.cancel()
        schedule.stop()
    }

    /// Coalesces bursts of file events into one read; a change during a read triggers another.
    private func scheduleReload(after delay: Duration = reloadDelay) {
        guard isEnabled else { return }
        reload.request(after: delay) { [weak self] in await self?.reloadNow() }
    }

    private func reloadNow() async {
        let files = await Self.read(
            statusLine: Self.statusLineFileURL,
            state: Self.stateFileURL,
            unlessStateModifiedAt: stateFileModificationDate
        )
        guard !Task.isCancelled else { return }
        statusLineUsage = files.statusLine
        if let state = files.state {
            accountState = state.contents
            stateFileModificationDate = state.modificationDate
        }
        hasLoaded = true
        reportSignIn()
    }

    private struct Files: Sendable {
        var statusLine: ClaudeCodeUsage?
        /// `nil` when the state file hasn't changed since the last read, or couldn't be decoded.
        var state: (contents: ClaudeCodeAccountState?, modificationDate: Date?)?
    }

    /// File I/O and decoding, kept off the main actor. `~/.claude.json` holds all of Claude Code's state, so it's
    /// only decoded when it has changed.
    @concurrent
    private static func read(statusLine: URL, state: URL, unlessStateModifiedAt lastModified: Date?) async -> Files {
        var files = Files()
        if let modified = modificationDate(of: statusLine), let data = try? Data(contentsOf: statusLine) {
            files.statusLine = ClaudeCodeUsage(statusLine: data, capturedAt: modified)
        }
        let modified = modificationDate(of: state)
        guard modified == nil || modified != lastModified else { return files }
        guard let modified, let data = try? Data(contentsOf: state) else {
            files.state = (nil, nil)
            return files
        }
        do {
            files.state = (try ClaudeCodeAccountState(data: data), modified)
        } catch {
            Log.claudeCode.notice("Can't read ~/.claude.json: \(error)")
        }
        return files
    }

    /// Asks the file system each time; `URL.resourceValues` would answer from a cache.
    private nonisolated static func modificationDate(of url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return attributes?[.modificationDate] as? Date
    }

    // MARK: Fetching from Anthropic

    private func fetchFromAnthropic() async -> FetchSchedule.Outcome? {
        let result = await Self.fetchUsage(userAgent: AppInfo.userAgent)
        guard !Task.isCancelled else { return nil }
        switch result {
        case .success(let usage):
            anthropicUsage = usage
            anthropicProblem = nil
            reportSignIn()
            return .succeeded
        case .failure(let problem):
            if problem != anthropicProblem {
                Log.claudeCode.notice("Can't fetch Claude usage from Anthropic: \(String(describing: problem))")
            }
            anthropicProblem = problem
            reportSignIn()
            return .failed
        }
    }

    /// Claude Code's sign-in, as the last fetch from Anthropic found or its state file says.
    private func reportSignIn() {
        guard let status = AccountStatus.claudeCode(fetched: anthropicUsage, problem: anthropicProblem, plan: plan)
        else { return }
        accounts.report(status, .claudeCodeApp)
    }

    /// Reads Claude Code's sign-in afresh each time, since Claude Code renews it every few hours, and holds it only
    /// for this one request. It's never stored or logged.
    @concurrent
    private static func fetchUsage(userAgent: String) async -> Result<ClaudeCodeUsage, ClaudeCodeFetchProblem> {
        guard let credentials = await readCredentials() else { return .failure(.notSignedIn) }
        guard !credentials.isExpired(at: .now) else { return .failure(.signInExpired) }
        let request = ClaudeCodeUsageAPI.request(accessToken: credentials.accessToken, userAgent: userAgent)
        do {
            let response = try await HTTP.send(request)
            return ClaudeCodeUsageAPI.result(status: response.status, body: response.body, receivedAt: .now)
        } catch {
            return .failure(.unreachable)
        }
    }

    /// Through the `security` tool, the way Claude Code saves the item itself, so macOS doesn't ask the user to let
    /// Sidelight in again every time Claude Code renews its sign-in.
    private nonisolated static func readCredentials() async -> ClaudeCodeCredentials? {
        let keychain = await Keychain.genericPassword(service: ClaudeCodeCredentials.keychainService)
        if let keychain, let credentials = try? ClaudeCodeCredentials(data: keychain) { return credentials }
        let file = URL.homeDirectory.appending(path: ".claude/.credentials.json", directoryHint: .notDirectory)
        return (try? Data(contentsOf: file)).flatMap { try? ClaudeCodeCredentials(data: $0) }
    }
}
