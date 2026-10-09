import AppKit

/// Deep links into System Settings.
enum SystemSettingsPane: String {
    case accessibilityPrivacy = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    case calendarsPrivacy = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"

    func open() {
        guard let url = URL(string: rawValue) else { return }
        NSWorkspace.shared.open(url)
    }
}
