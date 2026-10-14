import SidelightCore
import SwiftUI

/// OpenRouter's accounts, until the Accounts pane takes this one's place.
struct ConnectionsSettingsPane: View {
    @Environment(AccountStore.self) private var accounts
    @State private var isAdding = false

    var body: some View {
        Form {
            Section {
                ForEach(accounts.accounts(of: .openRouter)) { Text($0.name) }
                Button("Add Account…") { isAdding = true }
            } header: {
                Text("OpenRouter")
            } footer: {
                Text("Sidelight keeps keys in your keychain and never makes paid requests.").settingsFootnote()
            }
        }
        .sheet(isPresented: $isAdding) { AccountKeySheet(purpose: .add(.openRouter)) }
    }
}
