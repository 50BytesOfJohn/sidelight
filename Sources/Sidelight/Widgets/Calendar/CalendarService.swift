import AppKit
import EventKit
import Observation
import SidelightCore
import SwiftUI
import os

/// A calendar event, copied out of EventKit so views never hold on to `EKEvent`s. Made off the main actor, where
/// events are read.
nonisolated struct CalendarEvent: Identifiable, Hashable, Sendable {
    /// Unique per occurrence: recurring events share their item identifier, so the start date is part of it.
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let color: Color

    init(_ event: EKEvent) {
        id = "\(event.calendarItemIdentifier)@\(event.startDate.timeIntervalSinceReferenceDate)"
        title = event.title ?? ""
        startDate = event.startDate
        endDate = event.endDate
        isAllDay = event.isAllDay
        color = Color(cgColor: event.calendar.cgColor)
    }
}

/// Upcoming events for today and tomorrow, kept fresh while running.
///
/// Reading events is synchronous and can take a while with many calendars, so it runs off the main actor in
/// ``EventStore``; the store's change notifications, which come in bursts while calendars sync, are gathered into one.
@Observable
final class CalendarService: DataService {
    enum Access {
        case notDetermined
        case granted
        /// Denied, restricted or write-only; only System Settings can change it.
        case denied
    }

    nonisolated static let maximumEvents = 10
    static let refreshInterval: Duration = .seconds(300)

    private(set) var access: Access = CalendarService.currentAccess
    /// Sorted by start date.
    private(set) var upcomingEvents: [CalendarEvent] = []

    @ObservationIgnored private let store = EventStore()
    @ObservationIgnored private let refreshes = RepeatingTask()
    @ObservationIgnored private let reload = CoalescedReload()
    @ObservationIgnored private var storeChangeObserver: (any NSObjectProtocol)?
    /// Between `start()` and `stop()`. Only then does the service read or publish events; `access` is kept current
    /// either way, since settings shows it while the service is stopped.
    @ObservationIgnored private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        refresh()
        // Any store's changes: `EventStore` keeps the app's only one to itself.
        storeChangeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refreshes.schedule(every: Self.refreshInterval, tolerance: .seconds(30)) { [weak self] in self?.refresh() }
    }

    func stop() {
        isRunning = false
        refreshes.stop()
        reload.cancel()
        if let storeChangeObserver { NotificationCenter.default.removeObserver(storeChangeObserver) }
        storeChangeObserver = nil
    }

    /// The next event that hasn't ended yet and isn't all-day.
    func nextTimedEvent(after date: Date) -> CalendarEvent? {
        upcomingEvents.first { !$0.isAllDay && $0.endDate > date }
    }

    /// Asks for access, or opens System Settings if the user already said no.
    func requestAccess() async {
        guard access != .denied else {
            SystemSettingsPane.calendarsPrivacy.open()
            return
        }
        NSApp.activate()
        await store.requestFullAccess()
        // The permission prompt can outlast the service (a stop, or a stop and restart): `refresh()` then only
        // updates `access` unless the service is running again.
        refresh()
    }

    private func refresh() {
        let access = Self.currentAccess
        if access != self.access { self.access = access }
        guard isRunning else { return }
        guard access == .granted else {
            reload.cancel()
            if !upcomingEvents.isEmpty { upcomingEvents = [] }
            return
        }
        reload.request { [weak self] in await self?.reloadNow() }
    }

    private func reloadNow() async {
        let events = await store.upcomingEvents(from: .now)
        guard !Task.isCancelled, isRunning else { return }
        // Only a real change redraws the widgets: the store notifies for every edit, in any calendar.
        if events != upcomingEvents { upcomingEvents = events }
    }

    private static var currentAccess: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}

/// Owns the app's `EKEventStore` and runs every call to it one at a time, off the main actor.
///
/// EventKit doesn't say an event store is safe to use from several threads at once, and reads can overlap: a
/// cancelled read keeps running in `events(matching:)` while the next one starts. Only `CalendarEvent` copies leave.
private actor EventStore {
    private let store = EKEventStore()

    func requestFullAccess() async {
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            Log.calendar.error("Calendar access request failed: \(error)")
        }
    }

    /// Sorted by start date, up to `CalendarService.maximumEvents`, through the end of tomorrow.
    func upcomingEvents(from now: Date) -> [CalendarEvent] {
        let calendar = Calendar.autoupdatingCurrent
        guard let end = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(CalendarService.maximumEvents)
            .map(CalendarEvent.init)
    }
}
