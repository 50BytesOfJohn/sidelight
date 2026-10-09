import CoreServices
import Foundation
import Synchronization

/// Calls `handler` whenever the file at `url` changes: rewritten in place, replaced by an atomic save,
/// deleted or created.
///
/// A vnode watch on the file alone misses atomic saves (they swap in a new inode), and a watch on the directory
/// alone misses in-place writes, so this watches both and re-attaches to the file whenever the directory changes.
public final class FileWatcher: Sendable {
    private let url: URL
    private let queue: DispatchQueue
    private let handler: @Sendable () -> Void
    private let directorySource: any DispatchSourceFileSystemObject
    private let fileSource = Mutex<(any DispatchSourceFileSystemObject)?>(nil)

    public init?(file url: URL, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        let directoryDescriptor = open(url.deletingLastPathComponent().path(percentEncoded: false), O_EVTONLY)
        guard directoryDescriptor >= 0 else { return nil }
        self.url = url
        self.queue = queue
        self.handler = handler
        directorySource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        directorySource.setCancelHandler { close(directoryDescriptor) }
        directorySource.setEventHandler { [weak self] in
            self?.attachToFile()
            handler()
        }
        attachToFile()
        directorySource.activate()
    }

    deinit {
        directorySource.cancel()
        fileSource.withLock { $0?.cancel() }
    }

    private func attachToFile() {
        let source: (any DispatchSourceFileSystemObject)?
        let descriptor = open(url.path(percentEncoded: false), O_EVTONLY)
        if descriptor >= 0 {
            let newSource = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .delete, .rename],
                queue: queue
            )
            newSource.setCancelHandler { close(descriptor) }
            newSource.setEventHandler(handler: handler)
            newSource.activate()
            source = newSource
        } else {
            source = nil
        }
        fileSource.withLock { current in
            current?.cancel()
            current = source
        }
    }
}

/// Recursive file-level change notifications for a directory tree (FSEvents), coalesced by `latency`.
public final class FileEventStream: Sendable {
    private final class Callback: Sendable {
        let handler: @Sendable () -> Void
        init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
    }

    private nonisolated(unsafe) let stream: FSEventStreamRef

    public init?(
        directory url: URL,
        latency: TimeInterval,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(Callback(handler)).toOpaque(),
            retain: nil,
            release: { info in
                if let info { Unmanaged<Callback>.fromOpaque(info).release() }
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().handler()
        }
        guard
            let stream = FSEventStreamCreate(
                nil,
                callback,
                &context,
                [url.path(percentEncoded: false)] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
            )
        else {
            Unmanaged<Callback>.fromOpaque(context.info!).release()
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
