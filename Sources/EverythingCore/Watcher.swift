#if canImport(CoreServices)
import CoreServices
import Foundation

/// Streams folder-level change notifications from FSEvents.
public final class Watcher {
    public struct Event {
        public var path: String
        public var mustScanSubDirs: Bool
        public var rootChanged: Bool
        public var historyDone: Bool
        public var id: UInt64
    }

    public let paths: [String]
    public private(set) var lastEventId: UInt64
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "MacEverything.fsevents")
    private let handler: ([Event]) -> Void

    /// `since` is a saved event id, or nil to start from now.
    public init(paths: [String], since: UInt64?, latency: TimeInterval = 0.3, handler: @escaping ([Event]) -> Void) {
        self.paths = paths
        self.handler = handler
        self.lastEventId = since ?? Watcher.currentEventId
    }

    public static var currentEventId: UInt64 { UInt64(FSEventsGetCurrentEventId()) }

    /// The volume UUID FSEvents ties its history to, for the volume holding `path`.
    public static func volumeUUID(for path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        return (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    public func start(since: UInt64? = nil, latency: TimeInterval = 0.3) -> Bool {
        stop()
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, eventIds in
            guard let info else { return }
            let watcher = Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            var events: [Event] = []
            events.reserveCapacity(count)
            for i in 0..<count {
                let flags = eventFlags[i]
                let event = Event(
                    path: i < paths.count ? paths[i] : "",
                    mustScanSubDirs: flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0,
                    rootChanged: flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0,
                    historyDone: flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0,
                    id: UInt64(eventIds[i]))
                events.append(event)
                if event.id > watcher.lastEventId { watcher.lastEventId = event.id }
            }
            watcher.handler(events)
        }
        let sinceWhen = FSEventStreamEventId(since ?? lastEventId)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray, sinceWhen, latency, flags)
        else { return false }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        return FSEventStreamStart(created)
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
#endif
