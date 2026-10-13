import Foundation
import Testing

@testable import SidelightCore

struct OpenRouterModelTests {
    @Test(arguments: ["NaN", "garbage", "0.5oops", "", "-2"])
    func `invalid token prices are unknown`(text: String) {
        #expect(OpenRouterTokenPrice(listed: text) == .unknown)
    }

    @Test func `token prices scale exactly and zero does not imply free variant`() {
        #expect(OpenRouterTokenPrice(listed: "0.000000125").perMillion == Decimal(string: "0.125"))
        #expect(OpenRouterTokenPrice(listed: "-1") == .varies)
        #expect(OpenRouterTokenPrice(listed: nil) == .unknown)
        #expect(!OpenRouterModel(id: "vendor/model", name: "Model", inputPrice: .perToken(0)).isFreeVariant)
        #expect(OpenRouterModel(id: "vendor/model:free", name: "Model").isFreeVariant)
    }

    @Test func `strict text filter includes no other modalities but text output does`() {
        let text = OpenRouterModel(id: "a", name: "A", inputModalities: ["text"], outputModalities: ["text"])
        let multimodal = OpenRouterModel(
            id: "b", name: "B", inputModalities: ["text", "image"], outputModalities: ["text"])
        let unknown = OpenRouterModel(id: "c", name: "C", outputModalities: ["future"])
        #expect(text.matches(.textOnly))
        #expect(!multimodal.matches(.textOnly))
        #expect(multimodal.matches(.textOutput))
        #expect(unknown.matches(.all))
        #expect(!unknown.matches(.textOutput))
    }

    @Test func `sorts have stable ID ties unknowns last and limit after filtering`() {
        let recent = Date(timeIntervalSince1970: 100)
        let a = OpenRouterModel(id: "a", name: "Same", created: recent, contextLength: 200, inputPrice: .perToken(1))
        let b = OpenRouterModel(
            id: "b", name: "Same", created: recent, contextLength: 100, inputPrice: .perToken(0),
            outputPrice: .perToken(2))
        let c = OpenRouterModel(id: "c", name: "Same", inputPrice: .varies)
        let catalogue = OpenRouterCatalogue(models: [c, b, a], fetchedAt: recent)
        #expect(catalogue.models.map(\.id) == ["a", "b", "c"])
        #expect(catalogue.models(.all, sortedBy: .name).map(\.id) == ["a", "b", "c"])
        #expect(catalogue.models(.all, sortedBy: .context).map(\.id) == ["a", "b", "c"])
        #expect(catalogue.models(.all, sortedBy: .inputPrice).map(\.id) == ["b", "a", "c"])
        #expect(catalogue.models(.all, sortedBy: .outputPrice).map(\.id) == ["b", "a", "c"])
        #expect(
            catalogue.models(.all, sortedBy: .name, matching: OpenRouterSearchQuery("c"), limit: 1).map(\.id) == ["c"])
        #expect(catalogue.models(.all, sortedBy: .name, limit: 0).isEmpty)
    }

    @Test func `search matches all folded words across name and ID`() {
        let model = OpenRouterModel(id: "vendor/model", name: "Vendor: Café Model")
        #expect(model.matches(query: OpenRouterSearchQuery(" CAFE   VENDOR ")))
        #expect(!model.matches(query: OpenRouterSearchQuery("cafe missing")))
        #expect(model.matches(query: OpenRouterSearchQuery("\n\t")))
    }

    @Test(arguments: ["/evil", "../evil", "a/../../evil", "a?secret", "a#fragment", "a b", "é/model"])
    func `model links reject unsafe IDs`(id: String) {
        #expect(OpenRouterModel(id: id, name: id).pageURL == nil)
    }

    @Test func `safe variant link uses OpenRouter host`() {
        let url = OpenRouterModel(id: "vendor/model:free", name: "Model").pageURL
        #expect(url?.host == "openrouter.ai")
        #expect(url?.path == "/vendor/model:free")
    }

    @Test(arguments: ["2026-03-29T00:00:00Z", "2026-10-25T00:00:00Z", "2024-03-01T00:00:00Z"])
    func `completed days use UTC across DST and leap boundaries`(timestamp: String) throws {
        let date = try #require(Date(iso8601: timestamp))
        let activity = OpenRouterActivity(rows: [], fetchedAt: date)
        let days = activity.days(30)
        #expect(days.count == 30)
        #expect(days.last?.day == UTCDay(date.addingTimeInterval(-1)))
        for pair in zip(days, days.dropFirst()) {
            #expect(pair.1.day.start.timeIntervalSince(pair.0.day.start) == 86_400)
        }
        #expect(activity.days(99).count == 30)
        #expect(activity.days(0).count == 1)
    }
}
