import Foundation
import Security

/// Where the OpenRouter management key is kept: reading, saving and removing it, each off the main actor. The
/// keychain by default; anything else only stands in for it, as a test might.
nonisolated struct OpenRouterKeyStore: Sendable {
    var read: @Sendable () async -> String?
    var save: @Sendable (String) async -> Bool
    var delete: @Sendable () async -> Bool

    /// Sidelight's own keychain item, which holds only what someone typed into Settings. Nothing is ever read
    /// from other apps, shells or files.
    static let keychain = OpenRouterKeyStore(
        read: { await OpenRouterKeychainItem.read() },
        save: { await OpenRouterKeychainItem.save($0) },
        delete: { await OpenRouterKeychainItem.delete() }
    )
}

/// The OpenRouter management key in the login keychain, rather than in `config.json`.
private nonisolated enum OpenRouterKeychainItem {
    private static let service = "app.getsidelight.Sidelight.openrouter"
    private static let account = "management-key"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @concurrent
    static func read() async -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @concurrent
    static func save(_ key: String) async -> Bool {
        let data = Data(key.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Sidelight: OpenRouter management key"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @concurrent
    static func delete() async -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
