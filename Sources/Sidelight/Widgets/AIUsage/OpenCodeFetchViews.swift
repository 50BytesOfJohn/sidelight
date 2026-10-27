import SidelightCore
import SwiftUI

/// The opt-in to fetch OpenCode's limits on a timer, and how often.
struct OpenCodeFetchPicker: View {
    @Binding var isOn: Bool
    @Binding var minutes: Int

    var body: some View {
        RefreshIntervalPicker(
            title: "Fetch usage from OpenCode",
            info: "Asks OpenCode's Console for OpenCode Go's limits and the workspace's budgets, as OpenCode itself "
                + "does, with OpenCode's sign-in (opencode auth login) or an API key added in Settings. Sidelight "
                + "reads the sign-in for each request and never stores it. OpenCode doesn't document these "
                + "endpoints, so this may stop working.",
            isOn: $isOn, minutes: $minutes, choices: AIUsageSettings.openCodeRefreshMinuteChoices)
    }
}

/// How the last fetch from OpenCode went for a block's account, with a button to fetch now.
struct OpenCodeFetchStatus: View {
    /// The block's account reference: `nil` for the default account.
    let account: AccountID?
    @Environment(OpenCodeUsageService.self) private var openCode
    @Environment(AccountStore.self) private var accounts

    var body: some View {
        let id = accounts.resolve(account, at: .openCode).accountID
        let fetched = id.flatMap(openCode.usage(of:))
        StatusRow(
            color: fetched?.problem != nil ? Color.orange : fetched?.usage != nil ? .green : .secondary,
            alignment: .firstTextBaseline
        ) {
            if let problem = fetched?.problem {
                Text("\(problem.title). \(problem.advice)")
            } else if let usage = fetched?.usage {
                Text("Fetched \(usage.fetchedAt, format: .relative(presentation: .named))")
            } else {
                Text(openCode.isFetching ? "Fetching…" : "Waiting for the first fetch")
            }
        } trailing: {
            Spacer(minLength: 4)
            RefreshButton(help: "Fetch now", isDisabled: openCode.isFetching) { openCode.refreshNow() }
        }
    }
}
