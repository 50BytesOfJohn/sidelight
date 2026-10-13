import Foundation
import Observation
import SidelightCore

/// How often a ``RemoteResource`` fetches while something needs it.
enum RefreshPolicy: Equatable {
    /// Once when there's nothing to show yet, then only when someone asks.
    case manual
    /// Every so often.
    case every(Duration)
    /// Once each UTC day, `delay` after midnight UTC: for data counted in UTC days, which only changes then.
    case dailyUTC(delay: Duration)

    /// What a widget's `cadence` asks for.
    init(_ cadence: RefreshCadence) {
        switch cadence {
        case .manual: self = .manual
        case .minutes(let minutes): self = .every(.seconds(minutes * 60))
        }
    }
}

/// What one fetch of a ``RemoteResource`` came back with.
enum FetchResult<Value, Problem> {
    /// The value, and when the answer came, if the fetch knows: what the value covers is counted from then, so
    /// a day boundary passing while the result is handed over can't shift it. Otherwise it's when the result arrived.
    case success(Value, at: Date? = nil)
    case failure(Problem, retry: RetryAdvice)

    init(_ result: Result<Value, Problem>, retry: RetryAdvice, at date: Date? = nil) where Problem: Error {
        switch result {
        case .success(let value): self = .success(value, at: date)
        case .failure(let problem): self = .failure(problem, retry: retry)
        }
    }
}

/// Something fetched from a provider while something on screen needs it: the last value, kept through failures and
/// while nothing needs it, and the timing that decides when to fetch again.
///
/// - Given a ``policy``, it fetches right away when there's nothing yet or a fetch is due, and otherwise when one
///   is. Without one it stops, cancelling a fetch under way. Starting again picks the schedule up where it was:
///   one fetch if it's due by then, never one for each interval missed.
/// - After failures in a row it waits longer each time, at least as long as the provider asks (`Retry-After`), and
///   not at all on its own when only a change can help (a rejected credential, a rejected request).
/// - ``refreshNow()`` fetches right away, but never within ``manualGap`` of the last fetch, nor before the provider
///   allows.
///
/// The fetch must check `Task.isCancelled` after each `await` and return `nil` once it's set, or when it's been
/// superseded (a credential changed meanwhile): that counts as no fetch at all.
@Observable
final class RemoteResource<Value, Problem: Equatable> {
    /// The last value fetched.
    private(set) var value: Value?
    /// When ``value`` was fetched.
    private(set) var fetchedAt: Date?
    /// Why the last fetch failed; `nil` after a success.
    private(set) var problem: Problem?
    /// A fetch is under way: the only time a spinner shows.
    private(set) var isFetching = false

    /// How often to fetch; `nil` while nothing needs it.
    var policy: RefreshPolicy? {
        didSet {
            guard policy != oldValue else { return }
            if policy == nil {
                stopFetching()
            } else if !isFetching {
                // A fetch under way finishes first, then follows the new policy.
                reschedule()
            }
        }
    }

    /// Fetches the value. Set once, before the first ``policy``.
    @ObservationIgnored var fetch: () async -> FetchResult<Value, Problem>? = { nil }

    /// "Refresh now" waits at least this long after the last fetch.
    let manualGap: Duration
    /// The first wait after a failure, doubling with each failure in a row, up to ``maximumRetryDelay``.
    let firstRetryDelay: Duration
    let maximumRetryDelay: Duration

    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let task = PacedTask()
    @ObservationIgnored private var lastAttempt: ContinuousClock.Instant?
    @ObservationIgnored private var lastSuccess: ContinuousClock.Instant?
    @ObservationIgnored private var consecutiveFailures = 0
    /// The provider asked not to be asked again before this.
    @ObservationIgnored private var notBefore: ContinuousClock.Instant?
    /// The last failure can't be helped by trying again on its own.
    @ObservationIgnored private var waitsForRequest = false

    /// - Parameter now: The wall clock, for ``fetchedAt`` and UTC days. Waits use the continuous clock, which
    ///   keeps counting while the Mac sleeps.
    init(
        manualGap: Duration = .seconds(15), firstRetryDelay: Duration = .seconds(120),
        maximumRetryDelay: Duration = .seconds(60 * 60), now: @escaping () -> Date = { .now }
    ) {
        self.manualGap = manualGap
        self.firstRetryDelay = firstRetryDelay
        self.maximumRetryDelay = maximumRetryDelay
        self.now = now
    }

