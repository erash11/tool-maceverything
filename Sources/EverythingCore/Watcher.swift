#if canImport(CoreServices)
import CoreServices
import Foundation

/// Streams folder-level change notifications from FSEvents for one root.
///
/// Roots on other volumes (under /Volumes) use a per-device stream: their event ids live on
/// that disk, so a saved cursor stays valid when the disk is used on another Mac. Apple's
/// FSEvents guide recommends per-device streams for exactly this case.
public final class Watcher {
    public struct Event {
        public var path: String
        public var mustScanSubDirs: Bool
        public var rootChanged: Bool
        public var historyDone: Bool
        /// The kernel or daemon dropped events: everything watched must be rescanned.
        public var dropped: Bool = false
        public var id: UInt64
    }

    public let root: String
    /// Set for per-device streams: the device and its mount point.
    let device: dev_t?
    let mountPoint: String?
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "MacEverything.fsevents")
    private let handler: ([Event]) -> Void

    public init(root: String, handler: @escaping ([Event]) -> Void) {
        self.root = root
        self.handler = handler
        if let (dev, mount) = Watcher.deviceAndMount(for: root) {
            device = dev
            mountPoint = mount
        } else {
            device = nil
            mountPoint = nil
        }
    }

    public var isPerDevice: Bool { device != nil }

    /// The newest event id in the id space this root's stream uses.
    public static func currentEventId(for root: String) -> UInt64 {
        if let (dev, _) = deviceAndMount(for: root) {
            return UInt64(FSEventsGetLastEventIdForDeviceBeforeTime(dev, CFAbsoluteTimeGetCurrent()))
        }
        return UInt64(FSEventsGetCurrentEventId())
    }

    /// The device and mount point for roots on non-boot volumes, else nil.
    static func deviceAndMount(for root: String) -> (dev_t, String)? {
        guard root.hasPrefix("/Volumes/") else { return nil }
        var st = stat()
        guard stat(root, &st) == 0 else { return nil }
        var fs = statfs()
        guard statfs(root, &fs) == 0 else { return nil }
        let mount = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return (st.st_dev, mount)
    }

    /// The volume UUID FSEvents ties its history to, for the volume holding `path`.
    public static func volumeUUID(for path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        return (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    /// Per-device streams report paths relative to the device root; make them absolute.
    func absolute(_ path: String) -> String {
        guard let mount = mountPoint, !path.hasPrefix(mount + "/"), path != mount else { return path }
        let rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return rel.isEmpty ? mount : mount + "/" + rel
    }

    /// `since` is a saved event id, or nil to start from now.
    public func start(since: UInt64?, latency: TimeInterval = 0.3) -> Bool {
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
                events.append(Event(
                    path: i < paths.count ? watcher.absolute(paths[i]) : "",
                    mustScanSubDirs: flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0,
                    rootChanged: flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0,
                    historyDone: flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0,
                    dropped: flags & FSEventStreamEventFlags(
                        kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0,
                    id: UInt64(eventIds[i])))
            }
            watcher.handler(events)
        }
        let sinceWhen = FSEventStreamEventId(since ?? Watcher.currentEventId(for: root))
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        let created: FSEventStreamRef?
        if let dev = device, let mount = mountPoint {
            // Paths are relative to the device root; "" watches the whole volume.
            var rel = String(root.dropFirst(mount.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            created = FSEventStreamCreateRelativeToDevice(
                kCFAllocatorDefault, callback, &context, dev, [rel] as CFArray, sinceWhen, latency, flags)
        } else {
            created = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, [root] as CFArray, sinceWhen, latency, flags)
        }
        guard let s = created else { return false }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        if FSEventStreamStart(s) { return true }
        stop()
        return false
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
