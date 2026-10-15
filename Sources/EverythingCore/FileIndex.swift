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
    public internal(set) var deletedCount = 0

    /// Saved FSEvents state per root path.
    public var volumeState: [String: VolumeState] = [:]

    public struct VolumeState: Codable, Equatable {
        public var volumeUUID: String
        public var lastEventId: UInt64
        public init(volumeUUID: String, lastEventId: UInt64) {
            self.volumeUUID = volumeUUID
            self.lastEventId = lastEventId
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

    public var roots: [Int32] {
        var out: [Int32] = []
        for (i, r) in records.enumerated() where r.parent < 0 && !r.isDeleted {
            out.append(Int32(i))
        }
        return out
    }

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
        let id = Int32(records.count)
        var bytes = Array(name.utf8)
        if bytes.count > Int(UInt16.max) { bytes = Array(bytes.prefix(Int(UInt16.max))) }
        var lower = Array(FileIndex.searchForm(name).utf8)
        if lower.count > Int(UInt16.max) { lower = Array(lower.prefix(Int(UInt16.max))) }
        let record = Record(
            parent: parent,
            nameStart: UInt32(names.count), nameLength: UInt16(bytes.count),
            lowerStart: UInt32(lowerNames.count), lowerLength: UInt16(lower.count),
            flags: isDirectory ? 1 : 0, size: size, modified: modified)
        names.append(contentsOf: bytes)
        lowerNames.append(contentsOf: lower)
        records.append(record)
        if parent >= 0 { children[parent, default: []].append(id) }
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
        var stack = [id]
        while let cur = stack.popLast() {
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
        var newDirs: [Int32] = []
        for entry in entries {
            if let id = existing.removeValue(forKey: entry.name) {
                let old = records[Int(id)]
                if old.isDirectory == entry.isDirectory {
                    records[Int(id)].size = entry.size
                    records[Int(id)].modified = entry.modified
                    continue
                }
                remove(id)
            }
            let id = add(entry, parent: dir)
            if entry.isDirectory { newDirs.append(id) }
        }
        for (_, gone) in existing { remove(gone) }
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
        guard force || !unsorted.isEmpty || order.count != liveCount else { return }
        var all = order.filter { !records[Int($0)].isDeleted }
        all.append(contentsOf: unsorted.filter { !records[Int($0)].isDeleted })
        all.sort(by: lowerBytesLess)
        order = all
        unsorted = []
    }

    /// Takes over another index's contents, so holders of this instance see the new data.
    public func adopt(_ other: FileIndex) {
        records = other.records
        names = other.names
        lowerNames = other.lowerNames
        children = other.children
        order = other.order
        unsorted = other.unsorted
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
            let newId = out.append(name: name(of: Int32(i)), parent: parent,
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
