import Foundation
import Synchronization
import Testing

@testable import Sidelight
@testable import SidelightCore

/// A `docker` that answers from a script: what `ps`, `inspect` and `stats` print, and event streams the test feeds
/// and ends.
private nonisolated final class FakeDocker: Sendable {
    nonisolated final class Stream: Sendable {
        let arguments: [String]
        let continuation: AsyncStream<Data>.Continuation
        let isTerminated = Mutex(false)

        init(arguments: [String], continuation: AsyncStream<Data>.Continuation) {
            self.arguments = arguments
            self.continuation = continuation
        }
    }

    private let calls = Mutex<[[String]]>([])
    private let streamList = Mutex<[Stream]>([])
    /// What `ps -aq` answers; a failure prints this on stderr.
    let psFailure = Mutex<String?>(nil)
    /// `ps` takes this long, unless cancelled.
    let psDelay = Mutex<Duration>(.zero)
    /// Each `ps` waits for the test to answer.
    let holdsPS = Mutex(false)
    let psAnswers = Answers<Void>()
    let ids = Mutex(["c1"])

    var transport: DockerService.Transport {
        DockerService.Transport(
            run: { [self] arguments in await run(arguments) },
            stream: { [self] arguments in
                let (lines, continuation) = AsyncStream.makeStream(of: Data.self)
                let stream = Stream(arguments: arguments, continuation: continuation)
                streamList.withLock { $0.append(stream) }
                calls.withLock { $0.append(arguments) }
                return DockerEventStream(
                    lines: lines,
                    terminate: {
                        stream.isTerminated.withLock { $0 = true }
                        continuation.finish()
                    })
            })
    }

    var allCalls: [[String]] { calls.withLock { $0 } }
    var streams: [Stream] { streamList.withLock { $0 } }
    func count(_ command: String) -> Int { allCalls.count { $0.contains(command) } }

    private func run(_ arguments: [String]) async -> ProcessRunner.Result? {
        calls.withLock { $0.append(arguments) }
        if arguments.contains("ps") {
            let delay = psDelay.withLock { $0 }
            // sleeps on purpose: a slow `docker ps`, which is what the test is about.
            if delay > .zero { try? await Task.sleep(for: delay) }
            if holdsPS.withLock({ $0 }) { await psAnswers.next() }
            if let failure = psFailure.withLock({ $0 }) {
                return ProcessRunner.Result(status: 1, output: Data(), error: Data(failure.utf8))
            }
            let output = ids.withLock { $0 }.map { $0 + "\n" }.joined()
            return ProcessRunner.Result(status: 0, output: Data(output.utf8), error: Data())
        }
        if arguments.contains("inspect") {
            let lines = arguments.filter { $0.hasPrefix("c") && $0.count <= 3 }.map { id in
                #"{"id":"\#(id)","name":"/\#(id)","image":"img","state":{"Status":"running"},"labels":{},"ports":{}}"#
            }
            return ProcessRunner.Result(status: 0, output: Data(lines.joined(separator: "\n").utf8), error: Data())
        }
        if arguments.contains("stats") {
            let line = #"{"id":"c1","cpu":"1.5%","mem":"10MiB / 1GiB","memPerc":"1%"}"#
            return ProcessRunner.Result(status: 0, output: Data(line.utf8), error: Data())
        }
        return ProcessRunner.Result(status: 0, output: Data(), error: Data())
    }
}

private let quick = DockerConnection.Timing(
    readDelay: .milliseconds(20), readTimeout: .seconds(5), firstRetryDelay: .milliseconds(40),
    maximumRetryDelay: .milliseconds(400), healthyAfter: .seconds(60), statsInterval: .milliseconds(30))

private let daemonDown =
    "failed to connect to the docker API at unix:///tmp/docker.sock; check if the path is correct and if the daemon "
    + "is running: dial unix /tmp/docker.sock: connect: no such file or directory"

struct DockerServiceTests {
    private func service(
        _ fake: FakeDocker, timing: DockerConnection.Timing = quick, demand: DockerDemand
    )
        -> DockerService
    {
        let service = DockerService(transport: fake.transport, timing: timing)
        service.demand = demand
        return service
    }

    @Test func `starting twice opens one stream and reads once, events first`() async throws {
        let fake = FakeDocker()
        let startedAt = Date.now
        let service = service(fake, demand: DockerDemand(contexts: [.current]))
        service.start()
        service.start()
        let connection = try #require(service.connection(.current))
        #expect(await eventually { connection.status == .connected })
        await settle(.milliseconds(60))
        #expect(fake.streams.count == 1)
        #expect(fake.count("ps") == 1)
        let order = fake.allCalls.filter { $0.contains("events") || $0.contains("ps") }
        #expect(order.first?.contains("events") == true)
        let since = try #require(fake.streams[0].arguments.last.flatMap { TimeInterval($0) })
        #expect(since <= startedAt.timeIntervalSince1970)
        #expect(connection.snapshot?.containers.map(\.name) == ["c1"])
        service.stop()
    }

