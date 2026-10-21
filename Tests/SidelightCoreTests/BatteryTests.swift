import Foundation
import Testing

@testable import SidelightCore

/// An internal battery's IOPS description, as `IOPSGetPowerSourceDescription` gives it, with `changes` over it.
private func battery(_ changes: [String: Any] = [:]) -> [String: Any] {
    let base: [String: Any] = [
        "Type": "InternalBattery", "Name": "InternalBattery-0", "Transport Type": "Internal", "Is Present": true,
        "Current Capacity": 76, "Max Capacity": 100, "Power Source State": "Battery Power", "Is Charging": false,
        "Is Finishing Charge": false, "Time to Empty": 192, "Time to Full Charge": 0, "LPM Active": 0,
    ]
    return base.merging(changes) { $1 }
}

struct BatteryReadingTests {
    @Test func `on battery: the charge and the time until empty`() throws {
        let reading = try #require(BatteryReading(powerSources: [battery()], isLowPowerMode: false))
        #expect(reading.percent == 76)
        #expect(reading.state == .discharging)
        #expect(reading.timeRemaining == .minutes(192))
        #expect(reading.tone == .normal)
        #expect(reading.watts == nil)
    }

    @Test func `charging: the time until full, in green`() throws {
        let description = battery([
            "Power Source State": "AC Power", "Is Charging": 1, "Current Capacity": 38, "Time to Empty": 0,
            "Time to Full Charge": 107,
        ])
        let reading = try #require(BatteryReading(powerSources: [description], isLowPowerMode: false))
        #expect(reading.state == .charging)
        #expect(reading.timeRemaining == .minutes(107))
        #expect(reading.tone == .charging)
    }

    @Test func `minus one is still calculating, either way`() throws {
        let unplugged = try #require(
            BatteryReading(powerSources: [battery(["Time to Empty": -1])], isLowPowerMode: false))
        #expect(unplugged.timeRemaining == .calculating)
        let charging = battery([
            "Power Source State": "AC Power", "Is Charging": true, "Time to Empty": 0, "Time to Full Charge": -1,
        ])
        #expect(BatteryReading(powerSources: [charging], isLowPowerMode: false)?.timeRemaining == .calculating)
    }

    @Test func `plugged in but holding: not charging, no estimate, no warning however low`() throws {
        let description = battery([
            "Power Source State": "AC Power", "Is Charging": false, "Current Capacity": 8, "Time to Empty": 0,
        ])
        let reading = try #require(BatteryReading(powerSources: [description], isLowPowerMode: false))
        #expect(reading.state == .notCharging)
        #expect(reading.timeRemaining == nil)
        #expect(reading.tone == .normal)
    }

    @Test func `plugged in and full: charged`() {
        let description = battery([
            "Power Source State": "AC Power", "Is Charged": true, "Current Capacity": 100, "Time to Empty": 0,
        ])
        #expect(BatteryReading(powerSources: [description], isLowPowerMode: false)?.state == .charged)
    }

    @Test func `finishing a charge gives no time to full`() throws {
        let description = battery([
            "Power Source State": "AC Power", "Is Charging": true, "Is Finishing Charge": true,
            "Time to Full Charge": 12,
        ])
        let reading = try #require(BatteryReading(powerSources: [description], isLowPowerMode: false))
        #expect(reading.isFinishingCharge && reading.timeRemaining == nil)
        #expect(BatteryText.status(reading) == "Finishing charge")
    }

    @Test func `no internal battery, or one that isn't present, reads as none`() {
        #expect(BatteryReading(powerSources: [], isLowPowerMode: false) == nil)
        let ups: [String: Any] = ["Type": "UPS", "Current Capacity": 90, "Max Capacity": 100]
        #expect(BatteryReading(powerSources: [ups], isLowPowerMode: false) == nil)
        #expect(BatteryReading(powerSources: [battery(["Is Present": false])], isLowPowerMode: false) == nil)
        // Another source alongside the battery is passed over.
        #expect(BatteryReading(powerSources: [ups, battery()], isLowPowerMode: false)?.percent == 76)
    }

    @Test func `a capacity out of another maximum is scaled to a percentage`() {
        let description = battery(["Current Capacity": 2_100, "Max Capacity": 4_200])
        #expect(BatteryReading(powerSources: [description], isLowPowerMode: false)?.percent == 50)
    }

    @Test func `values of the wrong type read as missing`() throws {
        let description = battery(["Current Capacity": "lots", "Is Charging": "yes", "Time to Empty": "soon"])
        let reading = try #require(BatteryReading(powerSources: [description], isLowPowerMode: false))
        #expect(reading.percent == 0 && !reading.isCharging && reading.timeRemaining == nil)
    }

    /// Charge, on power, charging, Low Power Mode, and the tone.
    static let tones: [(Int, Bool, Bool, Bool, BatteryTone)] = [
        (50, false, false, false, .normal),
        (20, false, false, false, .low),
        (21, false, false, false, .normal),
        (10, false, false, false, .critical),
        (3, true, true, false, .charging),
        (3, true, false, false, .normal),
        // Low Power Mode wins over everything, as on iPhone.
        (80, false, false, true, .lowPower),
        (5, false, false, true, .lowPower),
        (40, true, true, true, .lowPower),
    ]

    @Test(arguments: tones)
    func `tones go low power first, then charging, then the level on battery`(
        percent: Int, onPower: Bool, charging: Bool, lowPower: Bool, tone: BatteryTone
    ) {
        let reading = BatteryReading(
            percent: percent, isOnACPower: onPower, isCharging: charging, isLowPowerMode: lowPower)
        #expect(reading.tone == tone)
    }

    @Test func `Low Power Mode comes from the system, not the description`() {
        let reading = BatteryReading(powerSources: [battery(["LPM Active": 1])], isLowPowerMode: true)
        #expect(reading?.isLowPowerMode == true)
        #expect(BatteryReading(powerSources: [battery()], isLowPowerMode: false)?.isLowPowerMode == false)
    }
}

