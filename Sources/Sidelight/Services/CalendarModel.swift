import Cocoa
import EventKit

// MARK: - Calendar

final class CalendarModel: ObservableObject {
    let store = EKEventStore()
    @Published var authorized = false
    @Published var events: [EKEvent] = []
    private var timer: Timer?
    init() {
        refresh()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 30
    }
    func refresh() {
        let st = EKEventStore.authorizationStatus(for: .event)
        authorized = (st == .fullAccess)
        guard authorized else { events = []; return }
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: start))!
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = Array(store.events(matching: pred).sorted { $0.startDate < $1.startDate }.prefix(10))
    }
    func requestAccess() {
        let st = EKEventStore.authorizationStatus(for: .event)
        if st == .denied || st == .restricted || st == .writeOnly {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        store.requestFullAccessToEvents { _, _ in DispatchQueue.main.async { self.refresh() } }
    }
}

