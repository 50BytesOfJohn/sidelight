import Foundation

/// What the battery's own controller (`AppleSmartBattery` in the I/O Registry) says, for what the public power-source
/// API leaves out: the current and voltage, and so the power going in or out.
///
/// Read only when a widget shows power. Every value is optional: macOS has moved these between the top level and its
/// `BatteryData` dictionary before (macOS 27 keeps some only there), so each is looked for at the top first, then
/// inside `BatteryData`.
public struct BatteryHardware: Equatable, Sendable {
    /// The keys read, and nothing else: `BatteryData` holds the rest, nested.
    public static let propertyKeys = ["InstantAmperage", "Amperage", "Voltage", "BatteryData"]

    /// Current in milliamps: positive while charging, negative on battery.
    public var amperage: Int?
    /// In millivolts.
    public var voltage: Int?

    public init(amperage: Int? = nil, voltage: Int? = nil) {
        self.amperage = amperage
        self.voltage = voltage
    }

    /// From `AppleSmartBattery`'s properties. A value of the wrong type reads as missing.
    public init(properties: [String: Any]) {
        let nested = properties["BatteryData"] as? [String: Any] ?? [:]
        func value(_ keys: String...) -> Int? {
            for key in keys {
                if let value = BatteryValue.int(properties[key]) { return value }
            }
            for key in keys {
                if let value = BatteryValue.int(nested[key]) { return value }
            }
            return nil
        }
        self.init(
            // The instant reading follows the load as it changes; the plain one is a running average.
            amperage: value("InstantAmperage", "Amperage"),
            voltage: value("Voltage"))
    }

    /// Power into or out of the battery, in watts rounded to tenths, so small jitter doesn't redraw anything.
    public var watts: Double? {
        guard let amperage, let voltage, voltage > 0 else { return nil }
        let watts = Double(amperage.magnitude) * Double(voltage) / 1_000_000
        return (watts * 10).rounded() / 10
    }
}
