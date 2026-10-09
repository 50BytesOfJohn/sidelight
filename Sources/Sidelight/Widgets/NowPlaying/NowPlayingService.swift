import AppKit
import Observation
import SidelightCore
import os

/// What's playing system-wide, streamed from the `media-control` CLI
/// (`brew install ungive/media-control/media-control`).
@Observable
final class NowPlayingService {
    static let toolName = "media-control"

    enum Availability: Equatable {
        case available
        case toolMissing
        /// The tool exited or couldn't be started.
        case failed
    }

    private(set) var availability: Availability = .available
    private(set) var state = NowPlayingState()
    private(set) var artwork: NSImage?

    @ObservationIgnored private var process: ChildProcess?
    @ObservationIgnored private var readingTask: Task<Void, Never>?

    var title: String { state.title ?? "" }
    var artist: String { state.artist ?? "" }

    func start() {
        guard process == nil else { return }
        guard let executable = ExecutableLocator.find(Self.toolName) else {
            availability = .toolMissing
            return
        }
        let process: ChildProcess
        do {
            process = try ChildProcess(executable: executable, arguments: ["stream"])
        } catch {
            Log.nowPlaying.error("Can't start \(Self.toolName, privacy: .public): \(error)")
            availability = .failed
            return
        }
        self.process = process
        availability = .available
        readingTask = Task { [weak self] in
            for await line in process.lines {
                guard let update = await Self.decode(line) else { continue }
                self?.apply(update)
            }
            self?.processDidExit(process)
        }
    }

    /// Stops the tool; `media-control` forks a second Perl process, which the process-group kill also ends.
    func stop() {
        readingTask?.cancel()
        readingTask = nil
        process?.terminate()
        process = nil
    }

    /// Decodes off the main actor: lines carry base64 artwork that can be hundreds of kilobytes.
    @concurrent
    private static func decode(_ line: Data) async -> NowPlayingUpdate? {
        NowPlayingUpdate.decode(line)
    }

    private func apply(_ update: NowPlayingUpdate) {
        let previousArtwork = state.artworkData
        state.apply(update)
        if state.artworkData != previousArtwork {
            artwork = state.artworkData.flatMap(NSImage.init(data:))
        }
    }

    private func processDidExit(_ exited: ChildProcess) {
        guard process === exited else { return }
        Log.nowPlaying.notice("\(Self.toolName, privacy: .public) exited")
        process = nil
        readingTask = nil
        availability = .failed
    }
}