    /// Fetches as soon as allowed: right away, or once ``manualGap`` has passed since the last fetch, or once the
    /// provider allows. Ignored during a fetch, and while nothing needs the resource.
    func refreshNow() {
        guard let delay = refreshDelay else { return }
        start(after: delay)
    }

    /// How long ``refreshNow()`` would wait before fetching: `.zero` to fetch right away, `nil` when it would do
    /// nothing (during a fetch, and while nothing needs the resource).
    var refreshDelay: Duration? {
        guard policy != nil, !isFetching else { return nil }
        let instant = ContinuousClock.now
        var earliest = lastAttempt.map { $0 + manualGap } ?? instant
        if let notBefore, notBefore > earliest { earliest = notBefore }
        return max(.zero, earliest - instant)
    }

    /// Forgets the value and every past fetch, as for a different account: what was fetched no longer applies. A
    /// resource still needed fetches again right away.
    func reset() {
        stopFetching()
        value = nil
        fetchedAt = nil
        problem = nil
        lastAttempt = nil
        lastSuccess = nil
        consecutiveFailures = 0
        notBefore = nil
        waitsForRequest = false
        if policy != nil { reschedule() }
    }

    // MARK: Scheduling

    private func stopFetching() {
        task.stop()
        isFetching = false
    }

    private func reschedule() {
        stopFetching()
        guard let delay = delayUntilDue() else { return }
        start(after: delay)
    }

    private func start(after delay: Duration) {
        stopFetching()
        task.start(
            after: delay, tolerance: { min($0 / 10, .seconds(30)) },
            run: { [weak self] in
                guard let self else { return nil }
                isFetching = true
                let result = await fetch()
                // Stopped or restarted meanwhile: whoever did owns `isFetching` now.
                guard !Task.isCancelled else { return nil }
                isFetching = false
                if let result { record(result) }
                return delayUntilDue()
            })
    }

    private func record(_ result: FetchResult<Value, Problem>) {
        let instant = ContinuousClock.now
        lastAttempt = instant
        switch result {
        case .success(let value, let date):
            self.value = value
            fetchedAt = date ?? now()
            problem = nil
            lastSuccess = instant
            consecutiveFailures = 0
            notBefore = nil
            waitsForRequest = false
        case .failure(let problem, let retry):
            self.problem = problem
            consecutiveFailures += 1
            switch retry {
            case .backoff:
                waitsForRequest = false
            case .notBefore(let date):
                waitsForRequest = false
                notBefore = instant + .seconds(max(0, date.timeIntervalSince(now())))
            case .onRequest:
                waitsForRequest = true
            }
        }
    }

    /// How long until the next fetch is due; `nil` when none is due on its own.
    private func delayUntilDue() -> Duration? {
        guard let policy else { return nil }
        let instant = ContinuousClock.now
        var due: ContinuousClock.Instant
        if let lastAttempt, consecutiveFailures > 0 {
            // A manual resource tried once on its own; after that, only a request tries again.
            if waitsForRequest || policy == .manual { return nil }
            due = lastAttempt + retryDelay()
        } else if let lastSuccess {
            switch policy {
            case .manual:
                return nil
            case .every(let interval):
                due = lastSuccess + interval
            case .dailyUTC(let delay):
                // The moment itself, then how far off it is: one already past is due now, not `delay` from now.
                let wallClock = now()
                let target = UTCDay(fetchedAt ?? wallClock).adding(days: 1).start.addingTimeInterval(delay.timeInterval)
                due = instant + .seconds(max(0, target.timeIntervalSince(wallClock)))
            }
        } else {
            // Nothing fetched yet.
            due = instant
        }
        if let notBefore, notBefore > due { due = notBefore }
        return max(.zero, due - instant)
    }

    private func retryDelay() -> Duration {
        UsageRefresh.retryDelay(
            interval: firstRetryDelay, consecutiveFailures: consecutiveFailures, maximum: maximumRetryDelay)
    }
}
