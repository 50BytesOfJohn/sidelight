import AppKit
import EventKit
import Observation
import SidelightCore
import SwiftUI
import os

/// A calendar event, copied out of EventKit so views never hold on to `EKEvent`s.
struct CalendarEvent: Identifiable, Hashable {
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
@Observable
final class CalendarService {
    enum Access {
        case notDetermined
        case granted
        /// Denied, restricted or write-only; only System Settings can change it.
        case denied
    }

    static let maximumEvents = 10
    static let refreshInterval: Duration = .seconds(300)

    private(set) var access: Access = CalendarService.currentAccess
    /// Sorted by start date.
    private(set) var upcomingEvents: [CalendarEvent] = []

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var storeChangeObserver: (any NSObjectProtocol)?

    func start() {
        guard refreshTask == nil else { return }
        refresh()
        storeChangeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refreshTask = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: Self.refreshInterval, tolerance: .seconds(30)) } catch { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
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
            _ = try await store.requestFullAccessToEvents()
        } catch {
            Log.calendar.error("Calendar access request failed: \(error)")
        }
        refresh()
    }

    private func refresh() {
        access = Self.currentAccess
        guard access == .granted else {
            upcomingEvents = []
            return
        }
        let now = Date.now
        let calendar = Calendar.autoupdatingCurrent
        guard let end = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) else { return }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        upcomingEvents = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(Self.maximumEvents)
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
