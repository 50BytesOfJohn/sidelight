import Foundation

/// An amount of money in a provider's answer, which may come as a JSON number or as a decimal string. Read without
/// going through `Double`, and only when all of it is a number.
enum ReportedAmount: Equatable {
    /// Not in the answer, or `null`.
    case absent
    case amount(Decimal)
    /// There, but not a number: the answer can't be vouched for.
    case unreadable

    init(_ container: KeyedDecodingContainer<AnyCodingKey>, _ key: String) {
        let codingKey = AnyCodingKey(key)
        guard container.contains(codingKey), (try? container.decodeNil(forKey: codingKey)) == false else {
            self = .absent
            return
        }
        if let value = try? container.decode(Decimal.self, forKey: codingKey), !value.isNaN {
            self = .amount(value)
        } else if let text = try? container.decode(String.self, forKey: codingKey),
            let value = Decimal(exactText: text)
        {
            self = .amount(value)
        } else {
            self = .unreadable
        }
    }

    /// The amount, when there is one.
    var value: Decimal? {
        if case .amount(let value) = self { value } else { nil }
    }
}
