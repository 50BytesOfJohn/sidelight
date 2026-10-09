import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Menu-bar app: no Dock icon until a window is open (see `WindowCoordinator`).
application.setActivationPolicy(.accessory)

// Quit cleanly on SIGTERM (`killall Sidelight`) and SIGINT (Ctrl-C in `make dev`), so helper processes are
// stopped and settings flushed. Helpers run in their own process groups, so they don't get the signal themselves.
let terminationSources = [SIGTERM, SIGINT].map { signalNumber in
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated { NSApp.terminate(nil) }
    }
    source.resume()
    return source
}

application.run()
