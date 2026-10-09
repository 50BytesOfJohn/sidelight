import Foundation

/// A coding key built from any string, for payloads whose keys we probe in more than one spelling.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Lookups for third-party JSON whose schema we don't control: each value is probed under several key
/// spellings (e.g. `usedPercent` and `used_percent`), numbers are accepted as integers or floating point,
/// and a value of the wrong type reads as `nil` instead of failing the whole payload.
extension KeyedDecodingContainer where Key == AnyCodingKey {
    func lenient<Value: Decodable>(_ type: Value.Type, _ keys: String...) -> Value? {
        for key in keys {
            if let value = try? decodeIfPresent(type, forKey: AnyCodingKey(key)) { return value }
        }
        return nil
    }

    func lenientDouble(_ keys: String...) -> Double? {
        for key in keys {
            if let value = try? decodeIfPresent(Double.self, forKey: AnyCodingKey(key)) { return value }
        }
        return nil
    }

    func lenientInt64(_ keys: String...) -> Int64? {
        for key in keys {
            if let value = try? decodeIfPresent(Int64.self, forKey: AnyCodingKey(key)) { return value }
            if let value = try? decodeIfPresent(Double.self, forKey: AnyCodingKey(key)), value.isFinite {
                return Int64(exactly: value.rounded())
            }
        }
        return nil
    }
}
