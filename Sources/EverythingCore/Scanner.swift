import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Lists directories and walks trees into a `FileIndex`.
public struct Scanner {
    /// Paths never descended into. Other volumes get their own roots; these are system mounts
    /// that either duplicate the boot volume (firmlinks) or hold nothing a person searches for.
    public static let defaultExclusions: Set<String> = [
        "/System/Volumes", "/Volumes", "/dev", "/private/var/vm", "/private/var/db/uuidtext",
        "/.vol", "/net", "/home", "/cores", "/.Spotlight-V100", "/.fseventsd", "/.DocumentRevisions-V100",
    ]

    public var exclusions: Set<String>
    public var useBulk: Bool

    public init(exclusions: Set<String> = Scanner.defaultExclusions, useBulk: Bool = true) {
        self.exclusions = exclusions
        self.useBulk = useBulk
    }

    /// Lists one directory's direct children. Returns nil if it cannot be opened.
    public func list(_ path: String) -> [ScannedEntry]? {
        #if canImport(Darwin)
        if useBulk { return Scanner.listBulk(path) }
        #endif
        return Scanner.listFoundation(path)
    }

    public static func listFoundation(_ path: String) -> [ScannedEntry]? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return nil }
        var out: [ScannedEntry] = []
        out.reserveCapacity(names.count)
        for name in names {
            let full = path.hasSuffix("/") ? path + name : path + "/" + name
            var st = stat()
            guard lstat(full, &st) == 0 else { continue }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            #if canImport(Darwin)
            let mtime = Int64(st.st_mtimespec.tv_sec)
            #else
            let mtime = Int64(st.st_mtim.tv_sec)
            #endif
            out.append(ScannedEntry(name: name, isDirectory: isDir, size: isDir ? 0 : Int64(st.st_size), modified: mtime))
        }
        return out
    }

    #if canImport(Darwin)
    // Attribute bits from <sys/attr.h>, spelled as UInt32 to avoid import-type surprises.
    static let cmnName: UInt32 = 0x0000_0001
    static let cmnObjType: UInt32 = 0x0000_0008
    static let cmnModTime: UInt32 = 0x0000_0400
    static let cmnError: UInt32 = 0x2000_0000
    static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    static let fileDataLength: UInt32 = 0x0000_0200
    static let vDir: UInt32 = 2

    /// Lists a directory with getattrlistbulk(2): one system call returns many entries with
    /// name, type, modification time and size, instead of a stat() per file.
    public static func listBulk(_ path: String) -> [ScannedEntry]? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd < 0 { return nil }
        defer { close(fd) }

        var attrs = attrlist()
        attrs.bitmapcount = 5 // ATTR_BIT_MAP_COUNT
        attrs.commonattr = cmnReturnedAttrs | cmnName | cmnError | cmnObjType | cmnModTime
        attrs.fileattr = fileDataLength

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var out: [ScannedEntry] = []
        while true {
            let count = withUnsafeMutablePointer(to: &attrs) { ptr in
                getattrlistbulk(fd, ptr, buffer, bufferSize, 0)
            }
            // A failure after some entries means the listing is incomplete. Callers treat a
            // listing as the whole folder, so a partial one would delete the missing entries.
            if count < 0 { return nil }
            if count == 0 { break }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<Int(count) {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var field = entry + 4
                // attribute_set_t: commonattr, volattr, dirattr, fileattr, forkattr
                let returnedCommon = field.loadUnaligned(as: UInt32.self)
                let returnedFile = field.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
                field += 20

                var failed = false
                if returnedCommon & cmnError != 0 {
                    failed = field.loadUnaligned(as: UInt32.self) != 0
                    field += 4
                }
                var name = ""
                if returnedCommon & cmnName != 0 {
                    let offset = Int(field.loadUnaligned(as: Int32.self))
                    let nameLength = Int(field.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                    let namePtr = (field + offset).assumingMemoryBound(to: UInt8.self)
                    // Length includes the trailing NUL.
                    name = String(decoding: UnsafeBufferPointer(start: namePtr, count: max(nameLength - 1, 0)), as: UTF8.self)
                    field += 8
                }
                var objType: UInt32 = 0
                if returnedCommon & cmnObjType != 0 {
                    objType = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var mtime: Int64 = 0
                if returnedCommon & cmnModTime != 0 {
                    mtime = Int64(field.loadUnaligned(as: Int.self)) // timespec.tv_sec
                    field += MemoryLayout<timespec>.size
                }
                var size: Int64 = 0
                if returnedFile & fileDataLength != 0 {
                    size = field.loadUnaligned(as: Int64.self)
                    field += 8
                }
                if !failed && !name.isEmpty {
                    let isDir = objType == vDir
                    out.append(ScannedEntry(name: name, isDirectory: isDir, size: isDir ? 0 : size, modified: mtime))
                }
                entry += length
            }
        }
        return out
    }
    #endif

    public struct Stats {
        public var entries = 0
        public var directories = 0
        public var unreadable = 0
        public var seconds = 0.0
        /// Folders whose listing took longest (over 0.5 s), slowest first, at most 10.
        public var slowest: [(path: String, seconds: Double)] = []
    }

    /// Walks everything under `root` (already in the index) level by level. Each level's
    /// directories are listed in parallel; the index is only written from this thread.
    @discardableResult
    public func scanTree(into index: FileIndex, root: Int32, rootPath: String,
                         progress: ((Int) -> Void)? = nil) -> Stats {
        let started = Date()
        var stats = Stats()
        var level: [(path: String, id: Int32)] = [(rootPath, root)]
        while !level.isEmpty {
            var results = [[ScannedEntry]?](repeating: nil, count: level.count)
            let lock = NSLock()
            let current = level
            var slow: [(String, Double)] = []
            let listedBefore = stats.entries
            var listedNow = 0
            DispatchQueue.concurrentPerform(iterations: current.count) { i in
                let t0 = DispatchTime.now().uptimeNanoseconds
                let listed = list(current[i].path)
                let took = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
                lock.lock()
                if took > 0.5 {
                    slow.append((current[i].path, took))
                }
                results[i] = listed
                listedNow += listed?.count ?? 0
                let soFar = listedBefore + listedNow
                lock.unlock()
                // Report as folders are listed, not once per tree level: a level can hold
                // hundreds of thousands of folders and take many seconds.
                progress?(soFar)
            }
            var next: [(path: String, id: Int32)] = []
            for (i, dir) in current.enumerated() {
                guard let entries = results[i] else {
                    stats.unreadable += 1
                    continue
                }
                stats.directories += 1
                for entry in entries {
                    let id = index.add(entry, parent: dir.id)
                    stats.entries += 1
                    if entry.isDirectory {
                        let childPath = dir.path == "/" ? "/" + entry.name : dir.path + "/" + entry.name
                        if !exclusions.contains(childPath) { next.append((childPath, id)) }
                    }
                }
            }
            if !slow.isEmpty {
                stats.slowest = (stats.slowest + slow.map { (path: $0.0, seconds: $0.1) })
                    .sorted { $0.seconds > $1.seconds }
                    .prefix(10).map { $0 }
            }
            level = next
        }
        stats.seconds = Date().timeIntervalSince(started)
        return stats
    }

    /// Re-lists `dir` and, when `recursive`, every directory below it. New directories are
    /// always walked, since a folder moved in arrives with its contents. Returns false when a
    /// folder that still exists could not be read, so the caller can retry instead of
    /// treating the change as applied.
    @discardableResult
    public func refresh(_ index: FileIndex, dir: Int32, path: String, recursive: Bool) -> Bool {
        refresh(SharedIndex(index), dir: dir, path: path, recursive: recursive)
    }

    /// Lists each folder from disk without holding the index lock, then takes the write lock
    /// only to apply that one folder, so searches keep running during big rescans. The caller
    /// must be the index's only writer for the duration (record ids must stay stable).
    @discardableResult
    public func refresh(_ shared: SharedIndex, dir: Int32, path: String, recursive: Bool) -> Bool {
        var complete = true
        var queue: [(String, Int32, Bool)] = [(path, dir, recursive)]
        while let (p, id, deep) = queue.popLast() {
            let entries = list(p)
            let gone = entries == nil && !FileManager.default.fileExists(atPath: p)
            let next: [(String, Int32, Bool)] = shared.write { index in
                if index.records[Int(id)].isDeleted { return [] }
                guard let entries else {
                    if !gone {
                        complete = false
                    } else if index.records[Int(id)].parent >= 0 {
                        index.remove(id)
                    } else {
                        // A root that disappeared keeps its record but loses everything under it.
                        index.replaceChildren(of: id, with: [])
                    }
                    return []
                }
                let newDirs = Set(index.replaceChildren(of: id, with: entries))
                var out: [(String, Int32, Bool)] = []
                for kid in index.childIds(of: id) where index.records[Int(kid)].isDirectory {
                    guard deep || newDirs.contains(kid) else { continue }
                    let kidPath = p == "/" ? "/" + index.name(of: kid) : p + "/" + index.name(of: kid)
                    if exclusions.contains(kidPath) { continue }
                    out.append((kidPath, kid, true))
                }
                return out
            }
            queue.append(contentsOf: next)
        }
        return complete
    }
}
