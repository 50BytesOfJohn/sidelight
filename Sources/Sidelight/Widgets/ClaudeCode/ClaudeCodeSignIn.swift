import AppKit
import Foundation
import Observation
import SidelightCore
import os

/// Claude Code's own command-line tool, run unmodified for what only it may do with a Claude account: sign it in,
/// say who's signed in, sign it out. Sidelight never takes part in the sign-in itself: Anthropic allows signing in to
/// a Claude account only through its own flow, and only Claude Code and Anthropic's apps to keep the sign-in
/// (https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use).
enum ClaudeCodeCLI {
    /// `claude`, where the installer, Homebrew or Claude Code's own updater put it; `nil` when it isn't installed.
    static var executable: URL? {
        ExecutableLocator.find(
            "claude",
            in: ExecutableLocator.standardDirectories + [
                URL.homeDirectory.appending(path: ".claude/local", directoryHint: .isDirectory)
            ])
    }

    /// Whether, and who as, `profile` is signed in; `nil` when Claude Code can't be asked or its answer can't be
    /// read, which says nothing about the sign-in.
    static func authStatus(of profile: ClaudeCodeProfile) async -> ClaudeCodeAuthStatus? {
        guard let executable,
            let result = await ProcessRunner.result(
                of: executable, arguments: ["auth", "status", "--json"], environment: profile.environment)
        else { return nil }
        return ClaudeCodeAuthStatus(json: result.output)
    }

    /// Has Claude Code renew `profile`'s sign-in once it has expired, as it does whenever it starts for anything but
    /// `claude auth`. Nobody uses an account Sidelight signed in, so otherwise nothing would. `claude plugin list` is
    /// the cheapest way to start it: it sends nothing to a model, so it uses none of the plan's limits, and starts
    /// no MCP servers. Claude Code renews the sign-in its own way, guarding against another `claude` renewing it at
    /// the same time, and keeps it; Sidelight never sees more than the access token. Returns whether it ran.
    static func renewSignIn(of profile: ClaudeCodeProfile) async -> Bool {
        guard let executable,
            let result = await ProcessRunner.result(
                of: executable, arguments: ["plugin", "list"], environment: profile.environment)
        else { return false }
        return result.status == 0
    }

    /// Signs `profile` out, which also revokes its sign-in; returns whether Claude Code says it did.
    static func signOut(_ profile: ClaudeCodeProfile) async -> Bool {
        guard let executable,
            let result = await ProcessRunner.result(
                of: executable, arguments: ["auth", "logout"], environment: profile.environment)
        else { return false }
        return result.status == 0
    }
}

/// Signs a Claude Code profile in, by running Claude Code's own `claude auth login` with the profile's folder.
/// Claude Code signs in in the browser and keeps the sign-in itself; Sidelight only sees the link it asks a browser
/// to open, and whether it signed in.
///
/// Claude Code is handed a browser of Sidelight's (`Resources/claude-code-sign-in-link.sh`) that passes the link on
/// instead of opening it, so someone can open it in the browser they choose or copy it. Signing in at that link in
/// any browser on this Mac finishes on its own; from another device, the page shows a code to paste here instead.
@Observable
final class ClaudeCodeSignIn {
    enum Phase: Equatable {
        case starting
        /// Waiting for someone to sign in at `link`.
        case waiting(link: URL)
        /// Signed in; asking Claude Code who as.
        case finishing
        case signedIn(ClaudeCodeIdentity)
        case failed(String)
    }

    let profile: ClaudeCodeProfile
    /// The profile is a new account's: its folder mustn't exist yet, so two sign-ins never share one.
    let isNewProfile: Bool
    private(set) var phase = Phase.starting
    /// The link for signing in from another device, which ends with a code to ``submit(code:)``.
    private(set) var manualLink: URL?
    /// Why the last code pasted didn't work.
    private(set) var codeProblem: String?

    @ObservationIgnored private var process: ChildProcess?
    @ObservationIgnored private var output: Task<Void, Never>?
    /// Asking Claude Code who signed in.
    @ObservationIgnored private var lookup: Task<Void, Never>?
    @ObservationIgnored private var linkWatcher: FileWatcher?
    /// Falls back to ``manualLink`` if Sidelight's browser never passes the link on.
    @ObservationIgnored private let linkFallback = DelayedTask()
    @ObservationIgnored private var linkFolder: URL?
    /// The profile's folder, when this sign-in created it: if it doesn't finish, the folder goes again.
    @ObservationIgnored private var createdFolder: URL?

    /// The browser Sidelight hands Claude Code; `nil` when running outside an app bundle.
    private static var linkScriptURL: URL? {
        Bundle.main.url(forResource: "claude-code-sign-in-link", withExtension: "sh")
    }

    init(profile: ClaudeCodeProfile, isNewProfile: Bool = false) {
        self.profile = profile
        self.isNewProfile = isNewProfile
    }

