#if canImport(Darwin)
import Darwin
import Foundation

/// Reads a volume's whole catalog with searchfs(2), the way Find Any File does, instead of
/// walking folders. searchfs searches an entire volume (the path only picks the volume) and
/// returns each object's id and parent id, so the tree is rebuilt from ids afterwards.
///
/// The struct layouts below are written out by hand from <sys/attr.h> and the function is
/// looked up at run time, so a mismatch shows up as an error result, not a build failure.
public enum SearchFS {
    public struct Entry {
        public var id: UInt64
        public var parent: UInt64
        public var name: String
        public var isDirectory: Bool
        public var size: Int64
        public var modified: Int64
    }

    public struct Result {
        public var entries: [Entry] = []
        public var calls = 0
        public var restarts = 0
        public var error: String?
        public var seconds = 0.0
    }

    // <sys/attr.h> bits and options.
    static let cmnName: UInt32 = 0x0000_0001
    static let cmnObjType: UInt32 = 0x0000_0008
    static let cmnModTime: UInt32 = 0x0000_0400
    static let cmnFileId: UInt32 = 0x0200_0000
    static let cmnParentId: UInt32 = 0x0400_0000
    static let fileDataLength: UInt32 = 0x0000_0200
    static let srchfsStart: UInt32 = 0x0000_0001
    static let srchfsMatchPartialNames: UInt32 = 0x0000_0002
    static let srchfsMatchDirs: UInt32 = 0x0000_0004
    static let srchfsMatchFiles: UInt32 = 0x0000_0008
    static let srchfsNegateParams: UInt32 = 0x8000_0000
    static let scriptCodeUTF8: UInt32 = 0x0800_0100

    typealias SearchFn = @convention(c) (UnsafePointer<CChar>, UnsafeMutableRawPointer, UnsafeMutablePointer<UInt>,
                                         UInt32, UInt32, UnsafeMutableRawPointer) -> Int32

