import Foundation
import Observation
import SidelightCore
import os

/// One Claude account's plan limits (the 5-hour session and the week), from whichever of these is newest:
///
/// - The status line bridge (`Resources/claude-code-statusline.sh`) saves Claude Code's status line input after
///   every response, a file for each of Claude Code's folders. Live, but the user has to point Claude Code's
///   `statusLine` setting at it.
/// - Claude Code caches what `/usage` last fetched in its state file. No setup, but only as fresh as the last time
///   someone opened `/usage`.
/// - Opt-in: every ``refreshInterval``, Sidelight asks Anthropic itself, signed in as Claude Code is. The only
///   source that also sees usage from claude.ai and other devices while Claude Code is idle.
///
/// Both files are watched, so without the opt-in nothing runs while Claude Code is idle. Every widget showing the
/// account shares it.
@Observable
final class ClaudeCodeAccount: DataService {
    /// Claude Code writes its state file several times in a row; read it once that settles.
    static let reloadDelay: Duration = .milliseconds(500)

    let id: AccountID
    /// Where Claude Code keeps the account.
    let profile: ClaudeCodeProfile
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

    /// Where the status line bridge saves this account's status line input.
    var statusLineFileURL: URL {
        ClaudeCodeService.statusLineDirectory.appending(path: profile.statusLineFileName, directoryHint: .notDirectory)
    }

    /// Says how the account's sign-in is doing.
    @ObservationIgnored private let report: (AccountStatus) -> Void
    /// Says who the account is signed in as.
    @ObservationIgnored private let identify: (String?) -> Void
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var watchers: [FileWatcher] = []
    @ObservationIgnored private let reload = CoalescedReload()
    @ObservationIgnored private var stateFileModificationDate: Date?
    @ObservationIgnored private let schedule = FetchSchedule(minimumManualGap: .seconds(30), tolerance: .seconds(10))

    init(
        id: AccountID, profile: ClaudeCodeProfile, report: @escaping (AccountStatus) -> Void = { _ in },
        identify: @escaping (String?) -> Void = { _ in }
    ) {
        self.id = id
        self.profile = profile
        self.report = report
        self.identify = identify
    }

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        watchers = [statusLineFileURL, profile.stateFileURL].compactMap { url in
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

    /// Reads the files again, and asks Anthropic again if someone opted in: after signing in again, say.
    func refreshNow() {
        scheduleReload(after: .zero)
        schedule.reset()
        schedule.refreshNow()
    }

    /// Coalesces bursts of file events into one read; a change during a read triggers another.
    private func scheduleReload(after delay: Duration = reloadDelay) {
        guard isEnabled else { return }
        reload.request(after: delay) { [weak self] in await self?.reloadNow() }
    }

    private func reloadNow() async {
        let files = await Self.read(
            statusLine: statusLineFileURL, state: profile.stateFileURL,
            unlessStateModifiedAt: stateFileModificationDate)
        guard !Task.isCancelled else { return }
        statusLineUsage = files.statusLine
        if let state = files.state {
            accountState = state.contents
            stateFileModificationDate = state.modificationDate
            identify(ClaudeCodeIdentity.summary(email: state.contents?.email, plan: state.contents?.plan))
        }
        hasLoaded = true
        reportSignIn()
    }

    private struct Files: Sendable {
        var statusLine: ClaudeCodeUsage?
        /// `nil` when the state file hasn't changed since the last read, or couldn't be decoded.
        var state: (contents: ClaudeCodeAccountState?, modificationDate: Date?)?
    }

    /// File I/O and decoding, kept off the main actor. The state file holds all of Claude Code's state, so it's only
    /// decoded when it has changed.
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
            Log.claudeCode.notice("Can't read Claude Code's state file: \(error)")
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
        let result = await Self.fetchUsage(profile: profile, userAgent: AppInfo.userAgent)
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

    /// The sign-in, as the last fetch from Anthropic found or the state file says.
    private func reportSignIn() {
        guard let status = AccountStatus.claudeCode(fetched: anthropicUsage, problem: anthropicProblem, plan: plan)
        else { return }
        report(status)
    }

    /// Reads Claude Code's sign-in afresh each time, since Claude Code renews it every few hours, and holds it only
    /// for this one request. It's never stored or logged.
    @concurrent
    static func fetchUsage(
        profile: ClaudeCodeProfile, userAgent: String
    ) async -> Result<ClaudeCodeUsage, ClaudeCodeFetchProblem> {
        guard let credentials = await readCredentials(of: profile) else { return .failure(.notSignedIn) }
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
    private nonisolated static func readCredentials(of profile: ClaudeCodeProfile) async -> ClaudeCodeCredentials? {
        let keychain = await Keychain.genericPassword(service: profile.keychainService)
        if let keychain, let credentials = try? ClaudeCodeCredentials(data: keychain) { return credentials }
        return (try? Data(contentsOf: profile.credentialsFileURL)).flatMap { try? ClaudeCodeCredentials(data: $0) }
    }
}