struct BatteryTextTests {
    @Test func `the time left reads as a duration, toward empty or full`() {
        let onBattery = BatteryReading(percent: 76, isOnACPower: false, timeRemaining: .minutes(192))
        #expect(BatteryText.timeRemaining(onBattery) == "3h 12m left")
        #expect(BatteryText.shortTimeRemaining(onBattery) == "3h 12m")
        #expect(BatteryText.clockTimeRemaining(onBattery) == "3:12")
        let charging = BatteryReading(percent: 40, isOnACPower: true, isCharging: true, timeRemaining: .minutes(45))
        #expect(BatteryText.timeRemaining(charging) == "45m to full")
        #expect(BatteryText.clockTimeRemaining(charging) == "0:45")
        let hours = BatteryReading(percent: 90, isOnACPower: false, timeRemaining: .minutes(120))
        #expect(BatteryText.shortTimeRemaining(hours) == "2h")
        let calculating = BatteryReading(percent: 90, isOnACPower: false, timeRemaining: .calculating)
        #expect(BatteryText.timeRemaining(calculating) == "Calculating…")
        #expect(BatteryText.clockTimeRemaining(calculating) == "-:--")
        #expect(BatteryText.timeRemaining(BatteryReading(percent: 100, isOnACPower: true)) == nil)
    }

    @Test func `statuses`() {
        #expect(BatteryText.status(BatteryReading(percent: 50, isOnACPower: false)) == "On battery")
        #expect(BatteryText.status(BatteryReading(percent: 50, isOnACPower: true, isCharging: true)) == "Charging")
        #expect(BatteryText.status(BatteryReading(percent: 100, isOnACPower: true)) == "Charged")
        #expect(BatteryText.status(BatteryReading(percent: 80, isOnACPower: true)) == "Not charging")
        #expect(BatteryText.percent(BatteryReading(percent: 7, isOnACPower: false)) == "7%")
        #expect(BatteryText.power(8.4) == "8.4 W")
        #expect(BatteryText.power(24) == "24.0 W")
    }

