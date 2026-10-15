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
    public private(set) var scanning = false
    public private(set) var ready = false
    public private(set) var lastScanSeconds: Double?

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
        self.roots = roots.map(IndexService.canonical)
        self.indexURL = indexURL
        self.scanner = Scanner(exclusions: exclusions)
        self.log = log
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
            ready = true
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
            let current = Watcher.currentEventId
            for root in roots {
                guard let state = loaded.volumeState[root],
                      state.volumeUUID == (Watcher.volumeUUID(for: root) ?? ""),
                      state.lastEventId <= current,
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
        scanning = true
        let since = Watcher.currentEventId
        let started = Date()
        let fresh = FileIndex()
        for root in roots {
            let mtime = (try? FileManager.default.attributesOfItem(atPath: root)[.modificationDate] as? Date)
                .map { Int64($0.timeIntervalSince1970) } ?? 0
            let id = fresh.addRoot(root, modified: mtime)
            let stats = scanner.scanTree(into: fresh, root: id, rootPath: root)
            log("scanned \(root): \(stats.entries) entries, \(stats.unreadable) unreadable folders, "
                + String(format: "%.1f s", stats.seconds))
            fresh.volumeState[root] = .init(volumeUUID: Watcher.volumeUUID(for: root) ?? "", lastEventId: since)
        }
        fresh.sortIfNeeded(force: true)
        lastScanSeconds = Date().timeIntervalSince(started)
        work.sync {
            // Queued changes refer to the old index; the replay from `since` covers them.
            pendingPaths = [:]
            pendingEventIds = [:]
            appliedEventIds = fresh.volumeState.mapValues(\.lastEventId)
            index.replace(with: fresh)
        }
        scanning = false
        ready = true
        dirty = true
        startWatchers(since: fresh.volumeState)
        work.async { try? self.saveOnWork() }
    }

    private func startWatchers(since states: [String: FileIndex.VolumeState]) {
        watchers.forEach { $0.stop() }
        watchers = roots.map { root in
            let since = states[root]?.lastEventId
            let w = Watcher(paths: [root], since: since) { [weak self] events in
                self?.receive(events, root: root)
            }
            if !w.start(since: since) { log("could not watch \(root)") }
            return w
        }
    }

    // MARK: - Updates

    private func receive(_ events: [Watcher.Event], root: String) {
        work.async {
            if let maxId = events.map(\.id).max(), maxId > (self.pendingEventIds[root] ?? 0) {
                self.pendingEventIds[root] = maxId
            }
            if events.contains(where: \.rootChanged) {
                // The root itself (or an ancestor) was renamed, deleted or recreated:
                // re-list the whole hierarchy. A missing root is emptied by refresh.
                self.pendingPaths[root] = true
            }
            for e in events where !e.path.isEmpty && !e.rootChanged {
                var p = e.path
                if p.hasPrefix("/System/Volumes/Data/") { p = String(p.dropFirst("/System/Volumes/Data".count)) }
                if p.count > 1 && p.hasSuffix("/") { p.removeLast() }
                if self.isExcluded(p) { continue }
                self.pendingPaths[p] = (self.pendingPaths[p] ?? false) || e.mustScanSubDirs
            }
            if !self.flushScheduled && (!self.pendingPaths.isEmpty || !self.pendingEventIds.isEmpty) {
                self.flushScheduled = true
                self.work.asyncAfter(deadline: .now() + 0.2) { self.flush() }
            }
        }
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
                idx.volumeState[root] = .init(volumeUUID: Watcher.volumeUUID(for: root) ?? "", lastEventId: id)
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
                  lastScanSeconds: lastScanSeconds, memoryBytes: IndexService.residentBytes())
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
