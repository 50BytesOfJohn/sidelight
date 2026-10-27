import Foundation

// How the app sign-ins Sidelight reads are doing, from what their services last found. Nothing here reads a sign-in:
// the services keep doing that, as they always did.

extension ClaudeCodeFetchProblem {
    public var accountStatus: AccountStatus {
        switch self {
        case .notSignedIn: .needsSignIn
        case .signInExpired: .expired
        case .rejected(let status) where status == 401 || status == 403: .expired
        case .rejected, .unreachable, .unreadable: .failed(message)
        }
    }
}

extension CursorFetchProblem {
    public var accountStatus: AccountStatus {
        switch self {
        case .notSignedIn: .needsSignIn
        case .signInExpired: .expired
        case .rejected where isSignInRejection: .expired
        case .rejected, .unreachable, .unreadable: .failed(title)
        }
    }
}

extension AccountStatus {
    /// Claude Code's sign-in: what the last fetch from Anthropic found, when someone opted in to it; otherwise
    /// signed in once its state file names a plan. `nil` until something tells.
    public static func claudeCode(
        fetched: ClaudeCodeUsage?, problem: ClaudeCodeFetchProblem?, plan: String?
    ) -> AccountStatus? {
        if let problem { return problem.accountStatus }
        if fetched != nil || plan != nil { return .connected }
        return nil
    }

    /// Codex's sign-in: signed in once its app-server says who as, not once it answers without anyone.
    public static func codex(_ state: CodexState) -> AccountStatus? {
        if let problem = state.problem { return .failed(problem) }
        if state.account != nil { return .connected }
        if state.source == .appServer { return .needsSignIn }
        return nil
    }

    /// Cursor's sign-in: what the last fetch found, once someone opted in to fetching.
    public static func cursor(fetched: CursorUsage?, problem: CursorFetchProblem?) -> AccountStatus? {
        if let problem { return problem.accountStatus }
        return fetched != nil ? .connected : nil
    }
}

extension OpenCodeFetchProblem {
    public var accountStatus: AccountStatus {
        switch self {
        case .notSignedIn: .needsSignIn
        case .signInExpired: .expired
        case .rejected where isSignInRejection: .expired
        case .rejected, .unreachable, .unreadable, .unreadableSignIn, .keychainUnavailable: .failed(title)
        }
    }
}
