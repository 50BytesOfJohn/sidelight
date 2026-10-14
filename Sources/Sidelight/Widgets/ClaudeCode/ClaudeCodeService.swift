import Foundation
import Observation
import SidelightCore
import os

/// Claude plan limits for every widget that shows them: a ``ClaudeCodeAccount`` for each Claude account one of them
/// uses, shared by all of them, each in the folder Claude Code keeps it in and fetching from Anthropic as often as
/// the most frequent of its widgets asks.
@Observable
final class ClaudeCodeService: DataService {
    /// Where the status line bridge saves each Claude Code folder's status line input.
    static let statusLineDirectory = URL.applicationSupportDirectory.appending(
        path: "Sidelight/Claude Code", directoryHint: .isDirectory)

    /// The bridge script in the app bundle; `nil` when running outside one.
    static var bridgeScriptURL: URL? { Bundle.main.url(forResource: "claude-code-statusline", withExtension: "sh") }

    /// The accounts widgets in the configuration use, while they do.
    private(set) var accounts: [AccountID: ClaudeCodeAccount] = [:]

    /// What the widgets on screen need from each account. Set from the configuration.
    var demand: [AccountID: ClaudeCodeNeeds] = [:] {
        didSet {
            guard demand != oldValue else { return }
            apply()
        }
    }

    /// Hears how each account's sign-in is doing.
    @ObservationIgnored private let access: AccountAccess
    @ObservationIgnored private var isEnabled = false
    /// Counts the checks of each account: only the newest one says how it's doing.
    @ObservationIgnored private var checks: [AccountID: Int] = [:]

    init(accounts: AccountAccess) {
        access = accounts
    }

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        // The watchers need the directory to exist before the bridge first writes to it.
        do {
            try FileManager.default.createDirectory(at: Self.statusLineDirectory, withIntermediateDirectories: true)
        } catch {
            Log.claudeCode.error("Can't create the status line directory: \(error)")
        }
        apply()
    }

    func stop() {
        isEnabled = false
        apply()
    }

    /// The account `id`, while a widget in the configuration uses it.
    func account(_ id: AccountID) -> ClaudeCodeAccount? {
        accounts[id]
    }

    /// The account a widget naming `reference` shows, while a widget in the configuration uses it.
    func account(for reference: AccountID?, in store: AccountStore) -> ClaudeCodeAccount? {
        store.resolve(reference, at: .claudeCode).accountID.flatMap { accounts[$0] }
    }

    // MARK: Checking

    /// Checks the Claude account `id`, kept in `profile`, and says how it's doing and who it's signed in as: Claude
    /// Code says who's signed in, and unless `isQuick`, Anthropic is asked once whether it takes the sign-in, the way
    /// fetching usage does. Runs only when someone asks, or just signed in or opened their accounts: never on a timer.
    func check(_ id: AccountID, in profile: ClaudeCodeProfile, isQuick: Bool = false) async {
        let check = (checks[id] ?? 0) + 1
        checks[id] = check
        // A newer check started meanwhile: what it finds stands, not this.
        func isCurrent() -> Bool { !Task.isCancelled && checks[id] == check }
        guard ClaudeCodeCLI.executable != nil else {
            access.report(.failed("Claude Code isn't installed"), id)
            return
        }
        let status = await ClaudeCodeCLI.authStatus(of: profile)
        guard isCurrent() else { return }
        let identity: ClaudeCodeIdentity
        switch status {
        case nil:
            access.report(.failed("Claude Code didn't say who's signed in"), id)
            return
        case .signedOut?:
            access.reportIdentity(nil, id)
            access.report(.needsSignIn, id)
            return
        case .signedIn(let signedIn)?:
            identity = signedIn
        }
        access.reportIdentity(identity.summary, id)
        guard identity.hasPlan else {
            access.report(.failed("Signed in with an API key, which has no plan limits"), id)
            return
        }
        guard !isQuick else {
            access.report(.connected, id)
            return
        }
        let result = await ClaudeCodeAccount.fetchUsage(profile: profile, userAgent: AppInfo.userAgent)
        guard isCurrent() else { return }
        switch result {
        case .success: access.report(.connected, id)
        case .failure(let problem): access.report(problem.accountStatus, id)
        }
        // What widgets show catches up too, without asking Anthropic again.
        accounts[id]?.checked(result)
    }

    // MARK: Demand

    private func apply() {
        for (id, needs) in demand where accounts[id]?.profile != needs.profile {
            accounts[id]?.stop()
            let access = access
            accounts[id] = ClaudeCodeAccount(
                id: id, profile: needs.profile, report: { access.report($0, id) },
                identify: { access.reportIdentity($0, id) })
        }
        for (id, account) in accounts where demand[id] == nil {
            // No widget uses it any more: what it showed goes.
            account.stop()
            accounts[id] = nil
        }
        for (id, account) in accounts {
            account.refreshInterval = demand[id]?.refreshMinutes.map { .seconds($0 * 60) }
            account.setRunning(isEnabled)
        }
    }
}
