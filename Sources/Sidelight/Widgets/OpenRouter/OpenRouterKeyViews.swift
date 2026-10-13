import SidelightCore
import SwiftUI

/// Which of the account's keys the chart shows. Keys are chosen by hash, so renaming one keeps it chosen; a chosen
/// key OpenRouter doesn't list (any more, or on the pages loaded so far) stays chosen, by its saved name.
struct OpenRouterKeyPicker: View {
    let account: OpenRouterAccount
    @Binding var chart: OpenRouterSpendChartSettings

    var body: some View {
        let list = account.keyList
        Picker("Key", selection: selection) {
            Text("Choose…").tag(String?.none)
            ForEach(list.keys) { key in
                Text(title(key)).tag(Optional(key.hash))
            }
            if let hash = chart.keyHash, !list.keys.contains(where: { $0.hash == hash }) {
                Text("\(chart.keyName ?? "Chosen key") (not listed)").tag(Optional(hash))
            }
        }
        .disabled(!account.canUseKey)
        // Keys load while a picker is on screen, and stop loading once none is.
        .onAppear { account.keyPickerAppeared() }
        .onDisappear { account.keyPickerDisappeared() }
        HStack(spacing: 8) {
            if list.isLoading {
                ProgressView().controlSize(.small)
            } else if list.problem != nil, !(list.problem?.needsKey ?? false) {
                Button("Try Again") { account.retryKeys() }.controlSize(.small)
            } else if list.hasMore {
                Button("Load More Keys") { account.loadMoreKeys() }.controlSize(.small)
            } else if list.fetchedAt == nil, list.problem == nil, account.canUseKey {
                // Nothing loaded yet, and nothing loading.
                Button("Load Keys") { account.retryKeys() }.controlSize(.small)
            }
            if let problem = list.problem {
                Text(problem.title).font(.caption).foregroundStyle(.orange)
            }
        }
        SettingsCaption(
            list.reachedLimit
                ? "The first \(list.keys.count) keys in the account's default workspace, disabled and expired ones "
                    + "included. A key past those can't be chosen here."
                : "Keys in the account's default workspace, disabled and expired ones included.")
    }

    private var selection: Binding<String?> {
        Binding {
            chart.keyHash
        } set: { hash in
            chart.keyHash = hash
            if let key = account.keyList.keys.first(where: { $0.hash == hash }) {
                chart.keyName = key.name
            } else if hash == nil {
                chart.keyName = nil
            }
        }
    }

    private func title(_ key: OpenRouterKey) -> String {
        if key.isDisabled { return "\(key.name) (disabled)" }
        if key.isExpired(at: .now) { return "\(key.name) (expired)" }
        return key.name
    }
}

/// Saving or removing the management key Sidelight reads an account with, the same everywhere it's offered.
struct OpenRouterKeyForm: View {
    let account: OpenRouterAccount
    /// Rows titled "Management key", with the explanation behind this ⓘ, for the Widgets window. `nil` shows the
    /// explanation under the form, as Settings does.
    var info: String?

    var body: some View {
        Group {
            if account.keyRemovalFailed {
                // Whatever the keychain still holds isn't used; this says so whether or not it can be read.
                HStack {
                    Label("A removed key is still in your keychain", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Remove Again", role: .destructive) { account.removeKey() }.controlSize(.small)
                }
                SettingsCaption(
                    account.unnotedKeyChange == .removal
                        ? "Sidelight isn't using it now, but couldn't note that you removed it: after it restarts, it "
                            + "would use it again. Remove it again, or save a key to replace it."
                        : "The keychain couldn't delete it. Sidelight isn't using it, even after it restarts. Remove "
                            + "it again, or save a key to replace it.")
                keyField
            } else {
                switch account.hasKey {
                case true? where info != nil:
                    LabeledContent {
                        HStack(spacing: 8) {
                            Label("Saved", systemImage: "key.fill")
                                .foregroundStyle(.secondary)
                                .help("In your keychain, never in config.json")
                            Button("Remove", role: .destructive) { account.removeKey() }.controlSize(.small)
                        }
                    } label: {
                        title
                    }
                    unnotedSave
                case true?:
                    HStack {
                        Label("Management key saved in your keychain", systemImage: "key.fill")
                            .font(.callout)
                        Spacer()
                        Button("Remove", role: .destructive) { account.removeKey() }.controlSize(.small)
                    }
                    unnotedSave
                case false? where info != nil:
                    VStack(alignment: .leading, spacing: 8) {
                        title
                        keyField
                    }
                case false?:
                    keyField
                case nil:
                    ProgressView().controlSize(.small)
                }
            }
            if info == nil {
                SettingsCaption(Self.explanation)
            }
        }
        // A new form for another account: a key typed for one is never saved for another.
        .id(account.id)
        .onAppear { account.lookForKey() }
    }

    @ViewBuilder
    private var title: some View {
        if let info { InfoLabel("Management key", info: info) }
    }

    @ViewBuilder
    private var unnotedSave: some View {
        if account.unnotedKeyChange == .save {
            SettingsCaption(
                "Sidelight couldn't note that this key replaces the one you removed: after it restarts, it won't use "
                    + "it until you save it again.")
        }
    }

    static let explanation =
        "Only a management key can read an account's balance and spending. It can also create and delete keys: "
        + "Sidelight only ever reads with it, and keeps it in your keychain, never in config.json. The model "
        + "catalogue needs no key."

    /// Where a key is typed in and checked before it's saved.
    private var keyField: some View {
        OpenRouterKeyField(save: account.saveKey)
    }
}

/// Where a management key is typed in, then checked with OpenRouter and saved.
struct OpenRouterKeyField: View {
    /// Checks and saves the key; returns why it wasn't saved.
    let save: (String) async -> OpenRouterProblem?
    /// Puts the field away without saving; `nil` where it always shows.
    var cancel: (() -> Void)?
    @State private var draft = ""
    @State private var isSaving = false
    @State private var problem: OpenRouterProblem?

    static let managementKeysURL = URL(string: "https://openrouter.ai/settings/management-keys")!

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField("OpenRouter management key", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Button(isSaving ? "Checking…" : "Save Key", action: submit)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                if let cancel {
                    Button("Cancel", action: cancel).disabled(isSaving)
                }
                Spacer()
                Link("Create a management key", destination: Self.managementKeysURL)
                    .font(.callout)
            }
            .controlSize(.small)
            if let problem {
                Text("\(problem.title). \(problem.advice)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func submit() {
        guard !isSaving else { return }
        isSaving = true
        problem = nil
        Task {
            problem = await save(draft)
            isSaving = false
            if problem == nil { draft = "" }
        }
    }
}
