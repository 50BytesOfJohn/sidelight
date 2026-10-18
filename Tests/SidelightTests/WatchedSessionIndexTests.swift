import Foundation
import Testing

@testable import Sidelight
@testable import SidelightCore

/// The same service reads Cursor's chats and OpenCode's sessions; these drive it with reads the test answers.
struct WatchedSessionIndexTests {
    typealias Index = WatchedSessionIndex<String>
    typealias Answer = Result<[String], SessionIndexFailure>

    let answers = Answers<Answer>()
    let index: Index

    init() {
        let directory = URL.temporaryDirectory.appending(path: "sidelight-index-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let answers = answers
        index = Index(name: "Test", database: directory.appending(path: "state.db"), log: Log.app) { _, _ in
            await answers.next()
        }
    }

    @Test func `publishes what it reads`() async {
        index.start()
        await answers.answer(.success(["a", "b"]))
        #expect(await eventually { index.hasLoaded })
        #expect(index.sessions == ["a", "b"])
        #expect(index.availability == .found)
        index.stop()
    }

    @Test func `start is idempotent`() async {
        index.start()
        index.start()
        await answers.answer(.success(["a"]))
        #expect(await eventually { index.hasLoaded })
        await settle()
        #expect(answers.callCount == 1)
        index.stop()
    }

    @Test func `stopping before the first read finishes publishes nothing`() async {
        index.start()
        await eventually { answers.pendingCount == 1 }
        index.stop()
        await answers.answer(.success(["late"]))
        await settle()
        #expect(!index.hasLoaded)
        #expect(index.sessions.isEmpty)
    }

    @Test func `a read from before a restart can't overwrite a newer one`() async {
        index.start()
        await eventually { answers.pendingCount == 1 }
        index.stop()
        index.start()
        await eventually { answers.pendingCount == 2 }
        await answers.answer(.success(["old"]))
        await answers.answer(.success(["new"]))
        #expect(await eventually { index.sessions == ["new"] })
        await settle()
        #expect(index.sessions == ["new"])
        index.stop()
    }

    @Test func `an unreadable database keeps what was read before`() async {
        index.start()
        await answers.answer(.success(["kept"]))
        await eventually { index.hasLoaded }
        index.scheduleReload()
        await answers.answer(.failure(.unreadable))
        #expect(await eventually { index.availability == .unreadable })
        #expect(index.sessions == ["kept"])
        index.scheduleReload()
        await answers.answer(.success(["recovered"]))
        #expect(await eventually { index.availability == .found && index.sessions == ["recovered"] })
        index.stop()
    }

    @Test(arguments: [SessionIndexFailure.noDatabase, .unsupported])
    func `a missing or unsupported database clears the list`(failure: SessionIndexFailure) async {
        index.start()
        await answers.answer(.success(["gone"]))
        await eventually { index.hasLoaded }
        index.scheduleReload()
        await answers.answer(.failure(failure))
        #expect(await eventually { index.sessions.isEmpty })
        #expect(index.availability == (failure == .noDatabase ? .notFound : .unsupported))
        index.stop()
    }

    @Test func `reads off the main thread`() async {
        let index = Index(name: "Test", database: URL(filePath: "/nonexistent/state.db"), log: Log.app) { _, _ in
            .success(pthread_main_np() != 0 ? ["main"] : ["background"])
        }
        index.start()
        #expect(await eventually { index.hasLoaded })
        #expect(index.sessions == ["background"])
        index.stop()
    }

    @Test func `no database file at all reads as unsupported without reading`() async {
        let index = Index(name: "Test", database: nil, log: Log.app) { _, _ in .success(["never"]) }
        index.start()
        #expect(index.hasLoaded)
        #expect(index.availability == .unsupported)
        #expect(index.sessions.isEmpty)
    }

    @Test func `stopped, it ignores reload requests`() async {
        index.start()
        await answers.answer(.success([]))
        await eventually { index.hasLoaded }
        index.stop()
        index.scheduleReload()
        await settle()
        #expect(answers.callCount == 1)
    }
}
