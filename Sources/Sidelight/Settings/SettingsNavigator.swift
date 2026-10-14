import Observation
import SidelightCore

/// Opens where accounts are managed, from wherever something needs one: Settings at the Accounts pane, or a widget's
/// own settings, where it chooses its account. Views ask; the composition root says how windows open.
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
