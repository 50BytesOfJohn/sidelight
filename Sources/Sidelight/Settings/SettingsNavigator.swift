import Observation
import SidelightCore

/// Opens Settings at a place, from wherever something needs it: the Accounts pane at a provider, or the keyboard
/// shortcuts; or a widget's own settings, where it chooses its account. Views ask; the composition root says how
/// windows open.
@Observable
final class SettingsNavigator {
    /// What Settings shows next. Settings selects its pane, and clears it unless the pane has more to show; then the
    /// pane clears it once it has.
    var request: Request?
    /// Brings the Settings window to the front.
    @ObservationIgnored var showSettings: () -> Void = {}
    /// Opens a widget's settings, where its accounts are chosen.
    @ObservationIgnored var showWidgetSettings: (WidgetInstance.ID) -> Void = { _ in }

    enum Request: Equatable {
        /// The Accounts pane at `provider`, or at its top for `nil`, opening the sheet that adds an account there if
        /// `adding`.
        case accounts(provider: AccountProvider?, adding: Bool)
        /// The Keyboard Shortcuts pane.
        case shortcuts

        var pane: SettingsPane {
            switch self {
            case .accounts: .accounts
            case .shortcuts: .shortcuts
            }
        }

        /// Whether there is more to show than the pane, which the pane shows and then clears the request.
        var hasMoreThanPane: Bool {
            switch self {
            case .accounts: true
            case .shortcuts: false
            }
        }
    }

    func showAccounts(_ provider: AccountProvider? = nil, adding: Bool = false) {
        show(.accounts(provider: provider, adding: adding && provider?.canAddAccounts == true))
    }

    func showShortcuts() { show(.shortcuts) }

    private func show(_ request: Request) {
        self.request = request
        showSettings()
    }
}