    @Test func `the detail line drops the status when the estimate says it`() {
        let reading = BatteryReading(percent: 76, isOnACPower: false, timeRemaining: .minutes(192), watts: 8.4)
        #expect(BatteryText.detail(reading, showsTimeRemaining: true, showsPower: true) == "3h 12m left · 8.4 W")
        #expect(BatteryText.detail(reading, showsTimeRemaining: false, showsPower: false) == "On battery")
        let calculating = BatteryReading(percent: 76, isOnACPower: false, timeRemaining: .calculating)
        #expect(
            BatteryText.detail(calculating, showsTimeRemaining: true, showsPower: false) == "On battery · Calculating…")
        let lowPower = BatteryReading(percent: 15, isOnACPower: false, isLowPowerMode: true)
        #expect(BatteryText.detail(lowPower, showsTimeRemaining: true, showsPower: true) == "On battery · Low Power")
    }

    @Test func `the subtitle is what the status line leaves out, or nothing`() {
        let reading = BatteryReading(percent: 76, isOnACPower: false, timeRemaining: .minutes(192), watts: 8.4)
        #expect(BatteryText.subtitle(reading, showsTimeRemaining: true, showsPower: true) == "3h 12m left · 8.4 W")
        #expect(BatteryText.subtitle(reading, showsTimeRemaining: false, showsPower: false) == nil)
    }

    @Test func `VoiceOver hears the whole reading`() {
        let reading = BatteryReading(
            percent: 40, isOnACPower: true, isCharging: true, timeRemaining: .minutes(65), isLowPowerMode: true)
        #expect(
            BatteryText.accessibilityValue(reading, showsTimeRemaining: true, showsPower: false)
                == "40 percent, charging, 1 hour, 5 minutes until full, Low Power Mode")
    }
}

struct BatteryHardwareTests {
    @Test func `older macOS: everything at the top level`() {
        let hardware = BatteryHardware(properties: [
            "InstantAmperage": -1_500, "Amperage": -1_200, "Voltage": 12_000,
        ])
        #expect(hardware.amperage == -1_500)
        #expect(hardware.voltage == 12_000)
        #expect(hardware.watts == 18)
    }

    @Test func `voltage and amperage are read when BatteryData holds extra keys`() {
        let hardware = BatteryHardware(properties: [
            "InstantAmperage": 3_262, "Amperage": 3_262, "Voltage": 12_360,
            "BatteryData": [
                "FullChargeCapacity": 4_143, "NominalChargeCapacity": 4_276, "DesignCapacity": 5_103,
                "RemainingCapacity": 1_533, "CurrentCapacity": 38, "MaxCapacity": 100,
            ] as [String: Any],
        ])
        #expect(hardware.watts == 40.3)
    }

    @Test func `the top level wins over BatteryData, which fills what it lacks`() {
        let hardware = BatteryHardware(properties: [
            "Voltage": 12_000, "BatteryData": ["Voltage": 11_000, "InstantAmperage": -500] as [String: Any],
        ])
        #expect(hardware.voltage == 12_000)
        #expect(hardware.amperage == -500)
        #expect(hardware.watts == 6)
    }

    @Test func `a negative current stored unsigned reads as negative`() {
        let hardware = BatteryHardware(properties: [
            "InstantAmperage": NSNumber(value: UInt64(bitPattern: -1_234)), "Voltage": NSNumber(value: 11_500),
        ])
        #expect(hardware.amperage == -1_234)
        #expect(hardware.watts == 14.2)
    }

    @Test func `missing or odd values give no watts`() {
        #expect(BatteryHardware(properties: [:]) == BatteryHardware())
        #expect(BatteryHardware(properties: [:]).watts == nil)
        #expect(BatteryHardware(properties: ["InstantAmperage": "x", "Voltage": 12_000]).watts == nil)
        #expect(BatteryHardware(properties: ["InstantAmperage": 100, "Voltage": 0]).watts == nil)
        #expect(BatteryHardware(properties: ["BatteryData": "nope"]).voltage == nil)
    }
}

struct BatteryPixelCellTests {
    @Test func `a started bar counts whole, and none lights at zero`() {
        func litBars(_ percent: Int) -> Int {
            // Each bar is two dots wide and three tall: count lit dots in the middle row inside the outline.
            let line = PixelLine.batteryCell(percent: percent)
            return line.lit.filter { $0.row == 3 && $0.column > 1 && $0.column < line.columns - 3 }.count / 2
        }
        #expect(litBars(0) == 0)
        #expect(litBars(1) == 1)
        #expect(litBars(20) == 1)
        #expect(litBars(62) == 4)
        #expect(litBars(100) == 5)
    }

