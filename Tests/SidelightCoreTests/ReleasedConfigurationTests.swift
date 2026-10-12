import Foundation
import Testing

@testable import SidelightCore

/// An app update must never reset someone's panel. Each file in `ReleasedConfigurations` was saved by that
/// release's own code, with every option it offered set away from its default (v0.1.0 and v0.1.1 save the same
/// schema as v0.1.2). Loading one and saving it again must keep everything it says; newer options may only add to
/// it. The one exception is a retired widget kind, which is dropped on purpose (``WidgetKind/retiredRawValues``).
struct ReleasedConfigurationTests {
    static let releases = ["v0.1.2", "v0.2.0", "v0.2.1", "v0.3.0", "v0.4.0"]

    @Test(arguments: releases)
    func `a released configuration loads with every setting kept`(release: String) throws {
        let url = try #require(
            Bundle.module.url(forResource: release, withExtension: "json", subdirectory: "ReleasedConfigurations"))
        let released = try Data(contentsOf: url)
        let saved = try AppConfiguration(json: released).json()
        let kept = try Self.values(in: JSONSerialization.jsonObject(with: saved))
        let expected = try Self.withoutRetiredWidgets(JSONSerialization.jsonObject(with: released))
        let changed = Self.values(in: expected).filter { path, value in kept[path] != value }
        #expect(changed.isEmpty, "Lost or changed: \(changed.keys.sorted())")
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

    /// Every value in a JSON document, by its path, such as `sections.<id>.widgets.<id>.settings.style`. Elements
    /// with an `id` are found by it, so a dropped widget doesn't move the ones after it.
    private static func values(in json: Any, at path: String = "") -> [String: NSObject] {
        func child(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }
        switch json {
        case let object as [String: Any]:
            return object.reduce(into: [:]) { $0.merge(values(in: $1.value, at: child($1.key))) { $1 } }
        case let array as [Any]:
            return array.enumerated().reduce(into: [:]) { result, element in
                let key = ((element.element as? [String: Any])?["id"] as? String) ?? "\(element.offset)"
                result.merge(values(in: element.element, at: child(key))) { $1 }
            }
        default:
            return [path: json as? NSObject ?? NSNull()]
        }
    }
}
