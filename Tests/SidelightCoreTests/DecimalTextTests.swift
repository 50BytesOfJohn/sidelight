import Foundation
import Testing

@testable import SidelightCore

struct DecimalTextTests {
    @Test(arguments: ["0", "-0", "0.125", "-.5", ".5", "1.", "2.5e-7", "4E+2", "-1e-3"])
    func `whole valid decimal fractions and exponents retain their value`(text: String) {
        #expect(Decimal(exactText: text) == Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")))
        #expect(Decimal(exactText: text) != nil)
        #expect((OpenRouterTokenPrice(listed: text).perMillion != nil) == (Decimal(exactText: text)! >= 0))
    }

    @Test(arguments: [
        "", "-", ".", "-.", "NaN", "Infinity", "1e", "1e+", "1.2.3", "12garbage",
        " 12", "12 ", "12\n", "1,25", "0x12", "١٢", "1e99999",
    ])
    func `partial nonfinite or localized decimals are unavailable`(text: String) {
        #expect(Decimal(exactText: text) == nil)
        #expect(OpenRouterTokenPrice(listed: text) == .unknown)
    }
}
