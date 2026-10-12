import Foundation
import Observation
import SidelightCore

/// When to fetch from a provider on a timer: every ``interval``, backing off after failures in a row, and never
/// sooner than that after the last fetch. Stopping and starting again (hiding and showing a widget, opening the
/// Widgets window) picks up where it left off rather than asking again right away.
@Observable
final class FetchSchedule {
    enum Outcome {
        case succeeded
        case failed
    }

    /// After failures in a row, the wait doubles up to this.
    let maximumRetryDelay: Duration
    /// "Refresh now" waits at least this long after the last fetch.
    let minimumManualGap: Duration
    let tolerance: Duration

    /// How often to fetch; `nil` not to. Changing it starts over at the new interval.
    var interval: Duration? {
        didSet {
            guard interval != oldValue else { return }
            if interval == nil { reset() }
            if isRunning { restart() }
        }
    }

    /// Fetching right now.
    private(set) var isFetching = false
    /// When the last fetch finished, successful or not.
    private(set) var lastAttempt: Date?
    @ObservationIgnored private(set) var consecutiveFailures = 0

    @ObservationIgnored private var fetch: (() async -> Outcome?)?
    @ObservationIgnored private var task: Task<Void, Never>?
    private var isRunning: Bool { fetch != nil }

    init(maximumRetryDelay: Duration = .seconds(60 * 60), minimumManualGap: Duration, tolerance: Duration) {
        self.maximumRetryDelay = maximumRetryDelay
        self.minimumManualGap = minimumManualGap
        self.tolerance = tolerance
    }

    deinit {
        task?.cancel()
    }

    /// Fetches with `fetch` whenever one is due, until ``stop()``. `fetch` returns `nil` when it was cancelled
    /// partway, which counts as no attempt at all.
    func start(_ fetch: @escaping () async -> Outcome?) {
        guard !isRunning else { return }
        self.fetch = fetch
        restart()
    }

    func stop() {
        fetch = nil
        cancelTask()
    }

    /// Fetches now, then carries on at the interval. Ignored during a fetch and right after one.
    func refreshNow() {
        guard isRunning, !isFetching else { return }
        if let lastAttempt, Date.now.timeIntervalSince(lastAttempt) < minimumManualGap.timeInterval { return }
        restart(immediately: true)
    }

    /// Forgets past fetches, so the next one is due right away.
    func reset() {
        lastAttempt = nil
        consecutiveFailures = 0
    }

    /// The wait after the last fetch, given the failures since the last success.
    var delayAfterLastAttempt: Duration? {
        interval.map {
            UsageRefresh.retryDelay(
                interval: $0, consecutiveFailures: consecutiveFailures, maximum: maximumRetryDelay)
        }
    }

    private func restart(immediately: Bool = false) {
        cancelTask()
        guard let fetch, let delay = delayAfterLastAttempt else { return }
        var wait = immediately ? .zero : lastAttempt.map { delay - .seconds(Date.now.timeIntervalSince($0)) } ?? .zero
        task = Task { [weak self] in
            while true {
                if wait > .zero {
                    do { try await Task.sleep(for: wait, tolerance: self?.tolerance ?? .zero) } catch { return }
                }
                guard let self, !Task.isCancelled else { return }
                isFetching = true
                let outcome = await fetch()
                guard !Task.isCancelled else { return }
                isFetching = false
                if let outcome { record(outcome) }
                guard let next = delayAfterLastAttempt else { return }
                wait = next
            }
        }
    }

    private func record(_ outcome: Outcome) {
        lastAttempt = .now
        switch outcome {
        case .succeeded: consecutiveFailures = 0
        case .failed: consecutiveFailures += 1
        }
    }

    private func cancelTask() {
        task?.cancel()
        task = nil
        isFetching = false
    }
}
