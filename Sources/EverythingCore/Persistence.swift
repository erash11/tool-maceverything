import Foundation

public enum IndexFileError: Error, CustomStringConvertible {
    case badHeader, versionMismatch(UInt32), truncated, corrupt(String)

    public var description: String {
        switch self {
        case .badHeader: return "not a MacEverything index file"
        case .versionMismatch(let v): return "index file version \(v) is not supported; it will be rebuilt"
        case .truncated: return "index file is truncated"
        case .corrupt(let why): return "index file is corrupt: \(why)"
        }
    }
}

extension FileIndex {
    static let magic: UInt32 = 0x5856_454D // "MEVX" little-endian
    static let fileVersion: UInt32 = 2
    /// Bytes per record on disk: parent, nameStart, nameLength, lowerStart, lowerLength,
    /// flags, size, modified, written field by field so struct padding never reaches disk.
    static let recordBytes = 4 + 4 + 2 + 4 + 2 + 1 + 8 + 8

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MacEverything", isDirectory: true)
    }

    public static var defaultIndexURL: URL { defaultDirectory.appendingPathComponent("index.bin") }

    /// Writes a compacted copy atomically. Deleted records are dropped.
    public func save(to url: URL) throws {
        let c = deletedCount > 0 || !unsorted.isEmpty ? compacted() : self
        let meta = try JSONEncoder().encode(c.volumeState)
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        put(Self.magic)
        put(Self.fileVersion)
        put(UInt32(Self.recordBytes))
        put(UInt64(c.records.count))
        put(UInt64(c.names.count))
        put(UInt64(c.lowerNames.count))
        put(UInt64(c.order.count))
        put(UInt64(meta.count))
        data.append(meta)
        data.reserveCapacity(data.count + c.records.count * Self.recordBytes + c.names.count * 2 + c.order.count * 4)
        for r in c.records {
            put(r.parent); put(r.nameStart); put(r.nameLength); put(r.lowerStart); put(r.lowerLength)
            put(r.flags); put(r.size); put(r.modified)
        }
        data.append(contentsOf: c.names)
        data.append(contentsOf: c.lowerNames)
        for id in c.order { put(id) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> FileIndex {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var pos = 0
        func get<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let n = MemoryLayout<T>.size
            guard pos + n <= data.count else { throw IndexFileError.truncated }
            var v: T = 0
            _ = withUnsafeMutableBytes(of: &v) { data.copyBytes(to: $0, from: pos..<pos + n) }
            pos += n
            return T(littleEndian: v)
        }
        guard try get(UInt32.self) == magic else { throw IndexFileError.badHeader }
        let version = try get(UInt32.self)
        guard version == fileVersion else { throw IndexFileError.versionMismatch(version) }
        guard try get(UInt32.self) == UInt32(recordBytes) else { throw IndexFileError.versionMismatch(version) }
        func count() throws -> Int {
            guard let n = Int(exactly: try get(UInt64.self)), n <= data.count * 2 else {
                throw IndexFileError.corrupt("section count out of range")
            }
            return n
        }
        let recordCount = try count()
        let nameCount = try count()
        let lowerCount = try count()
        let orderCount = try count()
        let metaCount = try count()

        func take(_ n: Int) throws -> Data {
            guard n >= 0, n <= data.count - pos else { throw IndexFileError.truncated }
            defer { pos += n }
            return data.subdata(in: pos..<pos + n)
        }
        let index = FileIndex()
        index.volumeState = try JSONDecoder().decode([String: VolumeState].self, from: take(metaCount))
        func sized(_ count: Int, _ width: Int) throws -> Int {
            let (n, overflow) = count.multipliedReportingOverflow(by: width)
            guard !overflow, count >= 0 else { throw IndexFileError.corrupt("section size overflows") }
            return n
        }
        let recordData = try take(sized(recordCount, recordBytes))
        index.names = [UInt8](try take(nameCount))
        index.lowerNames = [UInt8](try take(lowerCount))
        let orderData = try take(sized(orderCount, 4))
        guard pos == data.count else { throw IndexFileError.corrupt("trailing bytes") }

        var records: [Record] = []
        records.reserveCapacity(recordCount)
        try recordData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<recordCount {
                let o = i * recordBytes
                let r = Record(
                    parent: Int32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: Int32.self)),
                    nameStart: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o + 4, as: UInt32.self)),
                    nameLength: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: o + 8, as: UInt16.self)),
                    lowerStart: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o + 10, as: UInt32.self)),
                    lowerLength: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: o + 14, as: UInt16.self)),
                    flags: raw[o + 16],
                    size: Int64(littleEndian: raw.loadUnaligned(fromByteOffset: o + 17, as: Int64.self)),
                    modified: Int64(littleEndian: raw.loadUnaligned(fromByteOffset: o + 25, as: Int64.self)))
                // Parents are written before their children, so a valid parent is a lower id.
                guard r.parent == -1 || (r.parent >= 0 && Int(r.parent) < i) else {
                    throw IndexFileError.corrupt("record \(i) has parent \(r.parent)")
                }
                guard Int(r.nameStart) + Int(r.nameLength) <= nameCount,
                      Int(r.lowerStart) + Int(r.lowerLength) <= lowerCount else {
                    throw IndexFileError.corrupt("record \(i) name is out of range")
                }
                records.append(r)
            }
        }
        index.records = records
        var order: [Int32] = []
        order.reserveCapacity(orderCount)
        var seen = [Bool](repeating: false, count: recordCount)
        try orderData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<orderCount {
                let id = Int32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: Int32.self))
                guard id >= 0, Int(id) < recordCount, !seen[Int(id)] else {
                    throw IndexFileError.corrupt("sort order entry \(i) is invalid")
                }
                seen[Int(id)] = true
                order.append(id)
            }
        }
        index.order = order
        index.deletedCount = records.reduce(0) { $0 + ($1.isDeleted ? 1 : 0) }
        var children: [Int32: [Int32]] = [:]
        for (i, r) in index.records.enumerated() where r.parent >= 0 && !r.isDeleted {
            children[r.parent, default: []].append(Int32(i))
        }
        index.children = children
        index.rootIdList = records.indices.filter { records[$0].parent < 0 }.map { Int32($0) }
        index.rebuildRank()
        return index
    }
}
