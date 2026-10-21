import Foundation
import SidelightCore

/// What a provider said about asking with one account's key, whatever was asked: when it allows the next request,
/// and whether it rejected the key; and when someone's click last sent requests. Forgotten when a key is saved.
///
/// One per account, shared by every kind of request made with its key, so `Retry-After` on one holds them all.
struct AccountPacing<Problem: Equatable> {
    /// What a hold for `Retry-After` reports.
    private let rateLimited: Problem
    /// Whether a problem means the provider won't take the key at all, so asking again with it can't help.
    private let isRejection: (Problem) -> Bool
    /// The provider asked not to be asked again before this.
    private var notBefore: ContinuousClock.Instant?
    /// The provider rejected the key, or what it may read.
    private var rejection: Problem?
    /// When someone's last click sent requests.
    private var lastManualRequest: ContinuousClock.Instant?

    init(rateLimited: Problem, isRejection: @escaping (Problem) -> Bool) {
        self.rateLimited = rateLimited
        self.isRejection = isRejection
    }

    /// How long until someone's next click may send requests, `gap` after their last one did.
    func manualWait(gap: Duration) -> Duration {
        guard let lastManualRequest else { return .zero }
        return max(.zero, lastManualRequest + gap - .now)
    }

    mutating func manualRequestSent() {
        lastManualRequest = .now
    }

    mutating func record(_ problem: Problem, retry: RetryAdvice, at now: Date) {
        if isRejection(problem) { rejection = problem }
        if case .notBefore(let date) = retry {
            let instant = ContinuousClock.now + .seconds(max(0, date.timeIntervalSince(now)))
            notBefore = max(notBefore ?? instant, instant)
        }
    }

    /// Why a request mustn't be sent at `now`, and when one may be; `nil` to go ahead.
    func hold(at now: Date) -> (problem: Problem, retry: RetryAdvice)? {
        if let rejection { return (rejection, .onRequest) }
        guard let notBefore, notBefore > .now else { return nil }
        return (rateLimited, .notBefore(now.addingTimeInterval((notBefore - .now).timeInterval)))
    }
}
