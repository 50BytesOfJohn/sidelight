import Foundation

/// The words battery widgets show, the same in every style.
public enum BatteryText {
    /// `84%`.
    public static func percent(_ reading: BatteryReading) -> String {
        "\(reading.percent)%"
    }

    /// `On battery`, `Charging`, `Finishing charge`, `Charged`, `Not charging`.
    public static func status(_ reading: BatteryReading) -> String {
        switch reading.state {
        case .discharging: "On battery"
        case .charging: reading.isFinishingCharge ? "Finishing charge" : "Charging"
        case .charged: "Charged"
        case .notCharging: "Not charging"
        }
    }

    /// `3h 12m left`, `45m to full`, `Calculating…`; `nil` when there's no estimate to give.
    public static func timeRemaining(_ reading: BatteryReading) -> String? {
        switch reading.timeRemaining {
        case nil: nil
        case .calculating: "Calculating…"
        case .minutes(let minutes):
            "\(duration(minutes)) \(reading.state == .charging ? "to full" : "left")"
        }
    }

    /// The estimate alone, for glances: `3h 12m`, `45m`, `…` while calculating.
    public static func shortTimeRemaining(_ reading: BatteryReading) -> String? {
        switch reading.timeRemaining {
        case nil: nil
        case .calculating: "…"
        case .minutes(let minutes): duration(minutes)
        }
    }

    /// The estimate as a clock reads, for dot-matrix faces: `3:12`, `0:45`, `-:--` while calculating.
    public static func clockTimeRemaining(_ reading: BatteryReading) -> String? {
        switch reading.timeRemaining {
        case nil: nil
        case .calculating: "-:--"
        case .minutes(let minutes): "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
        }
    }

    /// `8.4 W`, `24.0 W`.
    public static func power(_ watts: Double) -> String {
        String(format: "%.1f W", watts)
    }

    /// `3h 12m`, `3h`, `45m`.
    static func duration(_ minutes: Int) -> String {
        let minutes = max(0, minutes)
        return switch (minutes / 60, minutes % 60) {
        case (0, let minutes): "\(minutes)m"
        case (let hours, 0): "\(hours)h"
        case (let hours, let minutes): "\(hours)h \(minutes)m"
        }
    }

    /// Everything a widget was asked to show beside the charge, on one line: `On battery · 3h 12m left · 8.4 W`.
    /// The status gives way to the estimate when both say the same, and Low Power Mode is named when it's on.
    public static func detail(_ reading: BatteryReading, showsTimeRemaining: Bool, showsPower: Bool) -> String {
        var parts: [String] = []
        let time = showsTimeRemaining ? timeRemaining(reading) : nil
        // `3h 12m left` says it's on battery, and `45m to full` that it's charging.
        if time == nil || reading.timeRemaining == .calculating { parts.append(status(reading)) }
        if let time { parts.append(time) }
        if showsPower, let watts = reading.watts { parts.append(power(watts)) }
        if reading.isLowPowerMode { parts.append("Low Power") }
        return parts.joined(separator: " · ")
    }

    /// What goes under the status, when the status has a line of its own: `3h 12m left · 8.4 W · Low Power`; `nil` when
    /// there's nothing to add.
    public static func subtitle(_ reading: BatteryReading, showsTimeRemaining: Bool, showsPower: Bool) -> String? {
        var parts: [String] = []
        if showsTimeRemaining, let time = timeRemaining(reading) { parts.append(time) }
        if showsPower, let watts = reading.watts { parts.append(power(watts)) }
        if reading.isLowPowerMode { parts.append("Low Power") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What VoiceOver reads: `76 percent, on battery, 3 hours 12 minutes left, Low Power Mode`.
    public static func accessibilityValue(_ reading: BatteryReading, showsPower: Bool) -> String {
        var parts = ["\(reading.percent) percent", status(reading).lowercased()]
        switch reading.timeRemaining {
        case nil: break
        case .calculating: parts.append("calculating time")
        case .minutes(let minutes):
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.hour, .minute]
            formatter.unitsStyle = .full
            let spoken = formatter.string(from: TimeInterval(minutes * 60)) ?? duration(minutes)
            parts.append("\(spoken) \(reading.state == .charging ? "until full" : "left")")
        }
        if showsPower, let watts = reading.watts { parts.append("\(watts.formatted()) watts") }
        if reading.isLowPowerMode { parts.append("Low Power Mode") }
        return parts.joined(separator: ", ")
    }
}
