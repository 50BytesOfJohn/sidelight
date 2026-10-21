import CryptoKit
import Foundation
import Observation
import SidelightCore
import os

/// Runware for every Runware widget and its details panel: for each account a widget uses, its balance, usage and
/// models, from Runware's HTTP API. Sidelight only reads: it never runs a generation.
///
/// Each account is a ``RunwareAccount`` of its own, paced on its own and shared by every widget using it: two
/// widgets on one account make one set of requests. Accounts are key accounts, or the Runware CLI's saved key, which
/// Sidelight reads from `~/.runware/config.yaml` and uses exactly like a key account. The CLI is never run.
@Observable
final class RunwareService: DataService {
    typealias Transport = RunwareClient.Transport

    /// Someone's clicks that ask Runware with a key are this far apart at least.
    static let manualActionGap: Duration = .seconds(15)

    /// What the CLI's saved sign-in says, without the key.
    enum CLIStatus: Equatable {
        case signedIn
        case signedOut
        case unreadable
    }

    /// The accounts Runware widgets in the configuration, or the details panel, use, while they do.
    private(set) var accounts: [AccountID: RunwareAccount] = [:]
    /// Where the Runware CLI is installed, if it is.
    private(set) var cliExecutable: URL?
    /// What the CLI's config said the last time it was read; `nil` until then.
    private(set) var cliStatus: CLIStatus?

    var cliIsSignedIn: Bool { cliStatus == .signedIn }

    /// What the widgets on screen and the details panel need. Set from the configuration.
    var demand = RunwareDemand() {
        didSet {
            guard demand != oldValue else { return }
            apply()
        }
    }

    @ObservationIgnored private let client: RunwareClient
    @ObservationIgnored private let access: AccountAccess
    @ObservationIgnored private let manualActionGap: Duration
    @ObservationIgnored private let cliConfigFile: URL
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var watcher: FileWatcher?
    /// ``watcher`` watches the CLI's config, rather than the folder its own folder will be made in.
    @ObservationIgnored private var watchesCLIConfig = false
    @ObservationIgnored private let reload = CoalescedReload()
    /// A SHA-256 of the CLI's key as last read, never the key: another key means another organization, whose data the
    /// old one's must never show as.
    @ObservationIgnored private var cliKeyFingerprint: SHA256Digest??

