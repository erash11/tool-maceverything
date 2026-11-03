import Foundation

/// One entry discovered by a scanner: a file or folder inside a known directory.
public struct ScannedEntry: Equatable {
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Int64 // seconds since 1970

    public init(name: String, isDirectory: Bool, size: Int64, modified: Int64) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }
}

/// Fixed-size record for one path entry. Names live in shared byte pools.
public struct Record {
    public var parent: Int32        // -1 for a root
    public var nameStart: UInt32    // offset into `names`
    public var nameLength: UInt16
    public var lowerStart: UInt32   // offset into `lowerNames`
    public var lowerLength: UInt16
    public var flags: UInt8         // bit 0: directory, bit 1: deleted
    public var size: Int64
    public var modified: Int64

    public var isDirectory: Bool { flags & 1 != 0 }
    public var isDeleted: Bool { flags & 2 != 0 }
}

/// In-memory index of every path under a set of roots.
///
/// Not thread-safe on its own; `SharedIndex` adds the locking.
public final class FileIndex {
    public internal(set) var records: [Record] = []
    public internal(set) var names: [UInt8] = []
    public internal(set) var lowerNames: [UInt8] = []
    /// Directory record id -> live child record ids.
    var children: [Int32: [Int32]] = [:]
    /// Live record ids sorted by lowercase name. Ids appended since the last sort live in `unsorted`.
    var order: [Int32] = []
    var unsorted: [Int32] = []
    /// rank[id] = position of id in `order`, or -1 when the id is not in `order`.
    var rank: [Int32] = []
    /// Ids of every record with no parent, deleted or not. Roots are few, so lookups scan this
    /// instead of all records.
    var rootIdList: [Int32] = []
    public internal(set) var deletedCount = 0
    /// See `tempMask()`. Searches run concurrently under the shared lock, so the cache has its own.
    let tempMaskLock = NSLock()
    var tempMaskCache: (records: Int, deleted: Int, mask: [UInt8])?
    /// See `kindTable()`, cached the same way with its own lock.
    let kindLock = NSLock()
    var kindCache: KindTable?

    /// Saved FSEvents state per root path.
    public var volumeState: [String: VolumeState] = [:]

    public struct VolumeState: Codable, Equatable {
        public var volumeUUID: String
        public var lastEventId: UInt64
        /// True when lastEventId comes from a per-device stream (see Watcher).
        public var perDevice: Bool?
        public init(volumeUUID: String, lastEventId: UInt64, perDevice: Bool? = nil) {
            self.volumeUUID = volumeUUID
            self.lastEventId = lastEventId
            self.perDevice = perDevice
        }
    }

    public init() {}

    public var liveCount: Int { records.count - deletedCount }

    // MARK: - Reading

    public func name(of id: Int32) -> String {
        let r = records[Int(id)]
        let start = Int(r.nameStart)
        return String(decoding: names[start..<start + Int(r.nameLength)], as: UTF8.self)
    }

    public func path(of id: Int32) -> String {
        var parts: [String] = []
        var cur = id
        while cur >= 0 {
            parts.append(name(of: cur))
            cur = records[Int(cur)].parent
        }
        guard var result = parts.popLast() else { return "" }
        while let next = parts.popLast() {
            if !result.hasSuffix("/") { result += "/" }
            result += next
        }
        return result
    }

    public var roots: [Int32] { rootIdList.filter { !records[Int($0)].isDeleted } }

    public func childIds(of id: Int32) -> [Int32] { children[id] ?? [] }

    /// Finds the record for an absolute path, or nil.
    public func lookup(_ path: String) -> Int32? {
        let normalized = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        // Longest matching root wins, so /Volumes/X beats /.
        var best: (id: Int32, root: String)?
        for id in roots {
            let root = name(of: id)
            let matches = normalized == root
                || (root == "/" && normalized.hasPrefix("/"))
                || normalized.hasPrefix(root + "/")
            if matches, best == nil || root.count > best!.root.count {
                best = (id, root)
            }
        }
        guard let start = best else { return nil }
        if normalized == start.root { return start.id }
        var rest = String(normalized.dropFirst(start.root.count))
        if rest.hasPrefix("/") { rest.removeFirst() }
        var cur = start.id
        for component in rest.split(separator: "/", omittingEmptySubsequences: true) {
            guard let next = child(of: cur, named: String(component)) else { return nil }
            cur = next
        }
        return cur
    }

