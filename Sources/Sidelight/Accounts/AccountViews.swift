import SidelightCore
import SwiftUI

extension AccountProvider {
    var systemImage: String {
        switch self {
        case .openRouter: "sparkles.rectangle.stack.fill"
        case .railway: "tram.fill"
        case .claudeCode: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow.rays"
        case .runware: "photo.stack"
        }
    }

    var tint: Color {
        switch self {
        case .openRouter: .indigo
        case .railway: .purple
        case .claudeCode: .orange
        case .codex: .teal
        case .cursor: .gray
        case .runware: .pink
        }
    }

    /// What its key is called, in the field it's typed into.
    var keyTitle: String {
        switch self {
        case .openRouter: "OpenRouter management key"
        case .railway: "Account or workspace token"
        case .runware: "Runware API key"
        case .claudeCode, .codex, .cursor: "Key"
        }
    }

    /// What kind of key it takes, and why.
    var keyExplanation: String {
        switch self {
        case .openRouter:
            "Only a management key can read an account's balance and spending. It can also create and delete keys: "
                + "Sidelight only ever reads with it. The model catalogue needs no key."
        case .railway:
            "An account or workspace token sees what the account sees. Project tokens can't list projects."
        case .runware:
            "Sidelight reads the organization's balance, usage and models with it, and never runs a generation."
        case .claudeCode, .codex, .cursor:
            ""
        }
    }

    /// Where to create a key.
    var keyLink: (title: String, url: URL)? {
        switch self {
        case .openRouter:
            ("Create a management key", URL(string: "https://openrouter.ai/settings/management-keys")!)
        case .railway: ("Create a token", URL(string: "https://railway.com/account/tokens")!)
        case .runware: ("Create an API key", URL(string: "https://my.runware.ai/keys")!)
        case .claudeCode, .codex, .cursor: nil
        }
    }

    /// `Managed by the Railway CLI`, for its app sign-in.
    var managedBy: String {
        switch self {
        case .openRouter: ""
        case .railway: "Managed by the Railway CLI"
        case .runware: "Managed by the Runware CLI"
        case .claudeCode: "Managed by Claude Code"
        case .codex: "Managed by Codex"
        case .cursor: "Managed by Cursor"
        }
    }

    /// How someone signs in to its app sign-in again.
    var signInAdvice: String {
        switch self {
        case .openRouter: "Replace its key in Settings, under Accounts."
        case .railway: "Run railway login, or add a token in Settings, under Accounts."
        case .runware:
            "Run runware auth login, or add an API key in Settings, under Accounts. A key set only in RUNWARE_API_KEY "
                + "isn't visible to Sidelight: add it here instead."
        case .claudeCode: "Sign in again in Settings, under Accounts, or run claude and sign in."
        case .codex: "Run codex and sign in."
        case .cursor: "Open Cursor and sign in."
        }
    }
}

extension AccountStatus {
    var color: Color {
        switch self {
        case .connected: .green
        case .needsSignIn, .expired: .orange
        case .failed: .yellow
        }
    }

    var title: String {
        switch self {
        case .connected: "Connected"
        case .needsSignIn: "Needs sign-in"
        case .expired: "Sign-in expired"
        case .failed(let message): message
        }
    }
}

/// Adds an account at `provider`, the way it takes them: a key typed in, or a sign-in its app keeps. The same sheet
/// in Settings and in the widgets' settings.
struct AddAccountSheet: View {
    let provider: AccountProvider
    /// Called with the account once it's added.
    var completion: (Account) -> Void = { _ in }

    var body: some View {
        if provider.acceptsAppProfiles {
            ClaudeAccountSheet(purpose: .add, completion: completion)
        } else {
            AccountKeySheet(purpose: .add(provider), completion: completion)
        }
    }
}

/// A key account's name and key, typed in and checked with the provider before it's added: or, for an account that
/// has one, a key to replace it with. The same sheet in Settings and in the widgets' settings.
struct AccountKeySheet: View {
    enum Purpose: Equatable {
        case add(AccountProvider)
        case replaceKey(Account)
    }

