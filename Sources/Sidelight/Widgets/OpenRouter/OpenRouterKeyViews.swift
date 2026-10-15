import SidelightCore
import SwiftUI

/// Which of the account's keys the chart shows. Keys are chosen by hash, so renaming one keeps it chosen; a chosen
/// key OpenRouter doesn't list (any more, or on the pages loaded so far) stays chosen, by its saved name.
struct OpenRouterKeyPicker: View {
    let account: OpenRouterAccount
    @Binding var chart: OpenRouterSpendChartSettings

    var body: some View {
        let list = account.keyList
        Picker(selection: selection) {
            Text("Choose…").tag(String?.none)
            ForEach(list.keys) { key in
                Text(title(key)).tag(Optional(key.hash))
            }
            if let hash = chart.keyHash, !list.keys.contains(where: { $0.hash == hash }) {
                Text("\(chart.keyName ?? "Chosen key") (not listed)").tag(Optional(hash))
            }
        } label: {
            InfoLabel(
                "Key",
                info: list.reachedLimit
                    ? "The first \(list.keys.count) keys in the account's default workspace, including disabled and "
                        + "expired ones. Later keys can't be chosen here."
                    : "Keys in the account's default workspace, including disabled and expired ones.")
        }
        .disabled(!account.canUseKey)
        // Keys load while a picker is on screen, and stop loading once none is.
        .onAppear { account.keyPickerAppeared() }
        .onDisappear { account.keyPickerDisappeared() }
        let action = action(list)
        if list.isLoading || action != nil || list.problem != nil {
            HStack(spacing: 8) {
                if list.isLoading {
                    ProgressView().controlSize(.small)
                } else if let action {
                    Button(action.title, action: action.run).controlSize(.small)
                }
                if let problem = list.problem {
                    Text(problem.title).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    /// What can be done about the list, while it isn't loading.
    private func action(_ list: OpenRouterKeyList) -> (title: String, run: () -> Void)? {
        if list.problem != nil, !(list.problem?.needsKey ?? false) { return ("Try Again", account.retryKeys) }
        if list.hasMore { return ("Load More Keys", account.loadMoreKeys) }
        // Nothing loaded yet, and nothing loading.
        if list.fetchedAt == nil, list.problem == nil, account.canUseKey { return ("Load Keys", account.retryKeys) }
        return nil
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
