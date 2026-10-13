import SidelightCore
import SwiftUI

/// The Widgets window's settings for an OpenRouter Credits widget: the account's key, how often to ask, and the
/// chart.
struct OpenRouterCreditsSettingsEditor: View {
    @Binding var settings: OpenRouterCreditsSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            OpenRouterKeyForm()
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Picker("Refresh", selection: $settings.refresh) {
                Text("Manually").tag(RefreshCadence.manual)
                ForEach(refreshChoices, id: \.self) { minutes in
                    Text("Every \(minutes) minutes").tag(RefreshCadence.minutes(minutes))
                }
            }
            SettingsCaption(
                settings.refresh == .manual
                    ? "Fetched once, then whenever you click refresh."
                    : "Only while the widget is on screen. Spending changes once a day, so it's fetched after "
                        + "midnight UTC.")
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show spending by day", isOn: $settings.chart.isShown)
            if settings.chart.isShown {
                Picker("Days", selection: $settings.chart.days) {
                    ForEach(dayChoices, id: \.self) { Text("\($0) days").tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Spending of", selection: $settings.chart.scope) {
                    Text("The account").tag(OpenRouterChartScope.account)
                    Text("One key").tag(OpenRouterChartScope.key)
                }
                if settings.chart.scope == .key {
                    OpenRouterKeyPicker(chart: $settings.chart)
                }
                SettingsCaption(
                    "Completed days in UTC: today isn't over yet. What other providers bill through your own keys "
                        + "(BYOK) is listed apart, never added. The balance is always the account's.")
            }
        }
    }

    /// The offered intervals; one set by hand in `config.json` is listed too.
    private var refreshChoices: [Int] {
        Set(OpenRouterCreditsSettings.refreshMinuteChoices + [settings.refresh.minutes].compactMap(\.self)).sorted()
    }

    private var dayChoices: [Int] {
        Set(OpenRouterSpendChartSettings.dayChoices + [settings.chart.days]).sorted()
    }
}

/// Which of the account's keys the chart shows. Keys are chosen by hash, so renaming one keeps it chosen; a chosen
/// key OpenRouter doesn't list (any more, or on the pages loaded so far) stays chosen, by its saved name.
private struct OpenRouterKeyPicker: View {
    @Binding var chart: OpenRouterSpendChartSettings
    @Environment(OpenRouterService.self) private var service

    var body: some View {
        let list = service.keyList
        Picker("Key", selection: selection) {
            Text("Choose…").tag(String?.none)
            ForEach(list.keys) { key in
                Text(title(key)).tag(Optional(key.hash))
            }
            if let hash = chart.keyHash, !list.keys.contains(where: { $0.hash == hash }) {
                Text("\(chart.keyName ?? "Chosen key") (not listed)").tag(Optional(hash))
            }
        }
        .disabled(!service.canUseKey)
        // Keys load while a picker is on screen, and stop loading once none is.
        .onAppear { service.keyPickerAppeared() }
        .onDisappear { service.keyPickerDisappeared() }
        HStack(spacing: 8) {
            if list.isLoading {
                ProgressView().controlSize(.small)
            } else if list.problem != nil, !(list.problem?.needsKey ?? false) {
                Button("Try Again") { service.retryKeys() }.controlSize(.small)
            } else if list.hasMore {
                Button("Load More Keys") { service.loadMoreKeys() }.controlSize(.small)
            } else if list.fetchedAt == nil, list.problem == nil, service.canUseKey {
                // Nothing loaded yet, and nothing loading.
                Button("Load Keys") { service.retryKeys() }.controlSize(.small)
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
            if let key = service.keyList.keys.first(where: { $0.hash == hash }) {
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

/// Saving or removing the management key Sidelight reads the account with, the same everywhere it's offered.
struct OpenRouterKeyForm: View {
    @Environment(OpenRouterService.self) private var service
    @State private var draft = ""
    @State private var isSaving = false
    @State private var problem: OpenRouterProblem?

    var body: some View {
        Group {
            if service.keyRemovalFailed {
                // Whatever the keychain still holds isn't used; this says so whether or not it can be read.
                HStack {
                    Label("A removed key is still in your keychain", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Remove Again", role: .destructive) { service.removeKey() }.controlSize(.small)
                }
                SettingsCaption(
                    service.unnotedKeyChange == .removal
                        ? "Sidelight isn't using it now, but couldn't note that you removed it: after it restarts, it "
                            + "would use it again. Remove it again, or save a key to replace it."
                        : "The keychain couldn't delete it. Sidelight isn't using it, even after it restarts. Remove "
                            + "it again, or save a key to replace it.")
                keyField
            } else {
                switch service.hasKey {
                case true?:
                    HStack {
                        Label("Management key saved in your keychain", systemImage: "key.fill").font(.callout)
                        Spacer()
                        Button("Remove", role: .destructive) { service.removeKey() }.controlSize(.small)
                    }
                    if service.unnotedKeyChange == .save {
                        SettingsCaption(
                            "Sidelight couldn't note that this key replaces the one you removed: after it restarts, "
                                + "it won't use it until you save it again.")
                    }
                case false?:
                    keyField
                case nil:
                    ProgressView().controlSize(.small)
                }
            }
            SettingsCaption(
                "Only a management key can read the account's balance and spending. It can also create and delete "
                    + "keys: Sidelight only ever reads with it, and keeps it in your keychain, never in config.json. "
                    + "The model catalogue needs no key.")
        }
        .onAppear { service.lookForKey() }
    }

    static let managementKeysURL = URL(string: "https://openrouter.ai/settings/management-keys")!

    /// Where a key is typed in and checked before it's saved.
    private var keyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField("OpenRouter management key", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Button(isSaving ? "Checking…" : "Save Key", action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
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

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        problem = nil
        Task {
            problem = await service.saveKey(draft)
            isSaving = false
            if problem == nil { draft = "" }
        }
    }
}
