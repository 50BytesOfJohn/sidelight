import Foundation
import IOKit
import IOKit.ps
import Observation
import SidelightCore
import notify
import os

/// The Mac's battery, for every Battery widget.
///
/// It's told when anything about power changes and never checks on a timer: macOS posts a notification whenever the
/// charge, the power source or its estimate changes, and another when Low Power Mode turns on or off. Each one reads
/// the battery again, and publishes only when what a widget shows has changed, so an unchanged reading redraws nothing.
@Observable
final class BatteryService: DataService {
    /// Ends an observation.
    struct Subscription {
        let cancel: () -> Void
    }

    /// Where readings come from; tests and previews stand in their own.
    struct Source {
        /// The internal battery's charge and state; `nil` on a Mac without one.
        var read: () -> BatteryReading?
        /// What the battery's controller says, for watts; `nil` when it can't be read.
        var readHardware: () -> BatteryHardware?
        /// Calls `changed` on the main actor whenever power or Low Power Mode changes.
        var observe: (_ changed: @escaping @Sendable @MainActor () -> Void) -> Subscription

        /// The real battery: IOPS for the charge, the I/O Registry for watts.
        static var system: Source {
            Source(
                read: {
                    BatteryReading(
                        powerSources: PowerSources.descriptions(),
                        isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
                },
                readHardware: { SmartBattery.read() },
                observe: { changed in
                    var token = NOTIFY_TOKEN_INVALID
                    let status = notify_register_dispatch(kIOPSNotifyAnyPowerSource, &token, .main) { _ in
                        MainActor.assumeIsolated { changed() }
                    }
                    if status != NOTIFY_STATUS_OK {
                        Log.battery.error("Can't watch power sources: notify status \(status)")
                    }
                    let lowPower = NotificationCenter.default.addObserver(
                        forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
                    ) { _ in
                        MainActor.assumeIsolated { changed() }
                    }
                    return Subscription {
                        if status == NOTIFY_STATUS_OK { notify_cancel(token) }
                        NotificationCenter.default.removeObserver(lowPower)
                    }
                })
        }

        /// Always `reading`, and never changes: for trying the widget on a Mac without a battery.
        static func sample(_ reading: BatteryReading? = .sample) -> Source {
            Source(
                read: {
                    reading.map {
                        var reading = $0
                        reading.watts = nil
                        return reading
                    }
                },
                // Gives back the watts `read` strips, so they survive while readsPower is on.
                readHardware: {
                    guard let watts = reading?.watts else { return nil }
                    return BatteryHardware(amperage: Int(watts * 100), voltage: 10_000)
                },
                observe: { _ in Subscription {} })
        }
    }

    /// What battery widgets show. Assigned only when it changes.
    private(set) var snapshot = BatterySnapshot.unknown

    /// A widget shows watts, so the battery's controller is read too.
    var readsPower = false {
        didSet {
            guard readsPower != oldValue, subscription != nil else { return }
            publish()
        }
    }

    @ObservationIgnored private let source: Source
    @ObservationIgnored private var subscription: Subscription?

    init(source: Source = .system) {
        self.source = source
    }

    func start() {
        guard subscription == nil else { return }
        subscription = source.observe { [weak self] in self?.publish() }
        publish()
    }

    /// Keeps the last reading: the next start reads again at once.
    func stop() {
        subscription?.cancel()
        subscription = nil
    }

    private func publish() {
        let next: BatterySnapshot
        if var reading = source.read() {
            if readsPower { reading.watts = source.readHardware()?.watts }
            next = .battery(reading)
        } else {
            next = .noBattery
        }
        guard next != snapshot else { return }
        if case .noBattery = next { Log.battery.notice("No internal battery") }
        snapshot = next
    }
}

/// The public power-source API, as plain dictionaries.
private enum PowerSources {
    static func descriptions() -> [[String: Any]] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return [] }
        return list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
    }
}

/// `AppleSmartBattery` in the I/O Registry: only the keys ``BatteryHardware`` needs, never the whole entry.
private enum SmartBattery {
    static func read() -> BatteryHardware? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var properties: [String: Any] = [:]
        for key in BatteryHardware.propertyKeys {
            if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
            {
                properties[key] = value
            }
        }
        return BatteryHardware(properties: properties)
    }
}
