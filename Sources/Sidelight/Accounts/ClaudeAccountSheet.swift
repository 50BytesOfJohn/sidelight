import AppKit
import SidelightCore
import SwiftUI

/// Adds a Claude account, or signs one in again, through Claude Code: it signs in in the browser, at a link this
/// shows to open or copy, and keeps the account in a folder of its own and the keychain, as when someone runs
/// `CLAUDE_CONFIG_DIR=~/.sidelight/claude/work claude`. Sidelight saves only the folder, and reads the sign-in from there.
/// A folder Claude Code has signed in to already can be added as it is.
struct ClaudeAccountSheet: View {
    enum Purpose: Equatable {
        case add
        case signInAgain(Account)
    }

    let purpose: Purpose
    /// Called with the account once it's added or signed in again.
    var completion: (Account) -> Void = { _ in }
    @Environment(AccountStore.self) private var accounts
    @Environment(ClaudeCodeService.self) private var claude
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var signIn: ClaudeCodeSignIn?
    /// Folders Claude Code has signed in to already, not added yet.
    @State private var signedInFolders: [ClaudeCodeProfile.SignedInFolder] = []
    /// Checking a folder that's signed in already, before adding it.
    @State private var isCheckingFolder = false
    @State private var problem: String?

    private var provider: AccountProvider { .claudeCode }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: provider.systemImage)
                .font(.headline)
            if case .add = purpose {
                Form {
                    TextField("Name", text: $name, prompt: Text("Work"))
                        .disabled(signIn != nil)
                        .onSubmit(startSignIn)
                    LabeledContent("Folder") {
                        Text(profile.displayPath)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .formStyle(.columns)
            }
            SettingsCaption(explanation)
            if let signIn {
                ClaudeSignInProgress(signIn: signIn)
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(20)
        .frame(width: 440)
        .task {
            guard case .add = purpose else { return }
            signedInFolders = await ClaudeCodeProfile.signedInFolders().filter {
                accounts.appProfile(at: provider, inFolder: $0.profile.configDirectory ?? "") == nil
            }
        }
        .onChange(of: signIn?.phase) { _, phase in
            if case .signedIn(let identity) = phase { finish(identity) }
        }
        .onDisappear { signIn?.cancel() }
    }

    private var buttons: some View {
        HStack {
            if case .add = purpose {
                existingFolderMenu
            }
            if isCheckingFolder { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if let signIn, case .failed = signIn.phase {
                Button("Try Again") { signIn.start() }
                    .keyboardShortcut(.defaultAction)
            } else if signIn == nil {
                Button("Sign In…", action: startSignIn)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSignIn)
            }
        }
    }

    /// Adds a folder Claude Code has signed in to already: one found in the home folder, or any other.
    private var existingFolderMenu: some View {
        Menu("Add Signed-In Folder") {
            if !signedInFolders.isEmpty {
                Section("Found on This Mac") {
                    ForEach(signedInFolders, id: \.self) { folder in
                        Button("\(folder.profile.displayPath) · \(folder.email)") { add(folder.profile) }
                    }
                }
            }
            Button("Choose Folder…", action: chooseFolder)
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(signIn != nil || isCheckingFolder)
        .help("Add a folder you already signed in to with CLAUDE_CONFIG_DIR")
    }

    // MARK: Text

    private var title: String {
        switch purpose {
        case .add: "Add Claude Account"
        case .signInAgain(let account): "Sign In to \(account.name) Again"
        }
    }

    private var explanation: String {
        switch purpose {
        case .add:
            "Claude Code signs in with your browser and keeps the account in this folder and your keychain. Sidelight "
                + "only reads it. Use the account in a terminal with \(profile.terminalCommand)."
        case .signInAgain:
            "Claude Code signs in again with your browser. Sidelight only reads the sign-in."
        }
    }

    // MARK: Profile

    /// The folder the account is kept in: one named after it for a new account, while it isn't signing in yet.
    private var profile: ClaudeCodeProfile {
        if let signIn { return signIn.profile }
        switch purpose {
        case .add:
            let folder = ClaudeCodeProfile.newFolder(named: trimmedName ?? "") { path in
                FileManager.default.fileExists(atPath: path) || accounts.appProfile(at: provider, inFolder: path) != nil
            }
            return ClaudeCodeProfile(configDirectory: folder)
        case .signInAgain(let account):
            return accounts.claudeCodeProfile(account.id) ?? .standard
        }
    }

    private var trimmedName: String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private var canSignIn: Bool {
        switch purpose {
        case .add: trimmedName != nil && !isCheckingFolder
        case .signInAgain: true
        }
    }

    // MARK: Actions

    private func startSignIn() {
        guard canSignIn, signIn == nil else { return }
        problem = nil
        let signIn = ClaudeCodeSignIn(profile: profile)
        self.signIn = signIn
        signIn.start()
    }

    private func finish(_ identity: ClaudeCodeIdentity) {
        switch purpose {
        case .add:
            guard let folder = profile.configDirectory else { return }
            let account = accounts.addAppProfile(
                at: provider, name: trimmedName ?? identity.email ?? "", folder: folder)
            completion(account)
        case .signInAgain(let account):
            completion(account)
        }
        checkSignedIn(profile)
        dismiss()
    }

    /// Checks the account just signed in, or added, so Settings says how it's doing right away. It outlives the
    /// sheet.
    private func checkSignedIn(_ profile: ClaudeCodeProfile) {
        let id: AccountID? =
            switch purpose {
            case .add: profile.configDirectory.flatMap { accounts.appProfile(at: provider, inFolder: $0)?.id }
            case .signInAgain(let account): account.id
            }
        guard let id else { return }
        let claude = claude
        Task { await claude.check(id, in: profile) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = .homeDirectory
        panel.prompt = "Add"
        panel.message = "Choose a folder Claude Code signed in to with CLAUDE_CONFIG_DIR."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var path = url.standardizedFileURL.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        add(ClaudeCodeProfile(configDirectory: path))
    }

    /// Adds a folder Claude Code has signed in to already, once Claude Code says it has, with a Claude plan.
    private func add(_ folder: ClaudeCodeProfile) {
        guard let path = folder.configDirectory else { return }
        problem = nil
        if path == ClaudeCodeProfile.defaultFolder {
            problem = "That's Claude Code's own folder, which Sidelight reads already as Claude Code."
            return
        }
        if let existing = accounts.appProfile(at: provider, inFolder: path) {
            problem = "That folder is added already, as \(existing.name)."
            return
        }
        isCheckingFolder = true
        Task {
            defer { isCheckingFolder = false }
            guard let identity = await ClaudeCodeCLI.identity(of: folder) else {
                problem = "Claude Code isn't signed in in \(folder.displayPath). Sign in to add it instead."
                return
            }
            guard identity.hasPlan else {
                problem = "\(folder.displayPath) signs in with an API key, which has no plan limits to show."
                return
            }
            let account = accounts.addAppProfile(
                at: provider, name: trimmedName ?? identity.email ?? "", folder: path)
            completion(account)
            checkSignedIn(folder)
            dismiss()
        }
    }
}

/// How Claude Code's sign-in is going: the link to sign in at, to open or copy, while it waits.
private struct ClaudeSignInProgress: View {
    let signIn: ClaudeCodeSignIn
    @State private var didCopy = false
    @State private var code = ""

    var body: some View {
        switch signIn.phase {
        case .starting:
            progress("Starting Claude Code…")
        case .waiting(let link):
            waiting(link)
        case .finishing, .signedIn:
            progress("Signed in. Finishing…")
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func waiting(_ link: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in to Claude in your browser")
                .font(.callout.weight(.medium))
            Text(link.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack {
                Button("Open in Browser", systemImage: "safari") { signIn.openLink() }
                    .keyboardShortcut(.defaultAction)
                Button(didCopy ? "Copied" : "Copy Link", systemImage: didCopy ? "checkmark" : "doc.on.doc") {
                    SessionHost.copy(link.absoluteString)
                    didCopy = true
                }
            }
            progress("Waiting for you to sign in…")
            if let manualLink = signIn.manualLink, manualLink != link {
                ExpandableRow(title: "Signing in on another device?") {
                    otherDevice(manualLink)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    /// The link that ends with a code to paste here, for a browser that can't reach this Mac.
    private func otherDevice(_ link: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open this link there instead. Once you sign in, the page shows a code: paste it here.")
                .settingsFootnote()
            Button("Copy Link for Another Device", systemImage: "doc.on.doc") { SessionHost.copy(link.absoluteString) }
                .controlSize(.small)
            HStack {
                TextField("Code", text: $code, prompt: Text("Paste the code"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { signIn.submit(code: code) }
                Button("Continue") { signIn.submit(code: code) }
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
            if let problem = signIn.codeProblem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
