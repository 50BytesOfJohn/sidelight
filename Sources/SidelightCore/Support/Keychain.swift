import Foundation
import Security

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

/// A secret someone typed into Sidelight (an API token, a management key), kept in their login keychain as a generic
/// password of Sidelight's own rather than in `config.json`. Every call runs off the main actor.
public struct KeychainItem: Hashable, Sendable {
    public let service: String
    public let account: String
    /// What Keychain Access shows for it.
    public let label: String

    public init(service: String, account: String, label: String) {
        self.service = service
        self.account = account
        self.label = label
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The saved secret; `nil` when there's none, or it can't be read.
    @concurrent
    public func read() async -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Saves `secret`, replacing any saved before; returns whether it was saved.
    @concurrent
    public func save(_ secret: String) async -> Bool {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = label
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// Deletes it; returns whether nothing is saved any more: deleted, or there was nothing.
    @concurrent
    public func delete() async -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
