#if canImport(CoreServices)
import Foundation
import Darwin

/// User settings, read from config.json next to the index. Every field is optional.
public struct ServiceConfig: Codable {
    public var roots: [String]?
    public var exclusions: [String]?
    public var includeExternalVolumes: Bool?

    public init(roots: [String]? = nil, exclusions: [String]? = nil, includeExternalVolumes: Bool? = nil) {
        self.roots = roots
        self.exclusions = exclusions
        self.includeExternalVolumes = includeExternalVolumes
    }

    public static var defaultURL: URL { FileIndex.defaultDirectory.appendingPathComponent("config.json") }

    public static func load(from url: URL = defaultURL) -> ServiceConfig {
        guard let data = try? Data(contentsOf: url) else { return ServiceConfig() }
        return (try? JSONDecoder().decode(ServiceConfig.self, from: data)) ?? ServiceConfig()
    }
}

/// The daemon's engine: owns the index, keeps it current, answers requests.
public final class IndexService {
    public let index = SharedIndex()
    public let roots: [String]
    public let indexURL: URL
    public private(set) var scanner: Scanner
    /// Guards the status fields below, which are read by request handlers on other threads.
    private let stateLock = NSLock()
    private var _scanning = false
    private var _ready = false
    private var _lastScanSeconds: Double?
    private var _unwatchedRoots: [String] = []

    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    public var scanning: Bool { locked { _scanning } }
    public var ready: Bool { locked { _ready } }
    public var lastScanSeconds: Double? { locked { _lastScanSeconds } }
    /// Roots whose FSEvents stream failed to start. Retried by `maintenance`, reported in status.
    public var unwatchedRoots: [String] { locked { _unwatchedRoots } }

    private var watchers: [Watcher] = []
    private let work = DispatchQueue(label: "MacEverything.service")
    private var pendingPaths: [String: Bool] = [:] // path -> recursive
    /// Highest event id per root whose change is queued but not yet applied. Lives on `work`.
    private var pendingEventIds: [String: UInt64] = [:]
    /// Highest event id per root whose change is in the index. Only this is ever saved.
    private var appliedEventIds: [String: UInt64] = [:]
    /// Paths whose refresh failed, with the number of attempts so far.
    private var retries: [String: Int] = [:]
    static let maxRetries = 3
    /// Held while loading or scanning, so only one runs and `watchers` has one writer.
    private let lifecycle = NSLock()
    private var flushScheduled = false
    private var dirty = false
    private var timer: DispatchSourceTimer?
    private let log: (String) -> Void

    public init(roots: [String], indexURL: URL = FileIndex.defaultIndexURL,
                exclusions: Set<String> = Scanner.defaultExclusions, log: @escaping (String) -> Void = { _ in }) {
        self.roots = IndexService.normalizeRoots(roots, exclusions: exclusions)
        self.indexURL = indexURL
        self.scanner = Scanner(exclusions: exclusions)
        self.log = log
    }

    /// Canonical, unique, non-overlapping roots. A root inside another root is kept only when
    /// the outer root's scan skips it (for example /Volumes/Work under /, since /Volumes is
    /// excluded); otherwise it would be indexed twice.
    public static func normalizeRoots(_ roots: [String], exclusions: Set<String>) -> [String] {
        var unique: [String] = []
        for root in roots.map(canonical) where !unique.contains(root) { unique.append(root) }
        func inside(_ path: String, _ outer: String) -> Bool {
            outer == "/" ? path != "/" : path.hasPrefix(outer + "/")
        }
        return unique.filter { root in
            !unique.contains { outer in
                outer != root && inside(root, outer)
                    && !exclusions.contains { ex in root == ex || inside(root, ex) }
            }
        }
    }

