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
/// Reading events is synchronous and can take a while with many calendars, so it runs off the main actor, one read
/// at a time; the store's change notifications, which come in bursts while calendars sync, are gathered into one.
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

    func start() {
        guard !refreshes.isRunning else { return }
        refresh()
        storeChangeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store.store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refreshes.schedule(every: Self.refreshInterval, tolerance: .seconds(30)) { [weak self] in self?.refresh() }
    }

    func stop() {
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
        do {
            _ = try await store.store.requestFullAccessToEvents()
        } catch {
            Log.calendar.error("Calendar access request failed: \(error)")
        }
        refresh()
    }

    private func refresh() {
        let access = Self.currentAccess
        if access != self.access { self.access = access }
        guard access == .granted else {
            reload.cancel()
            if !upcomingEvents.isEmpty { upcomingEvents = [] }
            return
        }
        reload.request { [weak self] in await self?.reloadNow() }
    }

    private func reloadNow() async {
        let events = await Self.upcomingEvents(in: store, now: .now)
        guard !Task.isCancelled else { return }
        // Only a real change redraws the widgets: the store notifies for every edit, in any calendar.
        if events != upcomingEvents { upcomingEvents = events }
    }

    @concurrent
    private static func upcomingEvents(in store: EventStore, now: Date) async -> [CalendarEvent] {
        let calendar = Calendar.autoupdatingCurrent
        guard let end = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) else { return [] }
        let predicate = store.store.predicateForEvents(withStart: now, end: end, calendars: nil)
        return store.store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(maximumEvents)
            .map(CalendarEvent.init)
    }

    private static var currentAccess: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}

/// The event store, handed to the reads off the main actor. EventKit's guide has `events(matching:)` run on another
/// thread; `CalendarService` runs one read at a time.
nonisolated private final class EventStore: @unchecked Sendable {
    let store = EKEventStore()
}