    let purpose: Purpose
    /// Called with the account once it's added or its key replaced.
    var completion: (Account) -> Void = { _ in }
    @Environment(AccountStore.self) private var accounts
    @Environment(OpenRouterService.self) private var openRouter
    @Environment(RailwayService.self) private var railway
    @Environment(RunwareService.self) private var runware
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var key = ""
    @State private var problem: String?
    /// Checking the key with the provider, then saving it. Closing the sheet cancels it before anything is saved.
    @State private var submission: Task<Void, Never>?

    private var isChecking: Bool { submission != nil }

    private var provider: AccountProvider {
        switch purpose {
        case .add(let provider): provider
        case .replaceKey(let account): account.provider
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: provider.systemImage)
                .font(.headline)
            Form {
                if case .add = purpose {
                    TextField("Name", text: $name, prompt: Text(accounts.suggestedName(for: provider)))
                }
                SecureField(provider.keyTitle, text: $key)
                    .onSubmit(submit)
            }
            .formStyle(.columns)
            VStack(alignment: .leading, spacing: 4) {
                SettingsCaption(provider.keyExplanation + " Sidelight keeps it in your keychain, never in config.json.")
                if let link = provider.keyLink {
                    Link(link.title, destination: link.url).font(.caption)
                }
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isChecking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) {
                    submission?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChecking)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { name = accounts.suggestedName(for: provider) }
        .onDisappear { submission?.cancel() }
    }

    private var title: String {
        switch purpose {
        case .add(let provider): "Add \(provider.title) Account"
        case .replaceKey(let account): "Replace the Key of \(account.name)"
        }
    }

    private var confirmTitle: String {
        if isChecking { return "Checking…" }
        if case .add = purpose { return "Add" }
        return "Replace"
    }

    private func submit() {
        guard !isChecking else { return }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        problem = nil
        submission = Task {
            defer { submission = nil }
            let rejection = await check(key)
            // Cancelled or closed while the provider was asked: nothing is saved.
            guard !Task.isCancelled else { return }
            if let rejection {
                problem = rejection
                return
            }
            switch purpose {
            case .add(let provider):
                guard let account = await accounts.add(at: provider, name: name, secret: key) else {
                    problem = "Sidelight couldn't save the key in your keychain."
                    return
                }
                completion(account)
            case .replaceKey(let account):
                guard await accounts.replaceSecret(of: account.id, with: key) else {
                    problem = "Sidelight couldn't save the key in your keychain."
                    return
                }
                completion(account)
            }
            dismiss()
        }
    }

    /// Why the provider won't take `key`; `nil` when it does.
    private func check(_ key: String) async -> String? {
        switch provider {
        case .openRouter:
            return await openRouter.checkKey(key).map { "\($0.title). \($0.advice)" }
        case .railway:
            return await railway.checkToken(key).map { "\($0.title). \($0.advice)" }
        case .runware:
            return await runware.checkKey(key).map { "\($0.title). \($0.advice)" }
        case .claudeCode, .codex, .cursor:
            return "\(provider.title) signs in on its own."
        }
    }
}

/// Which account a widget or block uses, in its settings: an Add Account button while the provider has none, the
/// account's name while it has one, and a picker once it has more, with Manage Accounts… beside it.
struct AccountPicker: View {
    let provider: AccountProvider
    /// The account reference: `nil` for the default account.
    @Binding var selection: AccountID?
    var title = "Account"
    @Environment(AccountStore.self) private var accounts
    @Environment(SettingsNavigator.self) private var navigator
    @State private var isAdding = false

    var body: some View {
        let choices = accounts.choices(at: provider, using: selection)
        Group {
            if choices.isEmpty && selection == nil {
                LabeledContent(title) {
                    Button("Add Account…", systemImage: "plus") { isAdding = true }
                        .controlSize(.small)
                }
            } else if choices.count == 1, accounts.resolve(selection, at: provider).accountID == choices[0].id {
                LabeledContent(title) {
                    HStack(spacing: 8) {
                        Text(choices[0].name).foregroundStyle(.secondary)
                        manageLink
                    }
                }
            } else {
                Picker(title, selection: $selection) {
                    Text(defaultTitle).tag(AccountID?.none)
                    Divider()
                    ForEach(choices) { Text($0.name).tag(Optional($0.id)) }
                    if let selection, !choices.contains(where: { $0.id == selection }) {
                        Text("Account not found").tag(Optional(selection))
                    }
                }
                HStack {
                    Spacer()
                    manageLink
                }
            }
        }
        .sheet(isPresented: $isAdding) {
            AddAccountSheet(provider: provider)
        }
    }

