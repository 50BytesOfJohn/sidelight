import Foundation
import Security

/// Where the OpenRouter management key is kept: reading, saving and removing it, each off the main actor. The
/// keychain by default; anything else only stands in for it, as a test might.
nonisolated struct OpenRouterKeyStore: Sendable {
    var read: @Sendable () async -> String?
    /// Whether the key was saved.
    var save: @Sendable (String) async -> Bool
    /// Whether no key is saved any more: removed, or there was none.
    var delete: @Sendable () async -> Bool

    /// Sidelight's own keychain item, which holds only what someone typed into Settings. Nothing is ever read
    /// from other apps, shells or files.
    static let keychain = OpenRouterKeyStore.keychain(service: OpenRouterKeychainItem.defaultService)

    /// The keychain item under `service`, to keep a trial run's key apart from the real one.
    static func keychain(service: String) -> OpenRouterKeyStore {
        let item = OpenRouterKeychainItem(service: service)
        return OpenRouterKeyStore(
            read: { await item.read() },
            save: { await item.save($0) },
            delete: { await item.delete() }
        )
    }
}

/// The OpenRouter management key in the login keychain, rather than in `config.json`.
private nonisolated struct OpenRouterKeychainItem: Sendable {
    static let defaultService = "app.getsidelight.Sidelight.openrouter"
    private static let account = "management-key"

    let service: String

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    @concurrent
    func read() async -> String? {
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
    func save(_ key: String) async -> Bool {
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
    func delete() async -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
