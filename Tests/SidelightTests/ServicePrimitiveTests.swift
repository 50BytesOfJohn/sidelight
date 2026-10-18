import Foundation
import Testing

@testable import Sidelight

struct CoalescedReloadTests {
    @Test func `requests during a read make one more read`() async {
        let reload = CoalescedReload()
        let answers = Answers<Void>()
        var reads = 0
        let read = {
            reads += 1
            await answers.next()
        }
        reload.request(read)
        await eventually { answers.pendingCount == 1 }
        reload.request(read)
        reload.request(read)
        reload.request(read)
        await answers.answer(())
        await answers.answer(())
        #expect(await eventually { !reload.isActive })
        #expect(reads == 2)
    }

    @Test func `a cancelled read sees it, and its replacement still runs`() async {
        let reload = CoalescedReload()
        let answers = Answers<Void>()
        var published: [String] = []
        func read(_ name: String) -> () async -> Void {
            {
                await answers.next()
                guard !Task.isCancelled else { return }
                published.append(name)
            }
        }
        reload.request(read("old"))
        await eventually { answers.pendingCount == 1 }
        reload.cancel()
        reload.request(read("new"))
        await eventually { answers.pendingCount == 2 }
        // The old read finishes after its replacement started: it publishes nothing and leaves the new one running.
        await answers.answer(())
        await settle()
        #expect(reload.isActive)
        await answers.answer(())
        #expect(await eventually { !reload.isActive })
        #expect(published == ["new"])
    }

    @Test func `cancelling drops a waiting request`() async {
        let reload = CoalescedReload()
        var reads = 0
        reload.request(after: .milliseconds(50)) { reads += 1 }
        reload.cancel()
        await settle(.milliseconds(100))
        #expect(reads == 0)
        #expect(!reload.isActive)
    }
}

struct RepeatingTaskTests {
    @Test func `runs until stopped`() async {
        let repeating = RepeatingTask()
        var runs = 0
        repeating.schedule(every: .milliseconds(5), tolerance: .zero) { runs += 1 }
        #expect(await eventually { runs >= 2 })
        repeating.stop()
        let stoppedAt = runs
        await settle()
        #expect(runs == stoppedAt)
        #expect(!repeating.isRunning)
    }

    @Test func `the same interval again changes nothing, and nil stops`() async {
        let repeating = RepeatingTask()
        var runs = 0
        repeating.schedule(every: .seconds(60)) { runs += 1 }
        repeating.schedule(every: .seconds(60)) { runs += 100 }
        #expect(repeating.interval == .seconds(60))
        repeating.schedule(every: nil) { runs += 1 }
        #expect(!repeating.isRunning)
        #expect(repeating.interval == nil)
        #expect(runs == 0)
    }
}

struct FetchScheduleTests {
    @Test func `fetches right away the first time, then not again on a restart`() async {
        let schedule = FetchSchedule(minimumManualGap: .seconds(30), tolerance: .zero)
        schedule.interval = .seconds(60 * 60)
        var fetches = 0
        let fetch = { () async -> FetchSchedule.Outcome? in
            fetches += 1
            return .succeeded
        }
        schedule.start(fetch)
        #expect(await eventually { fetches == 1 && !schedule.isFetching })
        #expect(schedule.lastAttempt != nil)
        schedule.stop()
        schedule.start(fetch)
        await settle()
        #expect(fetches == 1)
        // Too soon after the last fetch for a manual one, too.
        schedule.refreshNow()
        await settle()
        #expect(fetches == 1)
    }