    private var manageLink: some View {
        Button("Manage Accounts…") { navigator.showAccounts(provider) }
            .buttonStyle(.link)
            .controlSize(.small)
    }

    /// `Default (Work)`.
    private var defaultTitle: String {
        guard let id = accounts.defaultAccount(for: provider).accountID, let account = accounts.account(id) else {
            return "Default"
        }
        return "Default (\(account.name))"
    }
}

/// Why a widget can't show an account's data, and what to do about it.
enum AccountNotice: Equatable {
    /// The provider has no account the widget could use.
    case addAccount
    /// The account the widget names is gone, or it names none of several with no default: one has to be chosen.
    case chooseAccount(isMissing: Bool)
    /// The account needs signing in again, or its key replacing.
    case signIn(Account)

    /// What `accounts` says about a widget at `provider` naming `reference`; `nil` when it can show the account's
    /// data. Unless `requiresSignIn`, an account that needs signing in again still shows what it has.
    init?(
        _ reference: AccountID?, at provider: AccountProvider, in accounts: AccountStore, requiresSignIn: Bool = true
    ) {
        switch accounts.resolve(reference, at: provider) {
        case .account(let id):
            guard requiresSignIn, accounts.status(of: id)?.needsSignIn == true, let account = accounts.account(id)
            else { return nil }
            self = .signIn(account)
        case .notFound: self = .chooseAccount(isMissing: true)
        case .chooseAccount: self = .chooseAccount(isMissing: false)
        case .noAccount: self = .addAccount
        }
    }
}

/// A widget's content for the account it uses, or in its place, why it has none to use: no account yet, the one it
/// names is gone, or the account needs signing in again. Each says so with a button that leads to the fix.
struct AccountGate<Content: View>: View {
    /// The widget's account reference: `nil` for the default account.
    let reference: AccountID?
    let provider: AccountProvider
    let layout: WidgetLayout
    /// Whether the content needs the account signed in. Content that has more to show (what Claude Code saved, say)
    /// says so itself.
    var requiresSignIn = true
    @ViewBuilder let content: (AccountID) -> Content
    @Environment(AccountStore.self) private var accounts
    @Environment(SettingsNavigator.self) private var navigator
    @Environment(\.widgetPlacement) private var placement

    var body: some View {
        if let notice = AccountNotice(reference, at: provider, in: accounts, requiresSignIn: requiresSignIn) {
            message(notice)
        } else if let id = accounts.resolve(reference, at: provider).accountID {
            content(id)
        }
    }

    private func message(_ notice: AccountNotice) -> WidgetMessage {
        switch notice {
        case .addAccount:
            WidgetMessage(
                title: "Add an account to see \(provider.title) data.", systemImage: "person.crop.circle.badge.plus",
                layout: layout,
                action: action("Add Account") { navigator.showAccounts(provider, adding: true) })
        case .chooseAccount(let isMissing):
            WidgetMessage(
                title: isMissing ? "Account not found." : "Choose an account to see \(provider.title) data.",
                detail: isMissing ? "It may have been removed. Choose another in this widget's settings." : nil,
                systemImage: "person.crop.circle.badge.questionmark", layout: layout,
                action: action("Choose Account") {
                    if let widget = placement?.widgetID {
                        navigator.showWidgetSettings(widget)
                    } else {
                        navigator.showAccounts(provider)
                    }
                })
        case .signIn(let account):
            WidgetMessage(
                title: "\(account.name) needs you to sign in again.",
                detail: account.kind == .key ? nil : provider.signInAdvice,
                systemImage: "person.crop.circle.badge.exclamationmark", layout: layout,
                action: action("Open Accounts") { navigator.showAccounts(provider) })
        }
    }

    private func action(_ title: String, run: @escaping () -> Void) -> WidgetMessage.Action {
        WidgetMessage.Action(title: title, runsOnGlanceClick: true, run: run)
    }
}
