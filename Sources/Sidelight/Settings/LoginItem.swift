import Observation
import ServiceManagement

/// Whether Sidelight launches at login.
@Observable
final class LoginItem {
    private(set) var status = SMAppService.mainApp.status
    /// The error from the last failed change, for display.
    private(set) var errorMessage: String?

    var isEnabled: Bool { status == .enabled }

    var statusDescription: String {
        switch status {
        case .enabled: "Enabled"
        case .notRegistered: "Not registered"
        case .requiresApproval: "Requires approval in System Settings → General → Login Items"
        case .notFound: "Not found"
        @unknown default: "Unknown"
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }
}