    /// - Parameters:
    ///   - transport: How requests are sent: `HTTP.send`, unless a test stands in for Runware.
    ///   - accounts: Reads each key account's key, and hears how each account is doing.
    ///   - cliConfigFile: Where the Runware CLI keeps its key.
    init(
        transport: @escaping Transport = { try await HTTP.send($0) }, accounts: AccountAccess,
        manualActionGap: Duration = RunwareService.manualActionGap, cliConfigFile: URL = RunwareCLIConfig.configFile,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        client = RunwareClient(transport: transport, now: now)
        access = accounts
        self.manualActionGap = manualActionGap
        self.cliConfigFile = cliConfigFile
        accounts.observeChanges { [weak self] id in self?.accounts[id]?.keyChanged() }
    }

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        watch()
        apply()
    }

    /// Signing in or out with the CLI is noticed as it happens: its config is watched, or until its folder is made
    /// (the first `runware auth login` makes it), the folder that folder goes in.
    private func watch() {
        let folder = cliConfigFile.deletingLastPathComponent()
        let folderExists = FileManager.default.fileExists(atPath: folder.path(percentEncoded: false))
        guard watcher == nil || folderExists != watchesCLIConfig else { return }
        watchesCLIConfig = folderExists
        watcher = FileWatcher(
            file: folderExists ? cliConfigFile : folder, onMainActor: { [weak self] in self?.lookAroundSoon() })
    }

    func stop() {
        isEnabled = false
        watcher = nil
        watchesCLIConfig = false
        reload.cancel()
        apply()
    }

    /// The account `id`, while a widget or the details panel uses it.
    func account(_ id: AccountID) -> RunwareAccount? {
        accounts[id]
    }

    /// Looks for the CLI's sign-in again, and fetches each account now, or as soon as allowed.
    func refreshNow() {
        lookAroundSoon()
        for account in accounts.values { account.refresh(includingActivity: true) }
    }

    /// Asks Runware about the organization with `candidate`; returns why the key can't be used. Asks once with the
    /// candidate itself, whatever any account's pace: it's a different key, and someone just asked.
    func checkKey(_ candidate: String) async -> RunwareProblem? {
        let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .noKey }
        let uuid = UUID()
        let answer = await client.send(
            RunwareAPI.detailsRequest(key: key, taskUUID: uuid, userAgent: AppInfo.userAgent)
        ) { response, date in
            RunwareAPI.details(response, taskUUID: uuid, fetchedAt: date)
        }
        guard !Task.isCancelled else { return nil }
        if case .failure(let problem) = answer.result { return problem }
        return nil
    }

    // MARK: Demand

    private func apply() {
        for id in demand.keptAccounts where accounts[id] == nil {
            let access = access
            accounts[id] = RunwareAccount(
                id: id, client: client,
                credentials: { [weak self] in await self?.credentials(for: id) ?? .failure(.noKey) },
                report: { access.report($0, id) }, reportIdentity: { access.reportIdentity($0, id) },
                manualActionGap: manualActionGap)
        }
        for (id, account) in accounts where !demand.keptAccounts.contains(id) {
            // No widget uses it any more: what it showed goes. Its key stays the account's.
            account.update(demand: RunwareAccountDemand(), isKept: false, isEnabled: false)
            accounts[id] = nil
        }
        for account in accounts.values {
            account.update(demand: demand.account(account.id), isKept: true, isEnabled: isEnabled)
        }
        lookAroundSoon()
    }

    // MARK: The CLI

    /// Reads the CLI's sign-in, once for a burst of requests.
    private func lookAroundSoon() {
        guard isEnabled else { return }
        reload.request { [weak self] in await self?.lookAround() }
    }

    /// Looks for the CLI and its saved key: local and cheap. Whether it's signed in decides which account widgets
    /// without one of their own use.
    private func lookAround() async {
        guard isEnabled else { return }
        // The folder may have been made, or removed, since.
        watch()
        let executable = ExecutableLocator.find("runware", in: RunwareCLIConfig.executableDirectories)
        let reading = await Self.readCLIConfig(cliConfigFile)
        guard !Task.isCancelled, isEnabled else { return }
        if executable != cliExecutable { cliExecutable = executable }
        noteCLI(reading)
    }

    /// What the CLI's config says now: who's signed in, and whether its key changed since it was last read.
    private func noteCLI(_ reading: RunwareCLIConfig.Reading) {
        let status: CLIStatus =
            switch reading {
            case .signedIn: .signedIn
            case .signedOut: .signedOut
            case .unreadable: .unreadable
            }
        if status != cliStatus {
            cliStatus = status
            Log.runware.notice("Runware CLI: \(reading.description, privacy: .public)")
            switch status {
            // The next fetch says how it's doing.
            case .signedIn: access.report(nil, .runwareCLI)
            case .signedOut: access.report(.needsSignIn, .runwareCLI)
            case .unreadable: access.report(.failed("Can't read the Runware CLI's settings"), .runwareCLI)
            }
        }
        access.reportAppSignIn(.runwareCLI, cliExecutable != nil || status != .signedOut, status == .signedIn)
        let fingerprint = reading.key.map { SHA256.hash(data: Data($0.utf8)) }
        if let previous = cliKeyFingerprint, previous != fingerprint {
            // Signed in with another key, or out, or back in: nothing the old key showed may stay.
            accounts[.runwareCLI]?.keyChanged()
        }
        cliKeyFingerprint = .some(fingerprint)
    }

    @concurrent
    private static func readCLIConfig(_ file: URL) async -> RunwareCLIConfig.Reading {
        RunwareCLIConfig.read(file: file)
    }

    // MARK: Credentials

    /// The key to ask with for `id`: the CLI's, read fresh each time, or the one saved for a key account.
    private func credentials(for id: AccountID) async -> Result<String, RunwareProblem> {
        guard id != .runwareCLI else {
            let reading = await Self.readCLIConfig(cliConfigFile)
            noteCLI(reading)
            switch reading {
            case .signedIn(let key): return .success(key)
            case .signedOut: return .failure(.cliNotSignedIn)
            case .unreadable: return .failure(.cliConfigUnreadable)
            }
        }
        do throws(KeychainUnavailable) {
            return try await access.secret(id).map { .success($0) } ?? .failure(.noKey)
        } catch {
            return .failure(.keychain)
        }
    }
}

/// How Sidelight asks Runware: sends a request through the transport and reads the answer, off the main actor,
/// with the time it came.
nonisolated struct RunwareClient: Sendable {
    /// Sends a request and returns Runware's answer; throws when no answer came back at all.
    typealias Transport = @Sendable (URLRequest) async throws -> HTTP.Response

    let transport: Transport
    /// The wall clock, for UTC days and ages.
    let now: @Sendable () -> Date

    /// What one request came back with, and when.
    struct Answer<Value: Sendable>: Sendable {
        let result: Result<Value, RunwareProblem>
        /// When to try again, if it failed.
        let retry: RetryAdvice
        let date: Date
    }

    /// Sends `request` and reads the answer with `read`, off the main actor.
    @concurrent
    func send<Value: Sendable>(
        _ request: URLRequest, read: @Sendable (HTTP.Response, Date) -> Result<Value, RunwareProblem>
    ) async -> Answer<Value> {
        let response: HTTP.Response
        do {
            response = try await transport(request)
        } catch {
            return Answer(result: .failure(.unreachable), retry: .backoff, date: now())
        }
        let date = now()
        let result = read(response, date)
        switch result {
        case .success:
            return Answer(result: result, retry: .backoff, date: date)
        case .failure(let problem):
            return Answer(
                result: result, retry: RunwareAPI.retryAdvice(for: problem, response: response, now: date), date: date)
        }
    }
}

extension RunwareClient.Answer {
    /// The answer, for a ``RemoteResource``.
    var fetchResult: FetchResult<Value, RunwareProblem> {
        FetchResult(result, retry: retry, at: date)
    }
}
