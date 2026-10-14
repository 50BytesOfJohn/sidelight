import Foundation

// Versions before shared accounts kept credentials per widget: OpenRouter's shared management key and a key for each
// Balance block that used its own (`usesOwnKey`), and one Railway token (`account: token`, or `automatic` without the
// CLI). Loading such a configuration points the widgets at the accounts those secrets become, under IDs that are the
// same on every run; the accounts themselves are added once their secret has moved to them, so there's never an
// account without one.

extension AccountID {
    /// What OpenRouter's shared management key becomes.
    public static let migratedOpenRouterKey = derived(from: "openRouter.shared")
    /// What the Railway token saved in Sidelight becomes.
    public static let migratedRailwayToken = derived(from: "railway.token")

    /// What the own key of the Balance block `block` in the widget `widget` becomes. Keyed by both, since a preset's
    /// block has the same ID in every widget.
    public static func migratedOpenRouterKey(widget: UUID, block: UUID) -> AccountID {
        derived(from: "openRouter.balance/\(widget.uuidString)/\(block.uuidString)")
    }
}

/// What versions before accounts saved in an OpenRouter widget's settings that it no longer does: whether each
/// Balance block used its own key.
struct LegacyOpenRouterSettings: Decodable {
    struct Balance: Decodable {
        var usesOwnKey: Bool?

        init(from decoder: any Decoder) throws {
            usesOwnKey = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(
                Bool.self, forKey: .usesOwnKey)
        }

        private enum CodingKeys: String, CodingKey {
            case usesOwnKey
        }
    }

    var balances: [String: Balance]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        balances = container.decodeLeniently(.balances, or: [:])
    }

    private enum CodingKeys: String, CodingKey {
        case balances
    }
}

/// A secret an earlier version kept, and the key account it becomes once it's moved.
public struct LegacySecret: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// OpenRouter's shared management key.
        case openRouterShared
        /// The own management key of a Balance block.
        case openRouterBlock(widget: UUID, block: UUID)
        /// The Railway token.
        case railwayToken
    }

    public let source: Source
    public let account: Account
    /// It becomes its provider's default, unless the provider has one.
    public let isDefault: Bool
}

extension AppConfiguration {
    /// Every secret an earlier version may have kept, with the account each becomes: the shared OpenRouter key and
    /// the Railway token always (they don't show in the configuration), and the own key of each Balance block that
    /// still names the account it was migrated to.
    public var legacySecrets: [LegacySecret] {
        var secrets = [
            LegacySecret(
                source: .openRouterShared,
                account: Account(id: .migratedOpenRouterKey, provider: .openRouter, name: "OpenRouter", kind: .key),
                isDefault: true),
            LegacySecret(
                source: .railwayToken,
                account: Account(id: .migratedRailwayToken, provider: .railway, name: "Railway", kind: .key),
                isDefault: false),
        ]
        for widget in widgets {
            guard case .openRouter(let settings) = widget.settings else { continue }
            for (block, options) in settings.allBalances
            where options.account == .migratedOpenRouterKey(widget: widget.id, block: block) {
                let name = options.title ?? "\(AccountProvider.openRouter.title) key"
                secrets.append(
                    LegacySecret(
                        source: .openRouterBlock(widget: widget.id, block: block),
                        account: Account(id: options.account!, provider: .openRouter, name: name, kind: .key),
                        isDefault: false))
            }
        }
        return secrets
    }

    /// Adds the account `legacy`'s secret became, now that it's moved, unless it's there already; and makes it the
    /// default if it should be and its provider has none.
    public mutating func adopt(_ legacy: LegacySecret) {
        let account = legacy.account
        if !accounts.contains(where: { $0.id == account.id }) { accounts.append(account) }
        if legacy.isDefault, defaultAccounts[account.provider] == nil {
            defaultAccounts[account.provider] = account.id
        }
    }

    /// `legacy`'s secret isn't there to move: widgets that named its account use the default instead. Nothing changes
    /// once its account was added.
    public mutating func drop(_ legacy: LegacySecret) {
        guard !accounts.contains(where: { $0.id == legacy.account.id }) else { return }
        forgetReferences(to: legacy.account.id)
    }
}

// MARK: - References

extension AppConfiguration {
    /// How many widgets (counting each Balance block) name `id`.
    public func references(to id: AccountID) -> Int {
        widgets.reduce(0) { count, widget in
            switch widget.settings {
            case .openRouter(let settings): count + settings.allBalances.count { $0.options.account == id }
            case .railway(let settings): count + (settings.account == id ? 1 : 0)
            default: count
            }
        }
    }

    /// How many widgets (counting each Balance block) use `id`: those that name it, and if it's its provider's default,
    /// those that name none.
    public func uses(of id: AccountID, signedIn: Set<AccountID> = []) -> Int {
        guard let provider = account(id)?.provider else { return references(to: id) }
        let usesDefault = defaultAccount(for: provider, signedIn: signedIn) == .account(id)
        return widgets.reduce(0) { count, widget in
            switch widget.settings {
            case .openRouter(let settings) where provider == .openRouter:
                count
                    + settings.allBalances.count {
                        $0.options.account == id || usesDefault && $0.options.account == nil
                    }
            case .railway(let settings) where provider == .railway:
                count + (settings.account == id || usesDefault && settings.account == nil ? 1 : 0)
            default: count
            }
        }
    }

    /// Widgets and blocks that name `id` use their provider's default account instead.
    public mutating func forgetReferences(to id: AccountID) {
        for widget in widgets {
            switch widget.settings {
            case .openRouter(var settings):
                var changed = false
                for (block, var options) in settings.allBalances where options.account == id {
                    options.account = nil
                    settings.setBalanceOptions(options, for: block)
                    changed = true
                }
                if changed { updateWidget(widget.id) { $0.settings = .openRouter(settings) } }
            case .railway(var settings) where settings.account == id:
                settings.account = nil
                updateWidget(widget.id) { $0.settings = .railway(settings) }
            default:
                break
            }
        }
    }

    /// Removes the key account `id`, and the widgets that named it use the default. If it was the default and
    /// several accounts are left, the first of them is the default now, so widgets keep showing one.
    public mutating func removeAccount(_ id: AccountID) {
        accounts.removeAll { $0.id == id }
        for (provider, account) in defaultAccounts where account == id {
            let left = keyAccounts(of: provider)
            defaultAccounts[provider] = left.count > 1 ? left[0].id : nil
        }
        forgetReferences(to: id)
    }
}
