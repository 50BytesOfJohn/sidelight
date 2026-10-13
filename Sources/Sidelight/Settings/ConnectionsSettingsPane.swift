import SidelightCore
import SwiftUI

/// Accounts Sidelight reads with credentials typed in here, kept in the keychain. Widgets that use a provider's own
/// sign-in, like Railway's CLI, are set up in their own settings.
struct ConnectionsSettingsPane: View {
    var body: some View {
        Form {
            Section {
                OpenRouterKeyForm()
            } header: {
                Text("OpenRouter")
            } footer: {
                Text(
                    "Used by OpenRouter Credits widgets for the account's balance and spending. Sidelight never "
                        + "looks for keys in other apps, shells or files, and never makes paid requests."
                )
                .settingsFootnote()
            }
        }
    }
}
