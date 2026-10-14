import SidelightCore
import SwiftUI

/// Every provider Sidelight connects to, each with its accounts: the key accounts added here and the sign-ins other
/// apps own, how each is doing, and which one widgets use by default. Selecting an account shows what can be done
/// with it.
struct AccountsSettingsPane: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(SettingsNavigator.self) private var navigator
    @State private var selection: AccountID?
    @State private var adding: AccountProvider?

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                ForEach(AccountProvider.allCases) { provider in
                    ProviderSection(provider: provider, selection: $selection, adding: $adding)
                        .id(provider)
                }
                Section {
                } footer: {
                    Text(
                        "Sidelight keeps the keys you add in your keychain, never in config.json, and only reads with "
                            + "them: it never makes paid requests. It never looks for keys in other apps, shells or "
                            + "files. Sign-ins another app owns stay that app's: Sidelight only reads them. Claude "
                            + "accounts sign in through Claude Code, which keeps each in a folder of its own."
                    )
                    .settingsFootnote()
                }
            }
            .sheet(item: $adding) { provider in
                AddAccountSheet(provider: provider) { selection = $0.id }
            }
            .onAppear { follow(navigator.request, with: proxy) }
            .onChange(of: navigator.request) { follow(navigator.request, with: proxy) }
        }
    }

    /// Shows what someone asked for elsewhere: a provider's accounts, or adding one there.
    private func follow(_ request: SettingsNavigator.Request?, with proxy: ScrollViewProxy) {
        guard let request else { return }
        navigator.request = nil
        guard let provider = request.provider else { return }
        withAnimation(Motion.snappy) { proxy.scrollTo(provider, anchor: .top) }
        if request.adding { adding = provider }
    }
}

/// One provider's accounts, and adding another.
private struct ProviderSection: View {
    let provider: AccountProvider
    @Binding var selection: AccountID?
    @Binding var adding: AccountProvider?
    @Environment(AccountStore.self) private var accounts
    @Environment(ClaudeCodeService.self) private var claude

    var body: some View {
        Section {
            ForEach(accounts.accounts(of: provider)) { account in
                AccountRow(account: account, selection: $selection)
            }
            if provider.canAddAccounts {
                Button("Add Account…", systemImage: "plus") { adding = provider }
                    .buttonStyle(.borderless)
            }
        } header: {
            Label {
                Text(provider.title)
            } icon: {
                IconTile(systemImage: provider.systemImage, tint: provider.tint, size: 18)
            }
        }
        .task { await checkUnknownClaudeAccounts() }
    }
}

extension ProviderSection {
    /// Claude accounts no widget has said anything about yet ask Claude Code who's signed in, so the pane doesn't
    /// open on "Not checked yet". Quick and local: Anthropic is asked only when someone checks.
    private func checkUnknownClaudeAccounts() async {
        for account in accounts.accounts(of: provider) where accounts.status(of: account.id) == nil {
            guard let profile = accounts.claudeCodeProfile(account.id) else { continue }
            await claude.check(account.id, in: profile, isQuick: true)
        }
    }
}

/// An account: its name, how it's doing, whether it's the default, and once selected, what can be done with it.
private struct AccountRow: View {
    let account: Account
    @Binding var selection: AccountID?
    @Environment(AccountStore.self) private var accounts
    @Environment(ClaudeCodeService.self) private var claude
    /// Checking the account now, as someone asked.
    @State private var isChecking = false
    @State private var isRenaming = false
    @State private var name = ""
    @State private var isReplacingKey = false
    @State private var isSigningIn = false
    @State private var isConfirmingRemoval = false
    @State private var didCopyCommand = false

