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
        }
    }

    var tint: Color {
        switch self {
        case .openRouter: .indigo
        case .railway: .purple
        case .claudeCode: .orange
        case .codex: .teal
        case .cursor: .gray
        }
    }

    /// What its key is called, in the field it's typed into.
    var keyTitle: String {
        switch self {
        case .openRouter: "OpenRouter management key"
        case .railway: "Account or workspace token"
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
        case .claudeCode, .codex, .cursor: nil
        }
    }

    /// `Managed by the Railway CLI`, for its app sign-in.
    var managedBy: String {
        switch self {
        case .openRouter: ""
        case .railway: "Managed by the Railway CLI"
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
        case .claudeCode: "Run claude and sign in."
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
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var key = ""
    @State private var isChecking = false
    @State private var problem: String?

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
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChecking)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { name = accounts.suggestedName(for: provider) }
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
        isChecking = true
        problem = nil
        Task {
            defer { isChecking = false }
            if let problem = await check(key) {
                self.problem = problem
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
            } else if choices.count == 1, selection == nil || selection == choices.first?.id {
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
            AccountKeySheet(purpose: .add(provider))
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

/// What a widget shows in place of an account's data when it has no account to use, the one it names is gone, or the
/// account needs signing in again. `nil` from ``init(_:provider:accounts:navigator:widget:layout:)`` when there's
/// nothing to say: the widget shows the account's data.
struct AccountMessage: View {
    let message: WidgetMessage

    var body: some View { message }

    /// The message for the widget `widget` at `provider`, whose account resolved to `resolution`. Choosing an account
    /// opens the widget's settings, where its account is chosen; without a widget, Settings' Accounts pane.
    init?(
        _ resolution: AccountResolution, provider: AccountProvider, accounts: AccountStore,
        navigator: SettingsNavigator, widget: WidgetInstance.ID?, layout: WidgetLayout
    ) {
        func action(_ title: String, adding: Bool = false) -> WidgetMessage.Action {
            WidgetMessage.Action(title: title, runsOnGlanceClick: true) {
                navigator.showAccounts(provider, adding: adding)
            }
        }
        func choose() -> WidgetMessage.Action {
            guard let widget else { return action("Choose Account") }
            return WidgetMessage.Action(title: "Choose Account", runsOnGlanceClick: true) {
                navigator.showWidgetSettings(widget)
            }
        }
        switch resolution {
        case .account(let id):
            guard let status = accounts.status(of: id), status.needsSignIn, let account = accounts.account(id) else {
                return nil
            }
            message = WidgetMessage(
                title: "\(account.name) needs you to sign in again.",
                detail: account.kind == .appSignIn ? provider.signInAdvice : nil,
                systemImage: "person.crop.circle.badge.exclamationmark", layout: layout,
                action: action("Open Accounts"))
        case .notFound:
            message = WidgetMessage(
                title: "Account not found.",
                detail: "It may have been removed. Choose another in this widget's settings.",
                systemImage: "person.crop.circle.badge.questionmark", layout: layout, action: choose())
        case .chooseAccount:
            message = WidgetMessage(
                title: "Choose an account to see \(provider.title) data.", systemImage: "person.2", layout: layout,
                action: choose())
        case .noAccount:
            if accounts.isMovingLegacySecrets {
                message = WidgetMessage(title: "Loading accounts…", systemImage: "hourglass", layout: layout)
            } else {
                message = WidgetMessage(
                    title: "Add an account to see \(provider.title) data.",
                    systemImage: "person.crop.circle.badge.plus",
                    layout: layout, action: action("Add Account", adding: true))
            }
        }
    }
}

/// Opens Settings at the Accounts pane, from wherever something needs an account: a widget on a panel, or a widget's
/// settings.
@Observable
final class SettingsNavigator {
    /// What Settings shows next. Settings clears it once it has.
    var request: Request?
    /// Brings the Settings window to the front.
    @ObservationIgnored var showSettings: () -> Void = {}
    /// Opens a widget's settings, where its accounts are chosen.
    @ObservationIgnored var showWidgetSettings: (WidgetInstance.ID) -> Void = { _ in }

    struct Request: Equatable {
        /// The provider to show; `nil` for the top of the pane.
        var provider: AccountProvider?
        /// Opens the sheet that adds an account at `provider`.
        var adding: Bool
    }

    func showAccounts(_ provider: AccountProvider? = nil, adding: Bool = false) {
        request = Request(provider: provider, adding: adding && provider?.acceptsKeys == true)
        showSettings()
    }
}
