import Foundation

extension Decimal {
    /// `text` as a number when all of it is one: `12`, `-1`, `0.0000005`, `2.5e-7`. `nil` for anything else,
    /// including `12garbage`, which `Decimal(string:)` would read as 12, and `NaN`. Money and prices are read this way,
    /// so a damaged value is never taken for a smaller one.
    public init?(exactText text: String) {
        guard Self.isPlainNumber(text),
            let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN
        else { return nil }
        self = value
    }

    /// An optional minus, digits with an optional fraction, and an optional exponent; nothing before or after.
    private static func isPlainNumber(_ text: String) -> Bool {
        var rest = text.utf8[...]
        func skipDigits() -> Int {
            let count = rest.prefix(while: { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }).count
            rest = rest.dropFirst(count)
            return count
        }
        if rest.first == UInt8(ascii: "-") { rest = rest.dropFirst() }
        var digits = skipDigits()
        if rest.first == UInt8(ascii: ".") {
            rest = rest.dropFirst()
            digits += skipDigits()
        }
        guard digits > 0 else { return false }
        if rest.first == UInt8(ascii: "e") || rest.first == UInt8(ascii: "E") {
            rest = rest.dropFirst()
            if rest.first == UInt8(ascii: "+") || rest.first == UInt8(ascii: "-") { rest = rest.dropFirst() }
            guard skipDigits() > 0 else { return false }
        }
        return rest.isEmpty
    }
}