    @Test func `a burst of events costs at most two reads`() async throws {
        let fake = FakeDocker()
        let service = service(fake, demand: DockerDemand(contexts: [.current]))
        service.start()
        let connection = try #require(service.connection(.current))
        #expect(await eventually { connection.status == .connected })
        await settle()
        let before = fake.count("ps")
        fake.ids.withLock { $0 = ["c1", "c2"] }
        for _ in 0..<10 { fake.streams[0].continuation.yield(Data("start".utf8)) }
        #expect(await eventually { connection.snapshot?.containers.count == 2 })
        await settle(.milliseconds(80))
        #expect(fake.count("ps") - before <= 2)
        service.stop()
    }

    @Test func `Docker going away keeps the snapshot and reconnects once it's back`() async throws {
        let fake = FakeDocker()
        let service = service(fake, demand: DockerDemand(contexts: [.current]))
        service.start()
        let connection = try #require(service.connection(.current))
        #expect(await eventually { connection.status == .connected })
        fake.psFailure.withLock { $0 = daemonDown }
        fake.streams[0].continuation.yield(Data("die".utf8))
        #expect(await eventually { connection.status == .notRunning })
        #expect(connection.snapshot?.containers.count == 1)
        #expect(fake.streams[0].isTerminated.withLock { $0 })
        // It tries again on its own.
        #expect(await eventually { fake.streams.count >= 2 })
        fake.psFailure.withLock { $0 = nil }
        #expect(await eventually { connection.status == .connected })
        service.stop()
    }

    @Test func `the stream ending reconnects, waiting longer each time`() async throws {
        let fake = FakeDocker()
        let service = service(fake, demand: DockerDemand(contexts: [.current]))
        service.start()
        let connection = try #require(service.connection(.current))
        #expect(await eventually { connection.status == .connected })
        fake.streams[0].continuation.finish()
        #expect(await eventually { connection.consecutiveFailures == 1 })
        let first = connection.retryDelay
        #expect(await eventually { fake.streams.count == 2 })
        #expect(await eventually { connection.status == .connected })
        fake.streams[1].continuation.finish()
        #expect(await eventually { connection.consecutiveFailures == 2 })
        #expect(connection.retryDelay > first)
        #expect(await eventually { fake.streams.count == 3 })
        connection.refreshNow()
        #expect(connection.consecutiveFailures == 0)
        service.stop()
    }

    @Test func `nothing is published after stop, and starting again shows the kept snapshot`() async throws {
        let fake = FakeDocker()
        let service = service(fake, demand: DockerDemand(contexts: [.current]))
        service.start()
        let connection = try #require(service.connection(.current))
        #expect(await eventually { connection.status == .connected })
        fake.holdsPS.withLock { $0 = true }
        fake.ids.withLock { $0 = ["c1", "c2", "c3"] }
        fake.streams[0].continuation.yield(Data("start".utf8))
        #expect(await eventually { fake.psAnswers.pendingCount == 1 })
        service.stop()
        await fake.psAnswers.answer(())
        #expect(await eventually { fake.streams[0].isTerminated.withLock { $0 } })
        await settle()
        #expect(connection.snapshot?.containers.count == 1)
        fake.holdsPS.withLock { $0 = false }
        service.start()
        #expect(connection.snapshot?.containers.count == 1)
        #expect(connection.status == .connected)
        #expect(await eventually { connection.snapshot?.containers.count == 3 })
        service.stop()
    }

    @Test func `stats are read only for the details panel's context`() async throws {
        let fake = FakeDocker()
        let service = service(fake, demand: DockerDemand(contexts: [.current, .named("other")], stats: .current))
        service.start()
        let current = try #require(service.connection(.current))
        let other = try #require(service.connection(.named("other")))
        #expect(await eventually { current.stats["c1"]?.cpuPercent == 1.5 })
        #expect(fake.allCalls.filter { $0.contains("stats") }.allSatisfy { !$0.contains("--context") })
        #expect(other.stats.isEmpty)
        service.demand = DockerDemand(contexts: [.current, .named("other")])
        #expect(current.stats.isEmpty)
        let count = fake.count("stats")
        await settle(.milliseconds(100))
        #expect(fake.count("stats") == count)
        service.stop()
    }

    @Test func `one connection per context, and contexts no longer shown stop`() async throws {
        let fake = FakeDocker()
        let service = service(fake, demand: DockerDemand(contexts: [.current, .named("orbstack")]))
        service.start()
        #expect(await eventually { fake.streams.count == 2 })
        let named = try #require(fake.streams.first { $0.arguments.starts(with: ["--context", "orbstack"]) })
        service.demand = DockerDemand(contexts: [.current])
        #expect(named.isTerminated.withLock { $0 })
        #expect(service.connection(.named("orbstack")) != nil)
        service.demand = DockerDemand(contexts: [.current, .named("orbstack")])
        #expect(await eventually { fake.streams.count == 3 })
        service.stop()
        #expect(fake.streams.allSatisfy { $0.isTerminated.withLock { $0 } })
    }

    @Test func `a read that takes too long times out`() async throws {
        let fake = FakeDocker()
        fake.psDelay.withLock { $0 = .seconds(10) }
        var timing = quick
        timing.readTimeout = .milliseconds(50)
        timing.firstRetryDelay = .seconds(10)
        let service = service(fake, timing: timing, demand: DockerDemand(contexts: [.current]))
        service.start()
        let connection = try #require(service.connection(.current))
        #expect(await eventually { connection.status == .problem(.timedOut) })
        service.stop()
    }
}