    private var isSelected: Bool { selection == account.id }
    private var isDefault: Bool { accounts.defaultAccount(for: account.provider).accountID == account.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Motion.snappy) { selection = isSelected ? nil : account.id }
            } label: {
                summary.contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            if isSelected {
                actions.transition(.opacity)
            }
        }
        .sheet(isPresented: $isReplacingKey) {
            AccountKeySheet(purpose: .replaceKey(account))
        }
        .sheet(isPresented: $isSigningIn) {
            ClaudeAccountSheet(purpose: .signInAgain(account))
        }
        .confirmationDialog(
            "Remove \(account.name)?", isPresented: $isConfirmingRemoval, titleVisibility: .visible
        ) {
            if let profile = accounts.claudeCodeProfile(account.id), account.kind == .appProfile {
                Button("Remove") { remove() }
                Button("Remove and Sign Out", role: .destructive) {
                    remove()
                    Task { await ClaudeCodeCLI.signOut(profile) }
                }
            } else {
                Button("Remove", role: .destructive) { remove() }
            }
        } message: {
            Text(removalMessage)
        }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(finishRenaming)
                } else {
                    Text(account.name)
                }
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if isDefault {
                Text("Default")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
            }
            let (color, text) = isChecking ? (Color.secondary, "Checking…") : status
            StatusRow(color: color, text: text, dotSize: 6)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 200, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isSelected ? 90 : 0))
        }
    }

    /// Who it's signed in as, where that's known; then who keeps the sign-in, and for an app profile, where.
    private var detail: String? {
        let keeper: String? =
            switch account.kind {
            case .key: nil
            case .appSignIn: account.provider.managedBy
            case .appProfile: profile?.displayPath
            }
        let parts = [accounts.identity(of: account.id), keeper].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Where Claude Code keeps it, for a Claude account.
    private var profile: ClaudeCodeProfile? { accounts.claudeCodeProfile(account.id) }

    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if account.isSaved {
                    if isRenaming {
                        Button("Done", action: finishRenaming)
                    } else {
                        Button("Rename") {
                            name = account.name
                            isRenaming = true
                        }
                    }
                }
                if !isDefault {
                    Button("Make Default") { accounts.makeDefault(account.id) }
                }
                if account.kind == .key {
                    Button("Replace Key…") { isReplacingKey = true }
                }
                if let profile {
                    Button("Check", action: { check(profile) })
                        .disabled(isChecking)
                        .help("Ask Claude Code who's signed in, and Anthropic whether it takes the sign-in")
                    Button("Sign In Again…") { isSigningIn = true }
                }
                if account.isSaved {
                    Spacer()
                    Button("Remove…", role: .destructive) { isConfirmingRemoval = true }
                }
            }
            if let profile, account.kind == .appProfile {
                HStack(spacing: 6) {
                    Text("Use it in a terminal: \(profile.terminalCommand)")
                        .textSelection(.enabled)
                        .settingsFootnote()
                    Button(didCopyCommand ? "Copied" : "Copy", systemImage: didCopyCommand ? "checkmark" : "doc.on.doc")
                    {
                        SessionHost.copy(profile.terminalCommand)
                        didCopyCommand = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy the command")
                }
            } else if account.kind == .appSignIn, profile == nil {
                Text(account.provider.signInAdvice).settingsFootnote()
            }
        }
        .controlSize(.small)
    }

    /// The status dot's color and its text.
    private var status: (Color, String) {
        if let status = accounts.status(of: account.id) { return (status.color, status.title) }
        if account.kind == .appSignIn {
            if accounts.signedInAppSignIns.contains(account.id) { return (.blue, "Signed in") }
            if accounts.foundAppSignIns.contains(account.id) { return (.orange, "Not signed in") }
        }
        return (.secondary, "Not checked yet")
    }

    private var removalMessage: String {
        let uses = accounts.uses(of: account.id)
        let widgets =
            switch uses {
            case 0: "No widget uses it."
            case 1: "1 widget uses it, and will use the default account instead."
            default: "\(uses) widgets use it, and will use the default account instead."
            }
        switch account.kind {
        case .key:
            return widgets + " Its key is deleted from your keychain."
        case .appProfile:
            let folder = profile?.displayPath ?? "its folder"
            return widgets + " Claude Code keeps it in \(folder): Remove leaves it signed in there, so you can add it "
                + "again. Remove and Sign Out signs Claude Code out of it as well."
        case .appSignIn:
            return widgets
        }
    }

    private func check(_ profile: ClaudeCodeProfile) {
        isChecking = true
        Task {
            await claude.check(account.id, in: profile)
            isChecking = false
        }
    }

    private func remove() {
        selection = nil
        accounts.remove(account.id)
    }

    private func finishRenaming() {
        accounts.rename(account.id, to: name)
        isRenaming = false
    }
}
