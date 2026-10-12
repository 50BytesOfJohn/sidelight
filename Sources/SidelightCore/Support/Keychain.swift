import Foundation

/// Sign-ins other apps keep in the keychain.
public enum Keychain {
    /// The password of a generic item another app saved, read through the `security` tool the way those apps save
    /// it, so macOS's "Always Allow" keeps covering the item after the app rewrites it. `nil` when there's none, or
    /// the person said no.
    public static func genericPassword(service: String, account: String? = nil) async -> Data? {
        let account = account.map { ["-a", $0] } ?? []
        return await ProcessRunner.output(
            of: URL(filePath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-s", service] + account + ["-w"])
    }
}
