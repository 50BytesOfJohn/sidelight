import Foundation
import Testing

@testable import SidelightCore

/// Fail closed before a native launch can silently load default widgets or enable window movement.
struct NativeFixtureSafetyTests {
    static let path = ProcessInfo.processInfo.environment["SIDELIGHT_NATIVE_FIXTURE"]

    @Test(.enabled(if: path != nil))
    func `native launch fixture decodes and enables only isolated OpenRouter surfaces`() throws {
        let path = try #require(Self.path)
        let data = try Data(contentsOf: URL(filePath: path))
        let configuration = try AppConfiguration(json: data)
        #expect(configuration.windowAvoidance == .off)
        #expect(configuration.displays.isEmpty)
        #expect(!configuration.widgets.isEmpty)
        #expect(configuration.widgets.allSatisfy { $0.kind == .openRouter })
        #expect(configuration.openRouterDemand(panels: []).needsAccount == false)
        #expect(!configuration.appearance.background.color.isAnimated)
    }
}