    @Test func `as tall as text, every dot lit or unlit once`() {
        let line = PixelLine.batteryCell(percent: 50)
        #expect(line.rows == PixelFont.height)
        #expect(line.columns == 19)
        let all = line.lit + line.unlit
        #expect(Set(all).count == all.count)
        #expect(all.allSatisfy { (0..<line.columns).contains($0.column) && (0..<line.rows).contains($0.row) })
    }
}

struct BatteryConfigurationTests {
    @Test func `settings round-trip`() throws {
        var settings = BatterySettings(style: .pixel, showsTimeRemaining: false, showsPower: true)
        settings.glyph = GlyphBatteryOptions(showsPercent: false)
        settings.ring = RingBatteryOptions(gauge: .ticks)
        settings.cell = CellBatteryOptions(finish: .flat)
        settings.pixel = PixelBatteryOptions(color: .cyan, showsUnlitPixels: false, glows: false)
        let widget = WidgetInstance(settings: .battery(settings))
        let data = try JSONEncoder().encode(widget)
        #expect(try JSONDecoder().decode(WidgetInstance.self, from: data) == widget)
    }

    @Test func `missing settings take their defaults`() throws {
        let id = UUID()
        let json = #"{"id": "\#(id)", "kind": "battery", "showsInSidePanel": true, "showsInBar": true}"#
        let widget = try JSONDecoder().decode(WidgetInstance.self, from: Data(json.utf8))
        #expect(widget.settings == .battery(BatterySettings()))
        let defaults = BatterySettings()
        #expect(defaults.style == .ring && defaults.showsTimeRemaining && !defaults.showsPower)
        #expect(defaults.glyph.showsPercent && defaults.ring.gauge == .solid && defaults.cell.finish == .glass)
        #expect(defaults.pixel.showsUnlitPixels && defaults.pixel.glows)
    }

    @Test func `an unknown style or option, or an odd value, falls back without failing the rest`() throws {
        let json = #"""
            {"style": "hologram", "showsTimeRemaining": "maybe", "showsPower": true,
             "ring": {"gauge": "spiral"}, "cell": 7, "pixel": {"color": "plaid", "glows": false}}
            """#
        let settings = try JSONDecoder().decode(BatterySettings.self, from: Data(json.utf8))
        #expect(settings.style == .ring)
        #expect(settings.showsTimeRemaining)
        #expect(settings.showsPower)
        #expect(settings.ring.gauge == .solid)
        #expect(settings.cell == CellBatteryOptions())
        #expect(settings.pixel.color == PixelBatteryOptions().color)
        #expect(!settings.pixel.glows)
    }

    private func configuration(_ widgets: [WidgetInstance]) -> AppConfiguration {
        var configuration = AppConfiguration()
        configuration.sections = [PanelSection(widgets: widgets)]
        return configuration
    }

    @Test func `the battery runs for a visible widget, and reads watts only if one shows them`() {
        let plain = WidgetInstance(settings: .battery(BatterySettings()))
        let watts = WidgetInstance(
            settings: .battery(BatterySettings(showsPower: true)), showsInSidePanel: false, showsInBar: true)

        let side = configuration([plain, watts]).serviceDemand(at: [.left])
        #expect(side.kinds.contains(.battery))
        #expect(!side.battery.readsPower)

        let bar = configuration([plain, watts]).serviceDemand(at: [.top])
        #expect(bar.kinds.contains(.battery))
        #expect(bar.battery.readsPower)

        let hidden = configuration([watts]).serviceDemand(at: [.left])
        #expect(!hidden.kinds.contains(.battery))
        #expect(!hidden.battery.readsPower)

        #expect(configuration([plain]).serviceDemand(at: []).kinds.isEmpty)
        #expect(configuration([watts]).serviceDemand(at: [.top]).limited(to: [.clock]).battery == BatteryDemand())
    }

    @Test func `the Widgets window previews the battery`() {
        let demand = configuration([]).serviceDemand(at: [], previewsEveryWidget: true)
        #expect(demand.kinds.contains(.battery))
        #expect(!demand.battery.readsPower)
    }
}
