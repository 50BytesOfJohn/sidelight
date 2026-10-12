import Foundation

/// The running app's version, as providers and helper tools are told it.
enum AppInfo {
    /// The marketing version, e.g. `0.4.0`.
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    /// `Sidelight/<version>`.
    static var userAgent: String { "Sidelight/\(version)" }
}
