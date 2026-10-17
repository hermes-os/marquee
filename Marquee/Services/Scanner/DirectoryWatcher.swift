import Foundation
import CoreServices

// MARK: - Directory Watcher

/// Thin wrapper around FSEvents that fires a debounced callback whenever any
/// watched directory tree changes on disk. Used to auto-rescan the library
/// when files are added/moved/removed without requiring a manual rescan.
final class DirectoryWatcher {

    private var stream: FSEventStreamRef?
    private var paths: [String] = []
    private let queue = DispatchQueue(label: "com.marquee.directorywatcher", qos: .utility)
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceLock = NSLock()
    private let debounceInterval: TimeInterval = 2.0

    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    // MARK: - Public API

    func watch(paths: [String]) {
        stop()

        let filtered = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !filtered.isEmpty else { return }

        self.paths = filtered

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagIgnoreSelf |
            kFSEventStreamCreateFlagUseCFTypes
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            DirectoryWatcher.callback,
            &context,
            filtered as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)

        self.stream = stream
    }

    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        debounceLock.lock()
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        debounceLock.unlock()
        paths = []
    }

    // MARK: - FSEvents Callback

    private static let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
        guard let info = info else { return }
        let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()

        let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
        let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)

        let relevant = zip(paths, flags).contains { _, flag in
            let ignoredFlags = UInt32(
                kFSEventStreamEventFlagHistoryDone |
                kFSEventStreamEventFlagMount |
                kFSEventStreamEventFlagUnmount
            )
            return (flag & ignoredFlags) == 0
        }

        guard relevant else { return }
        watcher.scheduleDebouncedChange()
    }

    private func scheduleDebouncedChange() {
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async { self.onChange() }
        }
        debounceLock.lock()
        debounceWorkItem?.cancel()
        debounceWorkItem = work
        debounceLock.unlock()
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