    @Test func `failures in a row back off, and a success resets that`() async {
        let schedule = FetchSchedule(maximumRetryDelay: .seconds(600), minimumManualGap: .zero, tolerance: .zero)
        schedule.interval = .seconds(60)
        let answers = Answers<FetchSchedule.Outcome?>()
        schedule.start { await answers.next() }
        await answers.answer(.failed)
        #expect(await eventually { schedule.consecutiveFailures == 1 })
        #expect(schedule.delayAfterLastAttempt == .seconds(120))
        schedule.refreshNow()
        await answers.answer(.failed)
        #expect(await eventually { schedule.consecutiveFailures == 2 })
        #expect(schedule.delayAfterLastAttempt == .seconds(240))
        schedule.refreshNow()
        await answers.answer(.succeeded)
        #expect(await eventually { schedule.consecutiveFailures == 0 })
        #expect(schedule.delayAfterLastAttempt == .seconds(60))
        schedule.stop()
    }

    @Test func `a fetch cancelled partway counts as no attempt`() async {
        let schedule = FetchSchedule(minimumManualGap: .zero, tolerance: .zero)
        schedule.interval = .seconds(60)
        let answers = Answers<FetchSchedule.Outcome?>()
        schedule.start { await answers.next() }
        await eventually { answers.pendingCount == 1 }
        #expect(schedule.isFetching)
        schedule.stop()
        #expect(!schedule.isFetching)
        await answers.answer(.failed)
        await settle()
        #expect(schedule.lastAttempt == nil)
        #expect(schedule.consecutiveFailures == 0)
    }

    @Test func `turning fetching off forgets past attempts`() {
        let schedule = FetchSchedule(minimumManualGap: .zero, tolerance: .zero)
        schedule.interval = .seconds(60)
        schedule.interval = nil
        #expect(schedule.lastAttempt == nil)
        #expect(schedule.delayAfterLastAttempt == nil)
    }
}

struct DelayedTaskTests {
    @Test func `scheduling again replaces the run still waiting`() async {
        let delayed = DelayedTask()
        var runs: [String] = []
        delayed.schedule(after: .milliseconds(20)) { runs.append("first") }
        delayed.schedule(after: .milliseconds(20)) { runs.append("second") }
        #expect(delayed.isPending)
        #expect(await eventually { !delayed.isPending })
        #expect(runs == ["second"])
    }

    @Test func `cancelling drops the run`() async {
        let delayed = DelayedTask()
        var runs = 0
        delayed.schedule(after: .milliseconds(20)) { runs += 1 }
        delayed.cancel()
        #expect(!delayed.isPending)
        await settle()
        #expect(runs == 0)
    }

    @Test func `the action can schedule the next run`() async {
        let delayed = DelayedTask()
        var runs = 0
        func run() {
            runs += 1
            if runs < 3 { delayed.schedule(after: .milliseconds(5), run) }
        }
        delayed.schedule(after: .milliseconds(5), run)
        #expect(await eventually { runs == 3 && !delayed.isPending })
    }
}

struct PacedTaskTests {
    @Test func `each run sets the wait before the next, and nil ends it`() async {
        let paced = PacedTask()
        var runs = 0
        paced.start(
            after: .zero, tolerance: { _ in .zero },
            run: {
                runs += 1
                return runs < 3 ? .milliseconds(5) : nil
            })
        #expect(paced.isRunning)
        #expect(await eventually { !paced.isRunning })
        #expect(runs == 3)
    }

    @Test func `a run cancelled partway ends the loop and leaves its replacement running`() async {
        let paced = PacedTask()
        let answers = Answers<Void>()
        var published: [String] = []
        func run(_ name: String) -> () async -> Duration? {
            {
                await answers.next()
                guard !Task.isCancelled else { return .zero }
                published.append(name)
                return .seconds(60)
            }
        }
        paced.start(after: .zero, run: run("old"))
        await eventually { answers.pendingCount == 1 }
        paced.start(after: .zero, run: run("new"))
        await eventually { answers.pendingCount == 2 }
        await answers.answer(())
        await settle()
        #expect(paced.isRunning)
        await answers.answer(())
        #expect(await eventually { published == ["new"] })
        #expect(answers.callCount == 2)
        paced.stop()
        #expect(!paced.isRunning)
    }
}
