#if canImport(CoreServices)
import Foundation
import Darwin

/// User settings, read from config.json next to the index. Every field is optional.
public struct ServiceConfig: Codable {
    public var roots: [String]?
    public var exclusions: [String]?
    /// Folder names to skip anywhere. Replaces `Scanner.defaultExcludedNames` when set,
    /// so `[]` indexes browser caches again.
    public var excludedNames: [String]?
    public var includeExternalVolumes: Bool?
    /// Locations added on top of the default roots (the search window's Locations list):
    /// network shares, folders outside the scanned volumes, excluded folders.
    public var extraRoots: [String]?

    public init(roots: [String]? = nil, exclusions: [String]? = nil, excludedNames: [String]? = nil,
                includeExternalVolumes: Bool? = nil, extraRoots: [String]? = nil) {
        self.roots = roots
        self.exclusions = exclusions
        self.excludedNames = excludedNames
        self.includeExternalVolumes = includeExternalVolumes
        self.extraRoots = extraRoots
    }

    public static var defaultURL: URL { FileIndex.defaultDirectory.appendingPathComponent("config.json") }

    public static func load(from url: URL = defaultURL) -> ServiceConfig {
        guard let data = try? Data(contentsOf: url) else { return ServiceConfig() }
        return (try? JSONDecoder().decode(ServiceConfig.self, from: data)) ?? ServiceConfig()
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Every location to index: the configured or default roots (the boot volume and each
    /// local drive mounted now) plus the added ones.
    public func resolvedRoots(defaults: @autoclosure () -> [String] = IndexService.defaultRoots()) -> [String] {
        let base = roots ?? (includeExternalVolumes == false ? ["/"] : defaults())
        return base + (extraRoots ?? []).map(IndexService.canonical)
    }

    public var exclusionSet: Set<String> {
        var out = Scanner.defaultExclusions
        for extra in exclusions ?? [] { out.insert(IndexService.canonical(extra)) }
        return out
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
    private var _scanningRoot: String?
    private var _scannedSoFar = 0
    /// A full scan is building a new index. Queued changes are dropped meanwhile: they would
    /// go to the index about to be replaced, and the scan replays them from its own cursor.
    private var _replacing = false
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
    /// Folders still to list for changes taken from `pendingPaths`, newest last (listed first).
    /// The rest of the walk-related state below covers the same changes. All live on `work`.
    private var walk: [Scanner.PendingFolder] = []
    /// Highest event id per root taken into `walk`; applied only once the walk is done.
    private var walkEventIds: [String: UInt64] = [:]
    /// Folders that failed to list during the walk, one entry each (the latest attempt).
    private var walkFailures: [String: Scanner.RefreshFailure] = [:]
    private var walkStarted: Date?
    /// Recursive refreshes in this pass of the walk, and the ones asked for again meanwhile.
    /// A repeat (FSEvents dropping events again) waits for the next pass instead of restarting
    /// this one, so the walk finishes even when drops keep coming.
    private var walkTargets: [String] = []
    private var nextPass: [String: Bool] = [:]
    /// `walkEventIds` as it was when the current next pass started: once that pass is done,
    /// those changes are applied, even if drops keep queueing more passes.
    private var passStartIds: [String: UInt64]?
    private var retryScheduled = false
    /// Folders that changed in the last minute. When FSEvents drops events these are listed
    /// first: a bulk change big enough to overflow the queue (a 5000-file delete) most likely
    /// went on in the same folders, and the whole-volume walk would reach them minutes later.
    private var recentlyChanged: [String: Date] = [:]
    /// How long one flush lists folders before letting newer changes in. 0 lists one folder.
    var sliceSeconds = 0.25
    /// Tests set this before `start()`: no FSEvents watchers and no automatic flushes, so
    /// changes are applied only by `flushSliceNow()` (one slice) or `sync()`.
    var stepsByHand = false
    static let maxRetries = 3
    /// Held while loading or scanning, so only one runs and `watchers` has one writer.
    private let lifecycle = NSLock()
    private var flushScheduled = false
    private var dirty = false
    /// Compacts and writes index snapshots off `work`, so live changes keep applying during a
    /// save (a 212 MB save took 4 to 69 s and blocked every change meanwhile). Serial, so files
    /// are written in the order their snapshots were taken.
    private let saveQueue = DispatchQueue(label: "MacEverything.save", qos: .utility)
    /// A background save is queued or running. Lives on `work`.
    private var saveInFlight = false
    private var timer: DispatchSourceTimer?
    private let log: (String) -> Void

    public init(roots: [String], indexURL: URL = FileIndex.defaultIndexURL,
                exclusions: Set<String> = Scanner.defaultExclusions,
                excludedNames: Set<String> = Scanner.defaultExcludedNames,
                log: @escaping (String) -> Void = { _ in }) {
        self.roots = IndexService.normalizeRoots(roots, exclusions: exclusions)
        self.indexURL = indexURL
        self.scanner = Scanner(exclusions: exclusions, excludedNames: excludedNames)
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
        if ready {
            // A rescan requested before startup got the lock (ev --rescan right after launch)
            // already built a fresh index; loading the saved file now would only redo work.
        } else if let loaded = loadIndex() {
            index.replace(with: loaded)
            locked {
                _ready = true
                _scanning = false
                _scanningRoot = nil
            }
            log("loaded \(loaded.liveCount) entries from \(indexURL.path)")
            work.sync { appliedEventIds = loaded.volumeState.mapValues(\.lastEventId) }
            startWatchers(since: loaded.volumeState)
        } else {
            scanLocked()
        }
        work.sync {
            for root in roots where !FileManager.default.fileExists(atPath: root) { offlineRoots.insert(root) }
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

    /// Loads the saved index and checks each root on its own: valid roots are kept, roots no
    /// longer configured are dropped, and only stale or new roots are scanned. A drive that is
    /// plugged in or out therefore does not force a rescan of the boot volume.
    private func loadIndex() -> FileIndex? {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
        let loaded: FileIndex
        do { loaded = try FileIndex.load(from: indexURL) } catch {
            log("could not load index: \(error)")
            return nil
        }
        for id in loaded.roots where !roots.contains(loaded.name(of: id)) {
            loaded.volumeState[loaded.name(of: id)] = nil
            loaded.remove(id)
        }
        var stale: [String] = []
        for root in roots {
            // Ids from a per-host stream mean nothing to a per-device one and vice versa.
            let perDevice = Watcher(root: root) { _ in }.isPerDevice
            var reason: String?
            if let state = loaded.volumeState[root] {
                let uuid = Watcher.volumeUUID(for: root) ?? "", current = Watcher.currentEventId(for: root)
                if perDevice && current == 0 {
                    // No FSEvents history on this volume (for example exFAT, or a drive used
                    // on another computer): changes made while we were not running are unknown.
                    reason = "the volume keeps no change history"
                } else if state.volumeUUID != uuid {
                    reason = "volume id changed (\(state.volumeUUID) to \(uuid))"
                } else if (state.perDevice ?? false) != perDevice {
                    reason = "change stream type changed"
                } else if state.lastEventId > current {
                    reason = "saved event id \(state.lastEventId) is ahead of the volume's \(current)"
                }
            } else {
                reason = "no saved state"
            }
            if reason == nil && loaded.lookup(root) == nil { reason = "root missing from the index" }
            guard let reason else { continue }
            log("\(root) needs a rescan: \(reason)")
            if let id = loaded.lookup(root), loaded.records[Int(id)].parent < 0 { loaded.remove(id) }
            stale.append(root)
        }
        if !stale.isEmpty {
            log("scanning \(stale.joined(separator: ", ")); keeping the rest of the saved index")
            scanRoots(stale, into: loaded)
            locked { _scanningRoot = nil }
        }
        loaded.sortIfNeeded()
        return loaded
    }

    /// Scans `list` into `target`, recording each root's cursor before any scanning starts.
    private func scanRoots(_ list: [String], into target: FileIndex) {
        locked {
            _scanning = true
            _scannedSoFar = 0
        }
        var since: [String: UInt64] = [:]
        for root in list { since[root] = Watcher.currentEventId(for: root) }
        for root in list {
            let mtime = (try? FileManager.default.attributesOfItem(atPath: root)[.modificationDate] as? Date)
                .map { Int64($0.timeIntervalSince1970) } ?? 0
            let id = target.addRoot(root, modified: mtime)
            let base = locked { () -> Int in
                _scanningRoot = root
                return _scannedSoFar
            }
            let stats = scanner.scanTree(into: target, root: id, rootPath: root) { [weak self] n in
                self?.locked { self?._scannedSoFar = base + n }
            }
            locked { _scannedSoFar = base + stats.entries }
            log("scanned \(root): \(stats.entries) entries, \(stats.unreadable) unreadable folders, "
                + String(format: "%.1f s", stats.seconds))
            for s in stats.slowest {
                log("  slow folder: " + String(format: "%.1f s  ", s.seconds) + s.path)
            }
            target.volumeState[root] = .init(volumeUUID: Watcher.volumeUUID(for: root) ?? "",
                                             lastEventId: since[root] ?? 0,
                                             perDevice: Watcher(root: root) { _ in }.isPerDevice)
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
        locked {
            _scanning = true
            _replacing = true
        }
        let started = Date()
        let fresh = FileIndex()
        scanRoots(roots, into: fresh)
        locked { _scanningRoot = nil } // every root is listed; status reports the sort
        let sortStarted = Date()
        fresh.sortIfNeeded(force: true)
        log("sorted \(fresh.liveCount) names in " + String(format: "%.1f s", Date().timeIntervalSince(sortStarted)))
        let elapsed = Date().timeIntervalSince(started)
        work.sync {
            // Queued changes refer to the old index; the replay from `since` covers them.
            pendingPaths = [:]
            pendingEventIds = [:]
            resetWalk() // its ids point into the old index
            appliedEventIds = fresh.volumeState.mapValues(\.lastEventId)
            index.replace(with: fresh)
            dirty = true // lives on `work`
            locked { _replacing = false }
        }
        locked {
            _lastScanSeconds = elapsed
            _scanning = false
            _scanningRoot = nil
            _ready = true
        }
        startWatchers(since: fresh.volumeState)
        work.async { self.saveInBackground() }
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
        if stepsByHand { return }
        watchers.filter { $0.root == root }.forEach { $0.stop() }
        watchers.removeAll { $0.root == root }
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

    func receive(_ events: [Watcher.Event], root: String) {
        work.async {
            if let maxId = events.map(\.id).max(), maxId > (self.pendingEventIds[root] ?? 0) {
                self.pendingEventIds[root] = maxId
            }
            for e in events {
                guard let (p, recursive) = IndexService.target(for: e, root: root) else { continue }
                if p == root && recursive && self.pendingPaths[root] != true {
                    // Rare and expensive (a whole-volume re-list): say why it happened.
                    let why = e.dropped ? "events were dropped" : e.rootChanged ? "the root changed"
                        : e.mustScanSubDirs ? "FSEvents asked for a subtree scan" : "event outside the root"
                    self.log("re-listing all of \(root): \(why) (event \(e.id) on \(e.path))")
                }
                if p != root && self.isExcluded(p) { continue }
                self.pendingPaths[p] = (self.pendingPaths[p] ?? false) || recursive
            }
            if !self.stepsByHand && !self.flushScheduled
                && (!self.pendingPaths.isEmpty || !self.pendingEventIds.isEmpty) {
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
        // Inside a folder skipped by name (a browser cache): its contents are never indexed.
        if !scanner.excludedNames.isEmpty {
            let root = rootFor(path)
            let below = root == "/" ? path : String(path.dropFirst(root.count))
            if below.split(separator: "/").contains(where: { scanner.excludedNames.contains(String($0)) }) {
                return true
            }
        }
        return false
    }

    /// Applies queued folder changes. Runs on `work`.
    ///
    /// Changed folders go on top of `walk`, so they are listed first. A long walk (the whole
    /// volume, after FSEvents dropped events) is listed a slice at a time; between slices the
    /// changes that arrived meanwhile are taken in and listed ahead of it, so they show within
    /// a second instead of after the minutes the walk takes. `drain` lists everything first.
    private func flush(drain: Bool = false) {
        flushScheduled = false
        if locked({ _replacing }) {
            pendingPaths = [:]
            pendingEventIds = [:]
            resetWalk()
            return
        }
        let batch = pendingPaths
        pendingPaths = [:]
        for (root, id) in pendingEventIds where id > (walkEventIds[root] ?? 0) { walkEventIds[root] = id }
        pendingEventIds = [:]
        let now = Date()
        for path in batch.keys { recentlyChanged[path] = now }
        if recentlyChanged.count > 2000 { recentlyChanged = recentlyChanged.filter { now.timeIntervalSince($0.value) < 60 } }
        // Longest first, so parents end up on top and are listed first.
        for path in batch.keys.sorted(by: { $0.count > $1.count }) { enqueue(path, recursive: batch[path] ?? false) }
        repeat {
            if walk.isEmpty && !nextPass.isEmpty {
                // A pass is done. If it was a next pass, what was taken in before it is applied.
                if let covered = passStartIds { settle(covered) }
                passStartIds = walkEventIds
                let again = nextPass
                nextPass = [:]
                walkTargets = []
                for path in again.keys.sorted(by: { $0.count > $1.count }) { enqueue(path, recursive: again[path]!) }
            }
            if !walk.isEmpty {
                if walkStarted == nil { walkStarted = Date() }
                let end = Date().addingTimeInterval(sliceSeconds)
                let failed = scanner.refreshFailures(index, queue: &walk,
                                                     cancelled: { self.locked { self._replacing } },
                                                     yield: { !drain && Date() >= end },
                                                     handled: { path, deep in
                                                         // Listed fine: an earlier failure it covers
                                                         // is over (a shallow listing does not
                                                         // cover a failed walk below the folder).
                                                         if deep || self.walkFailures[path]?.recursive != true {
                                                             self.walkFailures[path] = nil
                                                             self.retries[path] = nil
                                                         }
                                                     },
                                                     // A new folder is where a bulk change most
                                                     // likely goes on (mkdir, then 5000 files).
                                                     discovered: { self.recentlyChanged[$0] = Date() })
                for f in failed {
                    var latest = f
                    latest.recursive = f.recursive || (walkFailures[f.path]?.recursive ?? false)
                    walkFailures[f.path] = latest
                }
                if index.read({ $0.unsorted.count }) > 50_000 { sortOffLock() }
                dirty = true
            }
            if locked({ _replacing }) {
                // Cancelled for a full scan: nothing was applied, so no cursor may move.
                resetWalk()
                return
            }
        } while drain && !nextPass.isEmpty
        if !walk.isEmpty || !nextPass.isEmpty {
            // Unfinished: the event ids stay held, so a save never claims the rest is applied.
            // Changes queued behind this block are taken in by the next slice, ahead of the walk.
            if !stepsByHand {
                flushScheduled = true
                work.async { self.flush() }
            }
            return
        }
        finishWalk()
    }

    /// Puts one changed folder on top of the walk. Runs on `work`.
    private func enqueue(_ path: String, recursive wanted: Bool) {
        // Resolve under the shared lock; refresh lists folders without holding any lock.
        // Ids stay valid across slices because every index write happens on this queue
        // and compaction waits until the walk is done.
        let resolved: (String, Int32, Bool)? = index.read { idx in
            var target = path
            var recursive = wanted
            var id = idx.lookup(target)
            // A folder we have never seen: refresh its nearest known ancestor instead.
            while id == nil {
                let parent = (target as NSString).deletingLastPathComponent
                if parent == target || parent.isEmpty { break }
                target = parent
                recursive = false
                id = idx.lookup(target)
            }
            guard let dir = id, idx.records[Int(dir)].isDirectory else { return nil }
            return (target, dir, recursive)
        }
        guard let (target, dir, recursive) = resolved else { return }
        if roots.contains(target) && !FileManager.default.fileExists(atPath: target) {
            offlineRoots.insert(target) // a drive was unplugged; rescanned when it returns
        }
        if recursive {
            let root = rootFor(target)
            func covers(_ outer: String, _ inner: String) -> Bool {
                rootFor(inner) == root && (outer == root || inner == outer || inner.hasPrefix(outer + "/"))
            }
            if walkTargets.contains(target) {
                // The same walk again (events dropped again): restarting it each time could
                // keep it from ever finishing, so it runs once more after this pass. A folder
                // below a walk under way goes on top instead, like any change.
                nextPass[target] = true
            } else {
                // This walk covers whatever is queued below it, so it replaces those entries.
                walk.removeAll { covers(target, $0.path) }
                walkTargets.removeAll { covers(target, $0) }
                walkTargets.append(target)
                walk.append((target, dir, recursive))
            }
            if target == root {
                // Events were dropped: re-list the folders changed in the last minute first. At
                // most 64 per drop, so repeated drops cannot starve the walk itself.
                let cutoff = Date().addingTimeInterval(-60)
                let recent = recentlyChanged.filter { $0.value > cutoff && $0.key != target && rootFor($0.key) == root }
                for (p, _) in recent.sorted(by: { $0.value > $1.value }).prefix(64).reversed() {
                    enqueue(p, recursive: false) // newest ends up on top
                }
            }
            return
        }
        walk.append((target, dir, recursive))
    }

    /// Everything taken into the walk is listed: retry what failed, advance the cursors.
    private func finishWalk() {
        if let started = walkStarted, Date().timeIntervalSince(started) > 2 {
            log("applied queued changes in " + String(format: "%.1f s", Date().timeIntervalSince(started)))
        }
        settle(walkEventIds)
        resetWalk()
        // Its own flag, so a retry waiting 5 s never delays a fresh change's 0.2 s flush.
        if !pendingPaths.isEmpty && !retryScheduled && !stepsByHand {
            retryScheduled = true
            work.asyncAfter(deadline: .now() + 5) {
                self.retryScheduled = false
                self.flush()
            }
        }
    }

    /// Accounts for the folders that failed so far and applies the event ids in `ids`, except
    /// for roots with a failure: those ids wait in `pendingEventIds` for the retry.
    private func settle(_ ids: [String: UInt64]) {
        var failedRoots = Set<String>()
        // Retry only the folders that failed, not the whole request: a volume-wide refresh
        // with one unreadable folder in it would otherwise re-list millions of entries.
        for f in walkFailures.values {
            let attempts = (retries[f.path] ?? 0) + 1
            if attempts > IndexService.maxRetries {
                // Persistently unreadable: stop holding the cursor back, or one folder
                // would stall every later save.
                let reason = f.errno != 0 ? String(cString: strerror(f.errno)) : "unknown error"
                log("giving up on \(f.path) after \(IndexService.maxRetries) failed refreshes (\(reason))")
                retries[f.path] = nil
                continue
            }
            retries[f.path] = attempts
            pendingPaths[f.path] = (pendingPaths[f.path] ?? false) || f.recursive
            failedRoots.insert(rootFor(f.path))
        }
        walkFailures = [:]
        for root in failedRoots {
            // Keep the cursor behind the unapplied change, and everything taken in after it.
            let held = max(ids[root] ?? 0, walkEventIds[root] ?? 0)
            if held > 0 { pendingEventIds[root] = max(pendingEventIds[root] ?? 0, held) }
            walkEventIds[root] = nil
            passStartIds?[root] = nil
        }
        for (root, id) in ids where !failedRoots.contains(root) && id > (appliedEventIds[root] ?? 0) {
            appliedEventIds[root] = id
        }
    }

    private func resetWalk() {
        walk = []
        walkEventIds = [:]
        walkFailures = [:]
        walkStarted = nil
        walkTargets = []
        nextPass = [:]
        passStartIds = nil
    }

    private func maintenance() {
        // Retry failed watchers from the last applied event, so nothing missed is skipped.
        if !unwatchedRoots.isEmpty, lifecycle.try() {
            for root in unwatchedRoots { startWatcher(root, since: appliedEventIds[root]) }
            lifecycle.unlock()
        }
        // A drive that was unplugged and is back: watch it again and re-list it.
        let returned = offlineRoots.filter { FileManager.default.fileExists(atPath: $0) }
        if !returned.isEmpty, lifecycle.try() {
            for root in returned {
                let since = Watcher.currentEventId(for: root)
                // A different disk at the same path: forget the old disk's id. Saves made before
                // the re-list below finishes then carry no state for this root (a load rescans
                // it), and the one after it stamps the new disk's id with the new cursor.
                let uuid = Watcher.volumeUUID(for: root) ?? ""
                let otherDisk: Bool = index.write { idx in
                    guard let saved = idx.volumeState[root], saved.volumeUUID != uuid else { return false }
                    idx.volumeState[root] = nil
                    return true
                }
                if otherDisk {
                    // Event ids still held for the old disk mean nothing on this one.
                    pendingEventIds[root] = nil
                    walkEventIds[root] = nil
                    passStartIds?[root] = nil
                }
                startWatcher(root, since: since)
                // Applied (and saved) only once the re-list below is done, like any change.
                // Until then a save keeps the index file's own volume id and cursor for this
                // root, a matching pair: a different disk now mounted there fails the id check.
                appliedEventIds[root] = nil
                pendingEventIds[root] = max(pendingEventIds[root] ?? 0, since)
                pendingPaths[root] = true
                offlineRoots.remove(root)
                log("\(root) is back; rescanning it")
            }
            lifecycle.unlock()
            flush()
        }
        // Heavy work runs under the shared lock; the write lock is held only to swap results in.
        // Nothing else writes the index meanwhile, since all writes happen on this queue.
        // Not while a walk is unfinished: it holds record ids, which compaction renumbers.
        let compacted: FileIndex? = !walk.isEmpty || !nextPass.isEmpty ? nil : index.read { idx in
            idx.records.count > 0 && Double(idx.deletedCount) / Double(idx.records.count) > 0.2
                ? idx.compacted() : nil
        }
        if let c = compacted {
            // Compaction renumbers records; safe because ids never leave a single request.
            index.write { $0.adopt(c) }
        } else {
            sortOffLock()
        }
        saveCounter += 1
        if dirty && saveCounter % 10 == 0 { saveInBackground() }
    }
    private var saveCounter = 0
    /// Roots whose path disappeared (an unplugged drive). Lives on `work`.
    private var offlineRoots = Set<String>()

    /// Sorts under the shared lock and installs the order under the write lock. Runs on `work`.
    private func sortOffLock() {
        guard let order = index.read({ $0.needsSort ? $0.computedOrder() : nil }) else { return }
        index.write { $0.install(order: order) }
    }

    /// Applies queued changes, then saves. Safe from any thread except `work`. Returns once the
    /// file is written, after any background save queued before it.
    public func save() throws {
        // The write is queued in the same `work` step that takes the snapshot, so writes land in
        // snapshot order: an older snapshot can never overwrite a newer file.
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        let queued: Bool = work.sync {
            guard let snap = snapshotOnWork() else { return false }
            saveQueue.async {
                do { try self.write(snap) } catch { failure = error }
                done.signal()
            }
            return true
        }
        guard queued else { return }
        done.wait()
        if let failure { throw failure }
    }

    /// Runs on `work`: snapshots now, writes on `saveQueue`. Skipped while one is in flight; the
    /// index stays dirty, so a later maintenance pass saves it.
    private func saveInBackground() {
        guard !saveInFlight, let snap = snapshotOnWork() else { return }
        saveInFlight = true
        saveQueue.async {
            try? self.write(snap)
            self.work.async { self.saveInFlight = false }
        }
    }

    /// Runs on `work`, so no change can be applied between choosing the event ids and taking the
    /// snapshot: the saved cursors always match the saved records.
    private func snapshotOnWork() -> (index: FileIndex, started: Date)? {
        // Before the first load or scan finishes, the index is empty; saving it would
        // overwrite a good index file.
        guard ready else { return nil }
        let started = Date()
        flush()
        let applied = appliedEventIds
        // No sort here: FileIndex.save sorts its compacted copy off this queue when needed
        // (a sort of 2.8M names held `work` for about 3 s).
        let snap: FileIndex = index.write { idx in
            for (root, id) in applied {
                // Keep the volume id the records came from (set by the scan that listed them).
                // Asking the disk now could pair one disk's records with another disk mounted at
                // the same path; a kept id that no longer matches only costs a rescan at load.
                // No stored id (a different disk came back, see maintenance): ask the disk, as a scan does.
                let saved = idx.volumeState[root]
                idx.volumeState[root] = .init(volumeUUID: saved?.volumeUUID ?? Watcher.volumeUUID(for: root) ?? "",
                                              lastEventId: id,
                                              perDevice: saved?.perDevice ?? Watcher(root: root) { _ in }.isPerDevice)
            }
            return idx.snapshot()
        }
        // Changes after this point dirty the index again; a failed write below re-dirties it.
        dirty = false
        return (snap, started)
    }

    /// Runs on `saveQueue`.
    private func write(_ snap: (index: FileIndex, started: Date)) throws {
        let wrote = Date()
        do {
            try snap.index.save(to: indexURL)
        } catch {
            work.async { self.dirty = true }
            log("could not save index: \(error)")
            throw error
        }
        log("saved index to \(indexURL.path) in " + String(format: "%.1f s", Date().timeIntervalSince(snap.started))
            + String(format: " (%.1f s off the update queue)", Date().timeIntervalSince(wrote)))
    }

    // MARK: - Requests

    /// Waits until queued changes are applied. For tests and the `sync` command.
    public func sync() { work.sync { flush(drain: true) } }

    /// Runs one flush: queued changes, then one slice of an unfinished walk. For tests.
    func flushSliceNow() { work.sync { flush() } }

    /// Folders an unfinished walk has yet to list. For tests.
    var foldersLeftToList: Int { work.sync { walk.count } }

    /// Whole-tree refreshes waiting for the walk under way to finish. For tests.
    var passesWaiting: Int { work.sync { nextPass.count } }

    /// The newest event id whose change is in the index, the one a save records. For tests.
    func appliedEventId(for root: String) -> UInt64? { work.sync { appliedEventIds[root] } }

    /// Runs the once-a-minute maintenance pass now. For tests.
    func maintenanceNow() { work.sync { maintenance() } }

    public func handle(_ request: IPCRequest) -> IPCResponse {
        switch request.command {
        case "search":
            guard ready else {
                let progress = locked { _scannedSoFar }
                let text = progress > 0
                    ? "the index is still being built (\(progress.formatted()) entries so far); try again shortly"
                    : "the index is still being built; try again shortly"
                return IPCResponse(ok: false, error: text,
                                   status: status())
            }
            let query = Query.parse(request.query ?? "").and(Query.parse(request.scope ?? ""))
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
            guard ready else {
                return IPCResponse(ok: false, error: "the index is still being built; nothing to save yet",
                                   status: status())
            }
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
                  unwatchedRoots: unwatchedRoots,
                  scanningRoot: locked { _scanning ? _scanningRoot : nil },
                  scannedSoFar: locked { _scanning ? _scannedSoFar : nil })
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
