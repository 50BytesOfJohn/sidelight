import Foundation
import Security
import os

/// Where the OpenRouter management key is kept: reading, saving and removing it, each off the main actor. The
/// keychain by default; anything else only stands in for it, as a test might.
nonisolated struct OpenRouterKeyStore: Sendable {
    var read: @Sendable () async -> String?
    /// Whether the key was saved.
    var save: @Sendable (String) async -> Bool
    /// Whether no key is saved any more: removed, or there was none.
    var delete: @Sendable () async -> Bool
    /// Whether someone removed the key, noted apart from the key itself: if the keychain couldn't delete it, it still
    /// isn't used after Sidelight restarts. In memory only unless another is given, so a stand-in writes nothing.
    var removal: OpenRouterKeyRemovalRecord = .memory()

    static let defaultKeychainService = "app.getsidelight.Sidelight.openrouter"

    /// Sidelight's own keychain item, which holds only what someone typed into Settings. Nothing is ever read
    /// from other apps, shells or files. Its removal is noted next to the configuration.
    static let keychain = OpenRouterKeyStore.keychain(
        service: defaultKeychainService, notingRemovalIn: ConfigurationStore.defaultFileURL.deletingLastPathComponent())

    /// The keychain item under `service`, to keep a trial run's key apart from the real one, with its removal noted
    /// in `directory`.
    static func keychain(service: String, notingRemovalIn directory: URL) -> OpenRouterKeyStore {
        let item = OpenRouterKeychainItem(service: service)
        let name = service.replacing("/", with: "-") + ".removed"
        return OpenRouterKeyStore(
            read: { await item.read() },
            save: { await item.save($0) },
            delete: { await item.delete() },
            removal: .file(directory.appending(path: name, directoryHint: .notDirectory))
        )
    }
}

/// That someone removed the management key: noted before the keychain is asked to delete it, and forgotten once it
/// did, or once a key is saved. Holds nothing secret.
nonisolated struct OpenRouterKeyRemovalRecord: Sendable {
    /// Whether a removal is noted. When that can't be told, it counts as noted: a key someone removed is never used
    /// because the note couldn't be read.
    var isNoted: @Sendable () async -> Bool
    /// Notes the removal (`true`) or forgets it (`false`); returns whether that worked.
    var note: @Sendable (Bool) async -> Bool

    /// Noted in memory, for as long as this record (or a copy of it) is kept.
    static func memory() -> OpenRouterKeyRemovalRecord {
        let isNoted = OSAllocatedUnfairLock(initialState: false)
        return OpenRouterKeyRemovalRecord(
            isNoted: { isNoted.withLock { $0 } },
            note: { noted in
                isNoted.withLock { $0 = noted }
                return true
            })
    }

    /// Noted by a file at `url`, there while a removal is noted.
    static func file(_ url: URL) -> OpenRouterKeyRemovalRecord {
        let file = OpenRouterKeyRemovalFile(url: url)
        return OpenRouterKeyRemovalRecord(isNoted: { await file.isNoted() }, note: { await file.note($0) })
    }
}

private nonisolated struct OpenRouterKeyRemovalFile: Sendable {
    let url: URL

    private static let explanation = """
        You removed Sidelight's OpenRouter management key. Until you save a key in Sidelight again, it doesn't use \
        one, even if your keychain still holds it. Nothing secret is kept here.

        """

    @concurrent
    func isNoted() async -> Bool {
        do {
            _ = try Data(contentsOf: url)
            return true
        } catch CocoaError.fileReadNoSuchFile {
            return false
        } catch {
            return true
        }
    }

    @concurrent
    func note(_ noted: Bool) async -> Bool {
        do {
            if noted {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(Self.explanation.utf8).write(to: url, options: .atomic)
            } else {
                try FileManager.default.removeItem(at: url)
            }
            return true
        } catch CocoaError.fileNoSuchFile where !noted {
            return true
        } catch {
            return false
        }
    }
}

/// The OpenRouter management key in the login keychain, rather than in `config.json`.
private nonisolated struct OpenRouterKeychainItem: Sendable {
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