    static let searchfsFn: SearchFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "searchfs") else { return nil } // RTLD_DEFAULT
        return unsafeBitCast(sym, to: SearchFn.self)
    }()

    /// Lists every file and folder on the volume holding `volumePath`.
    public static func listVolume(_ volumePath: String, includeSizes: Bool = true) -> Result {
        let started = Date()
        var result = run(volumePath, includeSizes: includeSizes)
        if result.error != nil && includeSizes {
            // Some file systems reject file attributes in a search that also matches folders.
            let retry = run(volumePath, includeSizes: false)
            if retry.error == nil { result = retry } else { result.error! += "; without sizes: " + retry.error! }
        }
        result.seconds = Date().timeIntervalSince(started)
        return result
    }

    private static func run(_ volumePath: String, includeSizes: Bool) -> Result {
        var result = Result()
        guard let searchfs = searchfsFn else {
            result.error = "searchfs is not available"
            return result
        }
        // Attributes to return for each match.
        var returnAttrs = attrlist()
        returnAttrs.bitmapcount = 5
        returnAttrs.commonattr = cmnName | cmnObjType | cmnModTime | cmnFileId | cmnParentId
        returnAttrs.fileattr = includeSizes ? fileDataLength : 0

        // Search on the name: everything whose name does NOT contain a string no real name has.
        let impossible = Array("\u{1}\u{2}mev-no-such-name\u{3}".utf8) + [0]
        let paramsSize = 4 + 8 + impossible.count
        let params = UnsafeMutableRawPointer.allocate(byteCount: paramsSize, alignment: 8)
        defer { params.deallocate() }
        params.storeBytes(of: UInt32(paramsSize), as: UInt32.self)          // size
        params.storeBytes(of: Int32(8), toByteOffset: 4, as: Int32.self)      // attr_dataoffset
        params.storeBytes(of: UInt32(impossible.count), toByteOffset: 8, as: UInt32.self) // attr_length
        impossible.withUnsafeBytes { params.advanced(by: 12).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }

        let bufferSize = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        // struct searchstate is 556 opaque bytes; give it room.
        let state = UnsafeMutableRawPointer.allocate(byteCount: 1024, alignment: 16)
        defer { state.deallocate() }
        state.initializeMemory(as: UInt8.self, repeating: 0, count: 1024)

        // struct fssearchblock, 64-bit layout:
        //   0 returnattrs*  8 returnbuffer*  16 returnbuffersize  24 maxmatches
        //   32 timelimit (timeval, 16)  48 searchparams1*  56 sizeofsearchparams1
        //   64 searchparams2*  72 sizeofsearchparams2  80 searchattrs (attrlist, 24)
        let block = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 16)
        defer { block.deallocate() }
        block.initializeMemory(as: UInt8.self, repeating: 0, count: 128)

        return withUnsafeMutablePointer(to: &returnAttrs) { attrsPtr -> Result in
            block.storeBytes(of: UnsafeMutableRawPointer(attrsPtr), toByteOffset: 0, as: UnsafeMutableRawPointer.self)
            block.storeBytes(of: buffer, toByteOffset: 8, as: UnsafeMutableRawPointer.self)
            block.storeBytes(of: bufferSize, toByteOffset: 16, as: Int.self)
            block.storeBytes(of: UInt(1 << 14), toByteOffset: 24, as: UInt.self)
            block.storeBytes(of: Int(1), toByteOffset: 32, as: Int.self)       // timelimit 1 s per call
            block.storeBytes(of: Int32(0), toByteOffset: 40, as: Int32.self)
            block.storeBytes(of: params, toByteOffset: 48, as: UnsafeMutableRawPointer.self)
            block.storeBytes(of: paramsSize, toByteOffset: 56, as: Int.self)
            block.storeBytes(of: params, toByteOffset: 64, as: UnsafeMutableRawPointer.self)
            block.storeBytes(of: paramsSize, toByteOffset: 72, as: Int.self)
            var searchAttrs = attrlist()
            searchAttrs.bitmapcount = 5
            searchAttrs.commonattr = cmnName
            block.storeBytes(of: searchAttrs, toByteOffset: 80, as: attrlist.self)

            var options = srchfsStart | srchfsMatchPartialNames | srchfsMatchDirs | srchfsMatchFiles | srchfsNegateParams
            var out = Result()
            while true {
                var matches: UInt = 0
                let rc = volumePath.withCString { searchfs($0, block, &matches, scriptCodeUTF8, options, state) }
                let err = rc == 0 ? 0 : errno
                out.calls += 1
                if rc != 0 && err != EAGAIN {
                    if err == EBUSY && out.restarts < 3 {
                        // The catalog changed under the search: start over.
                        out.entries.removeAll()
                        out.restarts += 1
                        options |= srchfsStart
                        continue
                    }
                    out.error = "searchfs failed: \(String(cString: strerror(err))) (errno \(err))"
                    return out
                }
                parse(buffer, count: Int(matches), includeSizes: includeSizes, into: &out.entries)
                if rc == 0 { return out }
                options &= ~srchfsStart
            }
        }
    }

    /// Each match: u_int32 length, then the requested attributes in bit order.
    private static func parse(_ buffer: UnsafeMutableRawPointer, count: Int, includeSizes: Bool,
                              into entries: inout [Entry]) {
        var entry = UnsafeRawPointer(buffer)
        for _ in 0..<count {
            let length = Int(entry.loadUnaligned(as: UInt32.self))
            let end = entry + length
            var field = entry + 4
            let nameOffset = Int(field.loadUnaligned(as: Int32.self))
            let nameLength = Int(field.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            let namePtr = (field + nameOffset).assumingMemoryBound(to: UInt8.self)
            let name = String(decoding: UnsafeBufferPointer(start: namePtr, count: max(nameLength - 1, 0)), as: UTF8.self)
            field += 8
            let objType = field.loadUnaligned(as: UInt32.self)
            field += 4
            let mtime = Int64(field.loadUnaligned(as: Int.self))
            field += MemoryLayout<timespec>.size
            let id = field.loadUnaligned(as: UInt64.self)
            field += 8
            let parent = field.loadUnaligned(as: UInt64.self)
            field += 8
            var size: Int64 = 0
            let isDir = objType == 2
            if includeSizes && !isDir && end - field >= 8 { size = field.loadUnaligned(as: Int64.self) }
            entries.append(Entry(id: id, parent: parent, name: name, isDirectory: isDir, size: size, modified: mtime))
            entry = end
        }
    }

    public struct TreeStats {
        public var added = 0
        public var unreachable = 0
    }

    /// Adds the entries reachable from the volume root (by parent id) under `root`.
    /// Parents are added before children, as the index requires.
    @discardableResult
    public static func buildTree(_ entries: [Entry], volumePath: String, into index: FileIndex, root: Int32) -> TreeStats {
        var st = stat()
        guard lstat(volumePath, &st) == 0 else { return TreeStats(added: 0, unreachable: entries.count) }
        var byParent: [UInt64: [Int]] = [:]
        for (i, e) in entries.enumerated() where e.id != e.parent { byParent[e.parent, default: []].append(i) }
        var stats = TreeStats()
        var queue: [(UInt64, Int32)] = [(UInt64(st.st_ino), root)]
        var head = 0
        while head < queue.count {
            let (dirId, recordId) = queue[head]
            head += 1
            for i in byParent[dirId] ?? [] {
                let e = entries[i]
                let id = index.add(ScannedEntry(name: e.name, isDirectory: e.isDirectory, size: e.size,
                                                modified: e.modified), parent: recordId)
                stats.added += 1
                if e.isDirectory { queue.append((e.id, id)) }
            }
        }
        stats.unreachable = entries.count - stats.added
        return stats
    }
}
#endif
