import SidelightCore
import SwiftUI

/// Accounts Sidelight reads with credentials typed in here, kept in the keychain. Widgets that use a provider's own
/// sign-in, like Railway's CLI, are set up in their own settings.
struct ConnectionsSettingsPane: View {
    @Environment(OpenRouterService.self) private var openRouter

    var body: some View {
        Form {
            Section {
                OpenRouterKeyForm(account: openRouter.shared)
            } header: {
                Text("OpenRouter")
            } footer: {
                Text(
                    "The shared key for OpenRouter widgets' Balance blocks, also in each widget's builder. A block can "
                        + "use its own key instead, for another account. Sidelight never looks for keys in other apps, "
                        + "shells or files, and never makes paid requests."
                )
                .settingsFootnote()
            }
        }
    }
}
