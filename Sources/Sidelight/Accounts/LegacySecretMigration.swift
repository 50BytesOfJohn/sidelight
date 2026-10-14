import Foundation
import SidelightCore
import os

/// Moves the secrets versions before accounts kept to the accounts they become: OpenRouter's shared management key,
/// each Balance block's own key, and the Railway token (see ``AppConfiguration/legacySecrets``).
///
/// It runs at every launch and does nothing once there's nothing left to move. Each secret is copied to its account's
/// keychain item, read back, and only once both match is the old item deleted, and the account added. An item already
/// there is never overwritten: a run cut short can leave one. Anything that fails keeps the old item, and is tried
/// again at the next launch. A key someone removed (OpenRouter noted that in a `.removed` file) isn't moved: its item
/// and the note are deleted. Without an old secret to move, widgets that named its account go back to the default.
struct LegacySecretMigration {
    /// Where the old secrets are.
    var old: LegacySecretLocation
    /// Where accounts' secrets go.
    var new: AccountSecrets
    /// Leaves the old items in place once they're copied, for a debug build sharing them with an installed release
    /// that still reads them.
    var keepsOldSecrets = false

    /// What happened to one secret.
    enum Outcome: Equatable {
        /// It's in its account's item now (or was already), and the account is added.
        case moved
        /// There's nothing to move, or someone had removed it: widgets that named its account use the default.
        case dropped
        /// Something failed; it's tried again at the next launch.
        case retry
    }

    /// Moves every secret `configuration` may have had, and adds or drops their accounts in it.
    @discardableResult
    func run(on configuration: ConfigurationStore) async -> [LegacySecret: Outcome] {
        var outcomes: [LegacySecret: Outcome] = [:]
        for legacy in configuration.configuration.legacySecrets {
            let outcome = await move(legacy)
            outcomes[legacy] = outcome
            switch outcome {
            case .moved: configuration.configuration.adopt(legacy)
            case .dropped: configuration.configuration.drop(legacy)
            case .retry: break
            }
        }
        return outcomes
    }

    private func move(_ legacy: LegacySecret) async -> Outcome {
        let account = legacy.account
        let kind = String(describing: legacy.source)
        let current = await new.lookUp(account.id)
        if case .failed = current { return .retry }

        switch await old.removal(legacy.source) {
        case .unknown:
            Log.accounts.error("Can't tell whether the \(kind, privacy: .public) key was removed; not moving it yet")
            return .retry
        case .noted:
            // Removed: not moved. The note goes only once the item has, so it's never moved later.
            if !keepsOldSecrets {
                guard await old.delete(legacy.source) else {
                    Log.accounts.error("Couldn't delete the removed \(kind, privacy: .public) key; trying again later")
                    return .retry
                }
                if await !old.forgetRemoval(legacy.source) {
                    Log.accounts.error("Couldn't delete the note that the \(kind, privacy: .public) key was removed")
                }
            }
            Log.accounts.info("Didn't move the \(kind, privacy: .public) key, which was removed")
            return current == .missing ? .dropped : .moved
        case .none:
            break
        }

        switch await old.lookUp(legacy.source) {
        case .failed:
            Log.accounts.error("Can't read the \(kind, privacy: .public) key to move it; trying again later")
            return .retry
        case .missing:
            // Nothing (left) to move: moved before, or there never was one.
            return current == .missing ? .dropped : .moved
        case .found(let secret):
            if case .found(let existing) = current {
                // Already there, maybe from a run cut short: never overwritten.
                guard existing == secret else {
                    Log.accounts.error("An account already has another key than the \(kind, privacy: .public) one")
                    return .moved
                }
            } else {
                guard await new.save(secret, account) else {
                    Log.accounts.error("Couldn't copy the \(kind, privacy: .public) key; trying again later")
                    return .retry
                }
                guard await new.lookUp(account.id) == .found(secret) else {
                    Log.accounts.error("The copied \(kind, privacy: .public) key didn't read back; trying again later")
                    _ = await new.delete(account.id)
                    return .retry
                }
            }
            if !keepsOldSecrets, await !old.delete(legacy.source) {
                Log.accounts.error("Copied the \(kind, privacy: .public) key, but couldn't delete the old one")
            }
            Log.accounts.info("Moved the \(kind, privacy: .public) key to its account")
            return .moved
        }
    }
}

/// Where versions before accounts kept their secrets, and OpenRouter's notes of removed keys.
nonisolated struct LegacySecretLocation: Sendable {
    /// Whether someone removed a key, as OpenRouter noted it.
    enum Removal: Equatable, Sendable {
        case none
        case noted
        /// The note couldn't be read.
        case unknown
    }

    var lookUp: @Sendable (LegacySecret.Source) async -> KeychainLookup
    /// Returns whether the old item is gone: deleted, or there was none.
    var delete: @Sendable (LegacySecret.Source) async -> Bool
    var removal: @Sendable (LegacySecret.Source) async -> Removal
    /// Deletes the note of a removal; returns whether it's gone.
    var forgetRemoval: @Sendable (LegacySecret.Source) async -> Bool

    static let defaultOpenRouterService = "app.getsidelight.Sidelight.openrouter"
    static let defaultRailwayService = "app.getsidelight.Sidelight.railway"

    static let keychain = LegacySecretLocation.keychain(
        openRouterService: defaultOpenRouterService, railwayService: defaultRailwayService,
        removalsIn: ConfigurationStore.defaultFileURL.deletingLastPathComponent())

    /// The OpenRouter keys under `openRouterService`, their removals noted in `directory`, and the Railway token
    /// under `railwayService`.
    static func keychain(
        openRouterService: String, railwayService: String, removalsIn directory: URL
    )
        -> LegacySecretLocation
    {
        @Sendable func item(_ source: LegacySecret.Source) -> KeychainItem {
            switch source {
            case .openRouterShared:
                KeychainItem(service: openRouterService, account: "management-key", label: "")
            case .openRouterBlock(let widget, let block):
                KeychainItem(
                    service: openRouterService, account: "management-key/\(widget.uuidString)/\(block.uuidString)",
                    label: "")
            case .railwayToken:
                KeychainItem(service: railwayService, account: "api-token", label: "")
            }
        }
        @Sendable func note(_ source: LegacySecret.Source) -> URL? {
            var name = openRouterService.replacing("/", with: "-")
            switch source {
            case .openRouterShared: break
            case .openRouterBlock(let widget, let block): name += ".\(widget.uuidString).\(block.uuidString)"
            case .railwayToken: return nil
            }
            return directory.appending(path: name + ".removed", directoryHint: .notDirectory)
        }
        return LegacySecretLocation(
            lookUp: { await item($0).lookUp() },
            delete: { await item($0).delete() },
            removal: { source in
                guard let url = note(source) else { return .none }
                return await RemovalNote(url: url).state()
            },
            forgetRemoval: { source in
                guard let url = note(source) else { return true }
                return await RemovalNote(url: url).delete()
            })
    }
}

/// A note OpenRouter's key store left next to the configuration when someone removed a key: there while the removal
/// counts. Holds nothing secret.
private nonisolated struct RemovalNote: Sendable {
    let url: URL

    @concurrent
    func state() async -> LegacySecretLocation.Removal {
        do {
            _ = try Data(contentsOf: url)
            return .noted
        } catch CocoaError.fileReadNoSuchFile {
            return .none
        } catch {
            return .unknown
        }
    }

    @concurrent
    func delete() async -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch CocoaError.fileNoSuchFile {
            return true
        } catch {
            return false
        }
    }
}
