import Foundation
import Observation
import Synchronization
import Testing

@testable import Sidelight
@testable import SidelightCore

/// A battery from a script: the test sets the reading and says when macOS would have posted a change.
private final class FakeBattery {
    var reading: BatteryReading? = BatteryReading(percent: 76, isOnACPower: false, timeRemaining: .minutes(192))
    var hardware: BatteryHardware? = BatteryHardware(amperage: -700, voltage: 12_000)
    private(set) var observations = 0
    private(set) var cancellations = 0
    private(set) var hardwareReads = 0
    private var changed: (@Sendable @MainActor () -> Void)?

    var source: BatteryService.Source {
        BatteryService.Source(
            read: { [unowned self] in reading },
            readHardware: { [unowned self] in
                hardwareReads += 1
                return hardware
            },
            observe: { [unowned self] changed in
                observations += 1
                self.changed = changed
                return BatteryService.Subscription { [unowned self] in
                    cancellations += 1
                    self.changed = nil
                }
            })
    }

    /// What macOS tells the service: something about power changed. Nothing happens once it stopped observing.
    func change() {
        changed?()
    }
}

/// Whether reading `value` from `service` is invalidated by running `change`.
private func notifies<Value>(
    _ service: BatteryService, _ value: (BatteryService) -> Value, on change: () -> Void
)
    -> Bool
{
    let didChange = Mutex(false)
    withObservationTracking {
        _ = value(service)
    } onChange: {
        didChange.withLock { $0 = true }
    }
    change()
    return didChange.withLock { $0 }
}

struct BatteryServiceTests {
    @Test func `starting twice subscribes once; stopping ends it; starting again reads at once`() {
        let battery = FakeBattery()
        let service = BatteryService(source: battery.source)
        #expect(service.snapshot == .unknown)
        service.start()
        service.start()
        #expect(battery.observations == 1)
        #expect(service.snapshot.reading?.percent == 76)

        battery.reading?.percent = 75
        battery.change()
        #expect(service.snapshot.reading?.percent == 75)

        service.stop()
        service.stop()
        #expect(battery.cancellations == 1)
        battery.reading?.percent = 74
        battery.change()
        // Stopped: it keeps what it read.
        #expect(service.snapshot.reading?.percent == 75)
        service.start()
        #expect(battery.observations == 2)
        #expect(service.snapshot.reading?.percent == 74)
    }

    @Test func `an unchanged reading publishes nothing`() {
        let battery = FakeBattery()
        let service = BatteryService(source: battery.source)
        service.start()
        #expect(!notifies(service, \.snapshot) { battery.change() })
        #expect(
            notifies(service, \.snapshot) {
                battery.reading?.isLowPowerMode = true
                battery.change()
            })
    }

    @Test func `watts are read only while a widget shows them`() {
        let battery = FakeBattery()
        let service = BatteryService(source: battery.source)
        service.start()
        #expect(battery.hardwareReads == 0)
        #expect(service.snapshot.reading?.watts == nil)

        service.readsPower = true
        #expect(battery.hardwareReads == 1)
        #expect(service.snapshot.reading?.watts == 8.4)
        battery.change()
        #expect(battery.hardwareReads == 2)

        service.readsPower = false
        #expect(service.snapshot.reading?.watts == nil)
        battery.change()
        #expect(battery.hardwareReads == 2)
    }

    @Test func `a stopped service doesn't read when watts are asked for`() {
        let battery = FakeBattery()
        let service = BatteryService(source: battery.source)
        service.readsPower = true
        #expect(battery.hardwareReads == 0)
        #expect(service.snapshot == .unknown)
    }

    @Test func `a Mac without a battery says so`() {
        let battery = FakeBattery()
        battery.reading = nil
        let service = BatteryService(source: battery.source)
        service.start()
        #expect(service.snapshot == .noBattery)
    }

    @Test func `the sample source shows the example, with watts only when asked`() {
        let service = BatteryService(source: .sample())
        service.start()
        #expect(service.snapshot.reading?.percent == BatteryReading.sample.percent)
        #expect(service.snapshot.reading?.watts == nil)
        service.readsPower = true
        #expect(service.snapshot.reading == BatteryReading.sample)
    }
}
