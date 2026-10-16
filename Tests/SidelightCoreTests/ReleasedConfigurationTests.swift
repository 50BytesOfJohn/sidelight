import Foundation
import Testing

@testable import SidelightCore

/// An app update must never reset someone's panel. Each file in `ReleasedConfigurations` was saved by that
/// release's own code, with every option it offered set away from its default (v0.1.0 and v0.1.1 save the same
/// schema as v0.1.2). Loading one and saving it again must keep everything it says; newer options may only add to
/// it. The exceptions are a retired widget kind, which is dropped on purpose (``WidgetKind/retiredRawValues``), the
/// credential choices widgets saved before shared accounts, which are left behind on purpose: accounts start
/// empty (``withoutCredentialChoices(_:)``), and the agents an AI Usage widget showed before it was built from blocks,
/// which start over as every agent's block (``withoutAIUsageAgents(_:)``).
struct ReleasedConfigurationTests {
    static let legacyReleases = ["v0.1.2", "v0.2.0", "v0.2.1", "v0.3.0", "v0.4.0", "v0.5.0", "v0.6.0"]
    static let releases = legacyReleases + ["v0.7.0", "v0.7.1", "v0.8.0", "v0.9.0"]

    @Test(arguments: releases.filter { $0 != ReleasedConfigurationFixture.release })
    func `a released configuration loads with every setting kept`(release: String) throws {
        let released = try Self.load(release)
        let saved = try AppConfiguration(json: released).json()
        let kept = try Self.values(in: JSONSerialization.jsonObject(with: saved))
        let original = try Self.withoutAIUsageAgents(
            Self.withoutRetiredWidgets(JSONSerialization.jsonObject(with: released)))
        let expected = Self.legacyReleases.contains(release) ? Self.withoutCredentialChoices(original) : original
        let changed = Self.values(in: expected).filter { path, value in kept[path] != value }
        #expect(changed.isEmpty, "Lost or changed: \(changed.keys.sorted())")
    }

    @Test(arguments: legacyReleases)
    func `old credential choices are left behind, and every widget uses its default account`(release: String) throws {
        let loaded = try AppConfiguration(json: Self.load(release))
        let saved = String(decoding: try loaded.json(), as: UTF8.self)
        #expect(!saved.contains("usesOwnKey") && !saved.contains(#""account" :"#))
        #expect(loaded.accounts.isEmpty && loaded.defaultAccounts.isEmpty)
        for widget in loaded.widgets {
            switch widget.settings {
            case .railway(let settings): #expect(settings.account == nil)
            case .openRouter(let settings): #expect(settings.allBalances.allSatisfy { $0.options.account == nil })
            default: break
            }
        }
    }

    @Test func `the retired Agent activity widget is the only one dropped`() throws {
        let url = try #require(
            Bundle.module.url(forResource: "v0.2.0", withExtension: "json", subdirectory: "ReleasedConfigurations"))
        let released = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let sections = try #require(released["sections"] as? [[String: Any]])
        let kinds = sections.flatMap { ($0["widgets"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String } }
        #expect(kinds.contains("agents"))
        let loaded = try AppConfiguration(json: Data(contentsOf: url))
        #expect(loaded.widgets.map(\.kind.rawValue) == kinds.filter { $0 != "agents" })
    }

    private static func load(_ release: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: release, withExtension: "json", subdirectory: "ReleasedConfigurations"))
        return try Data(contentsOf: url)
    }

    private static func withoutRetiredWidgets(_ json: Any) -> Any {
        switch json {
        case let object as [String: Any]:
            return object.mapValues(withoutRetiredWidgets)
        case let array as [Any]:
            return array.filter { element in
                ((element as? [String: Any])?["kind"] as? String).map { !WidgetKind.retiredRawValues.contains($0) }
                    ?? true
            }
            .map(withoutRetiredWidgets)
        default:
            return json
        }
    }

    /// `json` without the credential choices widgets saved before shared accounts: a Balance block's `usesOwnKey`
    /// and a Railway widget's `account`.
    private static func withoutCredentialChoices(_ json: Any) -> Any {
        guard var root = json as? [String: Any], let sections = root["sections"] as? [[String: Any]] else {
            return json
        }
        root["sections"] = sections.map { section in
            var section = section
            section["widgets"] = (section["widgets"] as? [[String: Any]] ?? []).map { widget in
                guard var settings = widget["settings"] as? [String: Any] else { return widget }
                var widget = widget
                settings["account"] = nil
                if let balances = settings["balances"] as? [String: [String: Any]] {
                    settings["balances"] = balances.mapValues { $0.filter { $0.key != "usesOwnKey" } }
                }
                widget["settings"] = settings
                return widget
            }
            return section
        }
        return root
    }

    /// `json` without the agents AI Usage widgets saved before blocks: `providers` and `claudeAccount`. How limits
    /// read and when they're fetched are kept.
    private static func withoutAIUsageAgents(_ json: Any) -> Any {
        guard var root = json as? [String: Any], let sections = root["sections"] as? [[String: Any]] else {
            return json
        }
        root["sections"] = sections.map { section in
            var section = section
            section["widgets"] = (section["widgets"] as? [[String: Any]] ?? []).map { widget in
                guard widget["kind"] as? String == "aiUsage", var settings = widget["settings"] as? [String: Any]
                else { return widget }
                var widget = widget
                settings["providers"] = nil
                settings["claudeAccount"] = nil
                widget["settings"] = settings
                return widget
            }
            return section
        }
        return root
    }

    /// Every value in a JSON document, by its path, such as `sections.<id>.widgets.<id>.settings.style`. Elements
    /// with an `id` are found by it, so a dropped widget doesn't move the ones after it.
    private static func values(in json: Any, at path: String = "") -> [String: NSObject] {
        func child(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }
        switch json {
        case let object as [String: Any]:
            return object.reduce(into: [:]) { $0.merge(values(in: $1.value, at: child($1.key))) { $1 } }
        case let array as [Any]:
            let ids = array.compactMap { ($0 as? [String: Any])?["id"] as? String }
            let order: [String: NSObject] = ids.isEmpty ? [:] : [child("$order"): ids as NSArray]
            return array.enumerated().reduce(into: order) { result, element in
                let key = ((element.element as? [String: Any])?["id"] as? String) ?? "\(element.offset)"
                result.merge(values(in: element.element, at: child(key))) { $1 }
            }
        default:
            return [path: json as? NSObject ?? NSNull()]
        }
    }
}
