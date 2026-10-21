import Foundation

/// How long until the battery is empty, or full while it charges, as macOS estimates it.
public enum BatteryTimeEstimate: Equatable, Sendable {
    /// macOS is still working it out: just after unplugging, plugging in or waking.
    case calculating
    case minutes(Int)
}

/// Whether the battery is filling, emptying or neither.
public enum BatteryChargeState: Equatable, Sendable {
    /// Running on the battery.
    case discharging
    case charging
    /// On power and full.
    case charged
    /// On power but holding: Optimized Charging waiting at 80 %, a charge limit, or an adapter too weak to charge.
    case notCharging
}

/// What a battery widget colors itself with. Charging only counts while the battery is actually filling, so green
/// stays meaningful, and low levels only on battery: plugged in, a low battery is on its way up.
public enum BatteryTone: Equatable, Sendable {
    case normal
    case charging
    /// Low Power Mode is on: yellow, as on iPhone, whatever the level.
    case lowPower
    /// At or under ``BatteryReading/lowPercent`` on battery.
    case low
    /// At or under ``BatteryReading/criticalPercent`` on battery.
    case critical
}

/// One look at the Mac's internal battery, from the public power-source API (IOPS).
public struct BatteryReading: Equatable, Sendable {
    public static let lowPercent = 20
    public static let criticalPercent = 10

    /// Charge, 0–100.
    public var percent: Int
    /// Plugged in to power.
    public var isOnACPower: Bool
    public var isCharging: Bool
    /// Full, according to macOS. Only while on power.
    public var isCharged: Bool
    /// The slow last few percent: macOS gives no time to full then.
    public var isFinishingCharge: Bool
    /// Until empty on battery, until full while charging; `nil` when neither applies.
    public var timeRemaining: BatteryTimeEstimate?
    public var isLowPowerMode: Bool
    /// Power going into or out of the battery, in watts, rounded to tenths. `nil` unless asked for, or unreadable.
    public var watts: Double?

    public init(
        percent: Int, isOnACPower: Bool, isCharging: Bool = false, isCharged: Bool = false,
        isFinishingCharge: Bool = false, timeRemaining: BatteryTimeEstimate? = nil, isLowPowerMode: Bool = false,
        watts: Double? = nil
    ) {
        self.percent = percent.clamped(to: 0...100)
        self.isOnACPower = isOnACPower
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.isFinishingCharge = isFinishingCharge
        self.timeRemaining = timeRemaining
        self.isLowPowerMode = isLowPowerMode
        self.watts = watts
    }

    public var state: BatteryChargeState {
        if !isOnACPower { return .discharging }
        if isCharging { return .charging }
        return isCharged || percent >= 100 ? .charged : .notCharging
    }

    /// Low Power Mode first, as on iPhone, then charging, then how low the battery is running.
    public var tone: BatteryTone {
        if isLowPowerMode { return .lowPower }
        switch state {
        case .charging: return .charging
        case .charged, .notCharging: return .normal
        case .discharging:
            if percent <= Self.criticalPercent { return .critical }
            if percent <= Self.lowPercent { return .low }
            return .normal
        }
    }

    /// An example for previews on a Mac without a battery: a working afternoon on battery.
    public static let sample = BatteryReading(
        percent: 76, isOnACPower: false, timeRemaining: .minutes(3 * 60 + 12), watts: 8.4)
}

/// What a battery widget can show.
public enum BatterySnapshot: Equatable, Sendable {
    /// Not read yet.
    case unknown
    /// This Mac has no internal battery: a Mac mini, Studio or Pro, or an iMac.
    case noBattery
    case battery(BatteryReading)

    public var reading: BatteryReading? {
        if case .battery(let reading) = self { reading } else { nil }
    }
}

extension BatteryReading {
    /// The internal battery among IOPS power-source descriptions (`IOPSGetPowerSourceDescription`); `nil` when there's
    /// none, or it isn't present. A UPS or a mouse's battery is another type, and left alone.
    public init?(powerSources descriptions: [[String: Any]], isLowPowerMode: Bool) {
        guard
            let battery = descriptions.first(where: {
                $0["Type"] as? String == "InternalBattery" && BatteryValue.bool($0["Is Present"]) != false
            })
        else { return nil }
        self.init(description: battery, isLowPowerMode: isLowPowerMode)
    }

    /// One internal battery's IOPS description. Missing values read as the battery's quietest state.
    init(description: [String: Any], isLowPowerMode: Bool) {
        let current = BatteryValue.int(description["Current Capacity"]) ?? 0
        let maximum = BatteryValue.int(description["Max Capacity"]) ?? 100
        // Apple Silicon reports a percentage over a maximum of 100; anything else is scaled.
        let percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
        let isOnACPower = description["Power Source State"] as? String == "AC Power"
        let isCharging = BatteryValue.bool(description["Is Charging"]) ?? false
        let isFinishing = BatteryValue.bool(description["Is Finishing Charge"]) ?? false
        let time: BatteryTimeEstimate? =
            if !isOnACPower {
                Self.estimate(description["Time to Empty"])
            } else if isCharging && !isFinishing {
                Self.estimate(description["Time to Full Charge"])
            } else {
                nil
            }
        self.init(
            percent: percent, isOnACPower: isOnACPower, isCharging: isCharging,
            isCharged: BatteryValue.bool(description["Is Charged"]) ?? false, isFinishingCharge: isFinishing,
            timeRemaining: time, isLowPowerMode: isLowPowerMode)
    }

    /// IOPS gives minutes, `-1` while it's calculating. Zero is no estimate: on power, Time to Empty reads 0.
    private static func estimate(_ value: Any?) -> BatteryTimeEstimate? {
        guard let minutes = BatteryValue.int(value) else { return nil }
        if minutes < 0 { return .calculating }
        return minutes > 0 ? .minutes(minutes) : nil
    }
}

/// Values out of IOKit dictionaries, which arrive as `NSNumber`s (or Swift numbers in tests). Anything else is `nil`.
enum BatteryValue {
    static func int(_ value: Any?) -> Int? {
        int64(value).flatMap { Int(exactly: $0) }
    }

    /// Signed, so a negative current that IOKit stores as an unsigned 64-bit number reads as negative.
    static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let value as Int: Int64(value)
        case let value as Int64: value
        case let value as UInt64: Int64(bitPattern: value)
        case let value as Double where value.isFinite && abs(value) < 9e18: Int64(value.rounded())
        case let value as NSNumber: value.int64Value
        default: nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool: value
        case let value as Int: value != 0
        case let value as NSNumber: value.boolValue
        default: nil
        }
    }
}