    public func child(of id: Int32, named childName: String) -> Int32? {
        guard let kids = children[id] else { return nil }
        let target = Array(childName.utf8)
        for kid in kids {
            let r = records[Int(kid)]
            let start = Int(r.nameStart)
            let len = Int(r.nameLength)
            if len == target.count && names[start..<start + len].elementsEqual(target) {
                return kid
            }
        }
        return nil
    }

    /// Lowercase, precomposed form used for matching. macOS returns decomposed names
    /// ("e" + combining accent) while typed queries are precomposed.
    public static func searchForm(_ s: String) -> String {
        s.lowercased().precomposedStringWithCanonicalMapping
    }

    // MARK: - Writing

    @discardableResult
    public func addRoot(_ path: String, modified: Int64 = 0) -> Int32 {
        if let existing = roots.first(where: { name(of: $0) == path }) { return existing }
        return append(name: path, parent: -1, isDirectory: true, size: 0, modified: modified)
    }

    @discardableResult
    public func add(_ entry: ScannedEntry, parent: Int32) -> Int32 {
        append(name: entry.name, parent: parent, isDirectory: entry.isDirectory,
               size: entry.size, modified: entry.modified)
    }

    private func append(name: String, parent: Int32, isDirectory: Bool, size: Int64, modified: Int64) -> Int32 {
        var bytes = Array(name.utf8)
        if bytes.count > Int(UInt16.max) { bytes = Array(bytes.prefix(Int(UInt16.max))) }
        var lower = Array(FileIndex.searchForm(name).utf8)
        if lower.count > Int(UInt16.max) { lower = Array(lower.prefix(Int(UInt16.max))) }
        return appendRaw(bytes: bytes[...], lower: lower[...], parent: parent, isDirectory: isDirectory,
                         size: size, modified: modified)
    }

    /// Appends a record whose name bytes are already prepared (used by compaction, which
    /// copies them instead of lowercasing and normalizing every name again).
    private func appendRaw(bytes: ArraySlice<UInt8>, lower: ArraySlice<UInt8>, parent: Int32,
                           isDirectory: Bool, size: Int64, modified: Int64) -> Int32 {
        let id = Int32(records.count)
        let record = Record(
            parent: parent,
            nameStart: UInt32(names.count), nameLength: UInt16(bytes.count),
            lowerStart: UInt32(lowerNames.count), lowerLength: UInt16(lower.count),
            flags: isDirectory ? 1 : 0, size: size, modified: modified)
        names.append(contentsOf: bytes)
        lowerNames.append(contentsOf: lower)
        records.append(record)
        rank.append(-1)
        if parent >= 0 { children[parent, default: []].append(id) } else { rootIdList.append(id) }
        unsorted.append(id)
        return id
    }

    /// Marks a record and everything under it deleted.
    public func remove(_ id: Int32) {
        guard !records[Int(id)].isDeleted else { return }
        let parent = records[Int(id)].parent
        if parent >= 0, var siblings = children[parent], let i = siblings.firstIndex(of: id) {
            siblings.remove(at: i)
            children[parent] = siblings
        }
        markDeleted(id)
    }

    /// Flags a subtree deleted without touching the parent's child list.
    private func markDeleted(_ id: Int32) {
        var stack = [id]
        while let cur = stack.popLast() {
            if records[Int(cur)].isDeleted { continue }
            records[Int(cur)].flags |= 2
            deletedCount += 1
            if let kids = children.removeValue(forKey: cur) { stack.append(contentsOf: kids) }
        }
    }

    /// Makes `dir`'s direct children match `entries`. Returns ids of directories that are new
    /// (their contents still need scanning).
    @discardableResult
    public func replaceChildren(of dir: Int32, with entries: [ScannedEntry]) -> [Int32] {
        var existing: [String: Int32] = [:]
        for kid in children[dir] ?? [] { existing[name(of: kid)] = kid }
        // Build the new child list once; removing ids one at a time from the parent's list
        // would be quadratic when a big folder is emptied.
        var kept: [Int32] = []
        var added: [(ScannedEntry)] = []
        for entry in entries {
            if let id = existing.removeValue(forKey: entry.name) {
                if records[Int(id)].isDirectory == entry.isDirectory {
                    records[Int(id)].size = entry.size
                    records[Int(id)].modified = entry.modified
                    kept.append(id)
                    continue
                }
                markDeleted(id)
            }
            added.append(entry)
        }
        for (_, gone) in existing { markDeleted(gone) }
        children[dir] = kept
        var newDirs: [Int32] = []
        for entry in added {
            let id = add(entry, parent: dir) // appends to children[dir]
            if entry.isDirectory { newDirs.append(id) }
        }
        if children[dir]?.isEmpty == true { children[dir] = nil }
        return newDirs
    }