    /// Starts Claude Code's sign-in. Once it's waiting, ``phase`` has the link.
    func start() {
        guard process == nil else { return }
        phase = .starting
        manualLink = nil
        codeProblem = nil
        guard let executable = ClaudeCodeCLI.executable else {
            phase = .failed("Sidelight can't find Claude Code. Install it from claude.com/claude-code, then try again.")
            return
        }
        do {
            guard try prepareFolder() else {
                phase = .failed("\(profile.displayPath) is in use already. Try another name.")
                return
            }
            let linkFile = try watchForLink()
            var environment = profile.environment
            environment["BROWSER"] = Self.linkScriptURL?.path(percentEncoded: false) ?? "/usr/bin/true"
            environment["SIDELIGHT_SIGN_IN_LINK"] = linkFile.path(percentEncoded: false)
            let process = try ChildProcess(
                executable: executable, arguments: ["auth", "login", "--claudeai"], environment: environment,
                mergesStandardError: true)
            self.process = process
            output = Task { [weak self] in
                for await line in process.lines {
                    guard !Task.isCancelled else { return }
                    self?.handle(String(decoding: line, as: UTF8.self))
                }
                guard !Task.isCancelled else { return }
                self?.claudeCodeExited()
            }
        } catch {
            Log.claudeCode.error("Can't start Claude Code's sign-in: \(error)")
            fail("Sidelight couldn't start Claude Code's sign-in.")
        }
    }

    /// Hands Claude Code the code the sign-in page showed on another device.
    func submit(code: String) {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, let process, case .waiting = phase else { return }
        codeProblem = nil
        process.send(Data(code.utf8))
    }

    /// Stops the sign-in. Unless Claude Code signed in already, it keeps nothing from it, and a folder created for
    /// it goes.
    func cancel() {
        lookup?.cancel()
        lookup = nil
        finish()
        switch phase {
        case .starting, .waiting: removeCreatedFolder()
        case .finishing, .signedIn, .failed: break
        }
    }

    /// Opens the link in the default browser.
    func openLink() {
        guard case .waiting(let link) = phase else { return }
        NSWorkspace.shared.open(link)
    }

    // MARK: Claude Code's output

    private func handle(_ line: String) {
        if let range = line.range(of: "visit: "), let link = Self.link(in: line[range.upperBound...]) {
            manualLink = link
            // Claude Code hands its browser the other link right after this one. Without Sidelight's browser, or if
            // it never does, this link is all there is.
            linkFallback.schedule(after: Self.linkScriptURL == nil ? .zero : .seconds(3)) { [weak self] in
                guard let self, case .starting = phase else { return }
                phase = .waiting(link: link)
            }
        }
        if line.contains("Invalid code") {
            codeProblem = "That code didn't work. Copy the whole code the page shows, then try again."
        }
        if let range = line.range(of: "Login failed: ") {
            fail("Claude Code couldn't sign in: \(line[range.upperBound...].trimmingCharacters(in: .whitespaces))")
        } else if line.contains("Login successful"), phase != .finishing {
            phase = .finishing
            lookup = Task { [weak self] in await self?.lookUpIdentity() }
        }
    }

    private func lookUpIdentity() async {
        let status = await ClaudeCodeCLI.authStatus(of: profile)
        guard !Task.isCancelled else { return }
        finish()
        createdFolder = nil
        guard case .signedIn(let identity) = status else {
            phase = .failed("Claude Code signed in, but doesn't say who as. Try again.")
            return
        }
        phase = .signedIn(identity)
    }

    private func claudeCodeExited() {
        process = nil
        switch phase {
        case .starting, .waiting: fail("Claude Code stopped before signing in.")
        case .finishing, .signedIn, .failed: break
        }
    }

    private func fail(_ message: String) {
        Log.claudeCode.notice("Claude Code's sign-in failed: \(message, privacy: .public)")
        finish()
        removeCreatedFolder()
        phase = .failed(message)
    }

    /// Stops Claude Code and stops watching for the link.
    private func finish() {
        linkFallback.cancel()
        output?.cancel()
        output = nil
        process?.terminate()
        process = nil
        linkWatcher = nil
        if let linkFolder { try? FileManager.default.removeItem(at: linkFolder) }
        linkFolder = nil
    }

    // MARK: Files

    /// Creates the profile's folder if it's missing, readable by its owner only, as Claude Code's own is. A new
    /// account's folder is created here or not at all, in one step: returns `false` when it exists already, which
    /// another sign-in may be using.
    private func prepareFolder() throws -> Bool {
        guard let path = profile.configDirectory else { return true }
        let folder = URL(filePath: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: folder.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // `mkdir` fails rather than reuse a folder that appeared meanwhile.
        guard mkdir(path, 0o700) == 0 else {
            guard errno == EEXIST else { throw CocoaError(.fileWriteUnknown) }
            return !isNewProfile
        }
        createdFolder = folder
        return true
    }

    private func removeCreatedFolder() {
        guard let createdFolder else { return }
        try? FileManager.default.removeItem(at: createdFolder)
        self.createdFolder = nil
    }

    /// A private folder the browser script writes the link into, watched for it; returns the link's file.
    private func watchForLink() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "Sidelight sign-in \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        linkFolder = folder
        let file = folder.appending(path: "link", directoryHint: .notDirectory)
        linkWatcher = FileWatcher(file: file) { [weak self] in self?.readLink(from: file) }
        return file
    }

    private func readLink(from file: URL) {
        guard phase == .starting || manualLink.map({ phase == .waiting(link: $0) }) == true,
            let text = try? String(contentsOf: file, encoding: .utf8),
            let link = Self.link(in: Substring(text))
        else { return }
        phase = .waiting(link: link)
    }

    /// A sign-in link on Anthropic's sites at the start of `text`; nothing else is opened or shown.
    private static func link(in text: Substring) -> URL? {
        let candidate = text.prefix { !$0.isWhitespace }
        guard let url = URL(string: String(candidate)), ClaudeCodeProfile.isSignInLink(url) else { return nil }
        return url
    }
}