    /// Resolves symlinks and /private aliases the way FSEvents reports paths.
    public static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// "/" plus every local volume mounted under /Volumes.
    public static func defaultRoots(includeExternal: Bool = true) -> [String] {
        var out = ["/"]
        guard includeExternal else { return out }
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsLocal == true, values?.volumeIsRootFileSystem != true else { continue }
            if url.path.hasPrefix("/Volumes/") { out.append(url.path) }
        }
        return out
    }

    // MARK: - Lifecycle

    /// Loads the saved index if it is still valid, otherwise scans. Returns once the index is
    /// searchable; watching starts in the background.
    public func start() {
        lifecycle.lock()
        if let loaded = loadValidIndex() {
            index.replace(with: loaded)
            locked { _ready = true }
            log("loaded \(loaded.liveCount) entries from \(indexURL.path)")
            work.sync { appliedEventIds = loaded.volumeState.mapValues(\.lastEventId) }
            startWatchers(since: loaded.volumeState)
        } else {
            scanLocked()
        }
        lifecycle.unlock()
        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in self?.maintenance() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        lifecycle.lock()
        watchers.forEach { $0.stop() }
        watchers = []
        lifecycle.unlock()
        try? save()
    }

    private func loadValidIndex() -> FileIndex? {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
        do {
            let loaded = try FileIndex.load(from: indexURL)
            for root in roots {
                // Ids from a per-host stream mean nothing to a per-device one and vice versa.
                let perDevice = Watcher(root: root) { _ in }.isPerDevice
                guard let state = loaded.volumeState[root],
                      state.volumeUUID == (Watcher.volumeUUID(for: root) ?? ""),
                      (state.perDevice ?? false) == perDevice,
                      state.lastEventId <= Watcher.currentEventId(for: root),
                      loaded.lookup(root) != nil
                else {
                    log("saved index is stale for \(root); rescanning")
                    return nil
                }
            }
            if Set(loaded.roots.map { loaded.name(of: $0) }) != Set(roots) {
                log("roots changed; rescanning")
                return nil
            }
            return loaded
        } catch {
            log("could not load index: \(error)")
            return nil
        }
    }

    /// Builds a fresh index off to the side, swaps it in, then replays changes made meanwhile.
    /// Returns false without doing anything when a load or scan is already running.
    @discardableResult
    public func fullScan() -> Bool {
        guard lifecycle.try() else { return false }
        scanLocked()
        lifecycle.unlock()
        return true
    }

    private func scanLocked() {
        locked { _scanning = true }
        // Each root's cursor is taken before any scanning, so the replay covers the whole scan.
        var since: [String: UInt64] = [:]
        for root in roots { since[root] = Watcher.currentEventId(for: root) }
        let started = Date()
        let fresh = FileIndex()
        for root in roots {
            let mtime = (try? FileManager.default.attributesOfItem(atPath: root)[.modificationDate] as? Date)
                .map { Int64($0.timeIntervalSince1970) } ?? 0
            let id = fresh.addRoot(root, modified: mtime)
            let stats = scanner.scanTree(into: fresh, root: id, rootPath: root)
            log("scanned \(root): \(stats.entries) entries, \(stats.unreadable) unreadable folders, "
                + String(format: "%.1f s", stats.seconds))
            fresh.volumeState[root] = .init(volumeUUID: Watcher.volumeUUID(for: root) ?? "",
                                            lastEventId: since[root] ?? 0,
                                            perDevice: Watcher(root: root) { _ in }.isPerDevice)
        }
        fresh.sortIfNeeded(force: true)
        let elapsed = Date().timeIntervalSince(started)
        work.sync {
            // Queued changes refer to the old index; the replay from `since` covers them.
            pendingPaths = [:]
            pendingEventIds = [:]
            appliedEventIds = fresh.volumeState.mapValues(\.lastEventId)
            index.replace(with: fresh)
        }
        locked {
            _lastScanSeconds = elapsed
            _scanning = false
            _ready = true
        }
        dirty = true
        startWatchers(since: fresh.volumeState)
        work.async { try? self.saveOnWork() }
    }

    /// Caller holds `lifecycle`.
    private func startWatchers(since states: [String: FileIndex.VolumeState]) {
        watchers.forEach { $0.stop() }
        watchers = []
        locked { _unwatchedRoots = [] }
        for root in roots { startWatcher(root, since: states[root]?.lastEventId) }
    }

    /// Caller holds `lifecycle`.
    private func startWatcher(_ root: String, since: UInt64?) {
        let w = Watcher(root: root) { [weak self] events in
            self?.receive(events, root: root)
        }
        if w.start(since: since) {
            watchers.append(w)
            locked { _unwatchedRoots.removeAll { $0 == root } }
        } else {
            log("could not watch \(root); changes there are missed until a retry succeeds")
            locked { if !_unwatchedRoots.contains(root) { _unwatchedRoots.append(root) } }
        }
    }

    // MARK: - Updates

    private func receive(_ events: [Watcher.Event], root: String) {
        work.async {
            if let maxId = events.map(\.id).max(), maxId > (self.pendingEventIds[root] ?? 0) {
                self.pendingEventIds[root] = maxId
            }
            for e in events {
                guard let (p, recursive) = IndexService.target(for: e, root: root) else { continue }
                if p != root && self.isExcluded(p) { continue }
                self.pendingPaths[p] = (self.pendingPaths[p] ?? false) || recursive
            }
            if !self.flushScheduled && (!self.pendingPaths.isEmpty || !self.pendingEventIds.isEmpty) {
                self.flushScheduled = true
                self.work.asyncAfter(deadline: .now() + 0.2) { self.flush() }
            }
        }
    }

    /// What to refresh for one event on `root`'s stream: a path and whether to recurse.
    /// Root changes, dropped events, and paths outside the root (FSEvents may report "/" when
    /// it drops events) all mean the whole root is rescanned, so no change is skipped.
    static func target(for e: Watcher.Event, root: String) -> (String, Bool)? {
        if e.rootChanged || e.dropped { return (root, true) }
        if e.path.isEmpty { return nil }
        var p = e.path
        if p.hasPrefix("/System/Volumes/Data/") { p = String(p.dropFirst("/System/Volumes/Data".count)) }
        if p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        let inside = root == "/" || p == root || p.hasPrefix(root + "/")
        return inside ? (p, e.mustScanSubDirs) : (root, true)
    }

    /// The configured root that contains `path` (longest match).
    func rootFor(_ path: String) -> String {
        roots.filter { $0 == "/" || path == $0 || path.hasPrefix($0 + "/") }.max { $0.count < $1.count } ?? "/"
    }

    func isExcluded(_ path: String) -> Bool {
        for ex in scanner.exclusions where path == ex || path.hasPrefix(ex + "/") {
            // Roots inside an excluded folder (for example /Volumes/Work) are still watched.
            if roots.contains(where: { $0 != "/" && (path == $0 || path.hasPrefix($0 + "/")) }) { return false }
            return true
        }
        return false
    }

    /// Applies queued folder changes. Runs on `work`.
    private func flush() {
        flushScheduled = false
        let batch = pendingPaths
        let ids = pendingEventIds
        pendingPaths = [:]
        pendingEventIds = [:]
        var failedRoots = Set<String>()
        defer {
            for (root, id) in ids {
                if failedRoots.contains(root) {
                    // Keep the cursor behind the unapplied change; retry later.
                    pendingEventIds[root] = max(pendingEventIds[root] ?? 0, id)
                } else if id > (appliedEventIds[root] ?? 0) {
                    appliedEventIds[root] = id
                }
            }
            if !pendingPaths.isEmpty && !flushScheduled {
                flushScheduled = true
                work.asyncAfter(deadline: .now() + 5) { self.flush() }
            }
        }
        if batch.isEmpty { return }
        // Parents first, so a rescan of a parent covers its children.
        let ordered = batch.keys.sorted { $0.count < $1.count }
        index.write { idx in
            for path in ordered {
                var target = path
                var recursive = batch[path] ?? false
                var id = idx.lookup(target)
                // A folder we have never seen: refresh its nearest known ancestor instead.
                while id == nil {
                    let parent = (target as NSString).deletingLastPathComponent
                    if parent == target || parent.isEmpty { break }
                    target = parent
                    recursive = false
                    id = idx.lookup(target)
                }
                guard let dir = id, idx.records[Int(dir)].isDirectory else { continue }
                if scanner.refresh(idx, dir: dir, path: target, recursive: recursive) {
                    retries[path] = nil
                    continue
                }
                let attempts = (retries[path] ?? 0) + 1
                if attempts > IndexService.maxRetries {
                    // Persistently unreadable (for example no permission): stop holding the
                    // cursor back, or one folder would stall every later save.
                    log("giving up on \(path) after \(IndexService.maxRetries) failed refreshes")
                    retries[path] = nil
                    continue
                }
                retries[path] = attempts
                pendingPaths[path] = (pendingPaths[path] ?? false) || (batch[path] ?? false)
                failedRoots.insert(rootFor(path))
            }
            if idx.unsorted.count > 50_000 { idx.sortIfNeeded() }
        }
        dirty = true
    }

    private func maintenance() {
        // Retry failed watchers from the last applied event, so nothing missed is skipped.
        if !unwatchedRoots.isEmpty, lifecycle.try() {
            for root in unwatchedRoots { startWatcher(root, since: appliedEventIds[root]) }
            lifecycle.unlock()
        }
        index.write { idx in
            if idx.records.count > 0 && Double(idx.deletedCount) / Double(idx.records.count) > 0.2 {
                // Compaction renumbers records; safe because ids never leave a single request.
                let c = idx.compacted()
                idx.adopt(c)
            } else if !idx.unsorted.isEmpty {
                idx.sortIfNeeded()
            }
        }
        saveCounter += 1
        if dirty && saveCounter % 10 == 0 { try? saveOnWork() }
    }
    private var saveCounter = 0

    /// Applies queued changes, then saves. Safe from any thread except `work`.
    public func save() throws {
        try work.sync { try saveOnWork() }
    }

    /// Runs on `work`, so no change can be applied between choosing the event ids and writing.
    private func saveOnWork() throws {
        flush()
        let applied = appliedEventIds
        try index.write { idx in
            for (root, id) in applied {
                idx.volumeState[root] = .init(volumeUUID: Watcher.volumeUUID(for: root) ?? "", lastEventId: id,
                                              perDevice: idx.volumeState[root]?.perDevice)
            }
            try idx.save(to: indexURL)
        }
        dirty = false
        log("saved index to \(indexURL.path)")
    }

    // MARK: - Requests

    /// Waits until queued changes are applied. For tests and the `sync` command.
    public func sync() { work.sync { flush() } }

    public func handle(_ request: IPCRequest) -> IPCResponse {
        switch request.command {
        case "search":
            let query = Query.parse(request.query ?? "")
            let options = SearchOptions(limit: request.limit ?? 100, offset: request.offset ?? 0,
                                        sort: request.sort ?? .name, descending: request.descending ?? false)
            let result = index.read { $0.search(query, options: options) }
            return IPCResponse(ok: true, result: result)
        case "status":
            return IPCResponse(ok: true, status: status())
        case "rescan":
            if scanning { return IPCResponse(ok: false, error: "a scan is already running", status: status()) }
            DispatchQueue.global().async { self.fullScan() }
            return IPCResponse(ok: true, status: status())
        case "save":
            do { try save(); return IPCResponse(ok: true) } catch {
                return IPCResponse(ok: false, error: "\(error)")
            }
        case "sync":
            sync()
            return IPCResponse(ok: true)
        default:
            return IPCResponse(ok: false, error: "unknown command \(request.command)")
        }
    }

    public func status() -> IPCStatus {
        IPCStatus(ready: ready, entries: index.read { $0.liveCount }, roots: roots, scanning: scanning,
                  lastScanSeconds: lastScanSeconds, memoryBytes: IndexService.residentBytes(),
                  unwatchedRoots: unwatchedRoots)
    }

    public static func residentBytes() -> Int? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size) : nil
    }
}
#endif