    // MARK: - Ordering

    func lowerBytesLess(_ a: Int32, _ b: Int32) -> Bool {
        let ra = records[Int(a)], rb = records[Int(b)]
        let sa = Int(ra.lowerStart), sb = Int(rb.lowerStart)
        let la = Int(ra.lowerLength), lb = Int(rb.lowerLength)
        let n = min(la, lb)
        var i = 0
        while i < n {
            let x = lowerNames[sa + i], y = lowerNames[sb + i]
            if x != y { return x < y }
            i += 1
        }
        if la != lb { return la < lb }
        return a < b
    }

    /// Folds `unsorted` into `order` and drops deleted ids.
    public func sortIfNeeded(force: Bool = false) {
        guard force || needsSort else { return }
        install(order: computedOrder())
    }

    public var needsSort: Bool { !unsorted.isEmpty || order.count != liveCount }

    /// The live ids in name order. Reads only, so it can run under a shared lock; install the
    /// result with `install(order:)` before anything else changes the index.
    public func computedOrder() -> [Int32] {
        var all = order.filter { !records[Int($0)].isDeleted }
        all.append(contentsOf: unsorted.filter { !records[Int($0)].isDeleted })
        all.sort(by: lowerBytesLess)
        return all
    }

    public func install(order newOrder: [Int32]) {
        order = newOrder
        unsorted = []
        rebuildRank()
    }

    func rebuildRank() {
        var r = [Int32](repeating: -1, count: records.count)
        for (i, id) in order.enumerated() { r[Int(id)] = Int32(i) }
        rank = r
    }

    /// Takes over another index's contents, so holders of this instance see the new data.
    public func adopt(_ other: FileIndex) {
        tempMaskLock.lock()
        tempMaskCache = nil
        tempMaskLock.unlock()
        kindLock.lock()
        kindCache = nil
        kindLock.unlock()
        records = other.records
        names = other.names
        lowerNames = other.lowerNames
        children = other.children
        order = other.order
        unsorted = other.unsorted
        rank = other.rank
        rootIdList = other.rootIdList
        deletedCount = other.deletedCount
        volumeState = other.volumeState
    }

    /// Returns a copy without deleted records. Ids change.
    public func compacted() -> FileIndex {
        let out = FileIndex()
        out.volumeState = volumeState
        var map: [Int32: Int32] = [:]
        // Parents always precede children because records are appended after their parent.
        for (i, r) in records.enumerated() where !r.isDeleted {
            let parent: Int32 = r.parent >= 0 ? (map[r.parent] ?? -2) : -1
            if parent == -2 { continue }
            let ns = Int(r.nameStart), ls = Int(r.lowerStart)
            let newId = out.appendRaw(bytes: names[ns..<ns + Int(r.nameLength)],
                                      lower: lowerNames[ls..<ls + Int(r.lowerLength)], parent: parent,
                                      isDirectory: r.isDirectory, size: r.size, modified: r.modified)
            map[Int32(i)] = newId
        }
        out.sortIfNeeded(force: true)
        return out
    }
}

/// Reader-writer lock around a `FileIndex`.
public final class SharedIndex {
    private var index: FileIndex
    private let queue = DispatchQueue(label: "MacEverything.index", attributes: .concurrent)

    public init(_ index: FileIndex = FileIndex()) { self.index = index }

    public func read<T>(_ body: (FileIndex) throws -> T) rethrows -> T {
        try queue.sync { try body(index) }
    }

    public func write<T>(_ body: (FileIndex) throws -> T) rethrows -> T {
        try queue.sync(flags: .barrier) { try body(index) }
    }

    public func replace(with newIndex: FileIndex) {
        queue.sync(flags: .barrier) { index = newIndex }
    }
}
