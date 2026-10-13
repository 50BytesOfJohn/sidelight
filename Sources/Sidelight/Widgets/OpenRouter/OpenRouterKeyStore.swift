import Foundation
import SidelightCore
import os

/// Where every OpenRouter account's management key is kept: one store for each account.
nonisolated struct OpenRouterKeyring: Sendable {
    /// The store for `account`'s key. Asked once for each account.
    var store: @Sendable (OpenRouterAccountID) -> OpenRouterKeyStore

    init(store: @escaping @Sendable (OpenRouterAccountID) -> OpenRouterKeyStore) {
        self.store = store
    }

    /// `shared` for the shared key, and for every other account a key kept in memory only, as a test might use.
    init(shared: OpenRouterKeyStore) {
        store = { $0 == .shared ? shared : .memory() }
    }

    static let defaultKeychainService = "app.getsidelight.Sidelight.openrouter"

    /// Sidelight's own keychain items, which hold only what someone typed into Sidelight. Nothing is ever read from
    /// other apps, shells or files. Removals are noted next to the configuration.
    static let keychain = OpenRouterKeyring.keychain(
        service: defaultKeychainService, notingRemovalIn: ConfigurationStore.defaultFileURL.deletingLastPathComponent())

    /// The keychain items under `service`, to keep a trial run's keys apart from the real ones, with removals noted
    /// in `directory`.
    static func keychain(service: String, notingRemovalIn directory: URL) -> OpenRouterKeyring {
        OpenRouterKeyring { account in
            let item = KeychainItem.openRouterKey(service: service, account: account)
            var name = service.replacing("/", with: "-")
            if case .own(let widget, let block) = account { name += ".\(widget.uuidString).\(block.uuidString)" }
            return OpenRouterKeyStore(
                read: { await item.read() },
                save: { await item.save($0) },
                delete: { await item.delete() },
                removal: .file(directory.appending(path: name + ".removed", directoryHint: .notDirectory))
            )
        }
    }
}

/// Where one OpenRouter management key is kept: reading, saving and removing it, each off the main actor. A keychain
/// item by default; anything else only stands in for it, as a test might.
nonisolated struct OpenRouterKeyStore: Sendable {
    var read: @Sendable () async -> String?
    /// Whether the key was saved.
    var save: @Sendable (String) async -> Bool
    /// Whether no key is saved any more: removed, or there was none.
    var delete: @Sendable () async -> Bool
    /// Whether someone removed the key, noted apart from the key itself: if the keychain couldn't delete it, it still
    /// isn't used after Sidelight restarts. In memory only unless another is given, so a stand-in writes nothing.
    var removal: OpenRouterKeyRemovalRecord = .memory()

    /// A key kept in memory only, with nothing saved to start with.
    static func memory() -> OpenRouterKeyStore {
        let key = OSAllocatedUnfairLock<String?>(initialState: nil)
        return OpenRouterKeyStore(
            read: { key.withLock { $0 } },
            save: { new in
                key.withLock { $0 = new }
                return true
            },
            delete: {
                key.withLock { $0 = nil }
                return true
            })
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

nonisolated extension KeychainItem {
    /// An OpenRouter management key under `service`: `management-key` for the shared key,
    /// `management-key/<widget>/<block>` for a Balance block's own.
    static func openRouterKey(service: String, account: OpenRouterAccountID) -> KeychainItem {
        switch account {
        case .shared:
            KeychainItem(service: service, account: "management-key", label: "Sidelight: OpenRouter management key")
        case .own(let widget, let block):
            KeychainItem(
                service: service, account: "management-key/\(widget.uuidString)/\(block.uuidString)",
                label: "Sidelight: OpenRouter management key (Balance block)")
        }
    }
}
