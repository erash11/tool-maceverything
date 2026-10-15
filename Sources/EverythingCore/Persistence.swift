import Foundation

public enum IndexFileError: Error, CustomStringConvertible {
    case badHeader, versionMismatch(UInt32), truncated

    public var description: String {
        switch self {
        case .badHeader: return "not a MacEverything index file"
        case .versionMismatch(let v): return "index file version \(v) is not supported; it will be rebuilt"
        case .truncated: return "index file is truncated"
        }
    }
}

extension FileIndex {
    static let magic: UInt32 = 0x5856_454D // "MEVX" little-endian
    static let fileVersion: UInt32 = 1

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
        put(UInt32(MemoryLayout<Record>.stride))
        put(UInt64(c.records.count))
        put(UInt64(c.names.count))
        put(UInt64(c.lowerNames.count))
        put(UInt64(c.order.count))
        put(UInt64(meta.count))
        data.append(meta)
        c.records.withUnsafeBytes { data.append(contentsOf: $0) }
        data.append(contentsOf: c.names)
        data.append(contentsOf: c.lowerNames)
        c.order.withUnsafeBytes { data.append(contentsOf: $0) }
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
        guard try get(UInt32.self) == UInt32(MemoryLayout<Record>.stride) else {
            throw IndexFileError.versionMismatch(version)
        }
        let recordCount = Int(try get(UInt64.self))
        let nameCount = Int(try get(UInt64.self))
        let lowerCount = Int(try get(UInt64.self))
        let orderCount = Int(try get(UInt64.self))
        let metaCount = Int(try get(UInt64.self))

        func take(_ n: Int) throws -> Data {
            guard pos + n <= data.count else { throw IndexFileError.truncated }
            defer { pos += n }
            return data.subdata(in: pos..<pos + n)
        }
        let index = FileIndex()
        index.volumeState = try JSONDecoder().decode([String: VolumeState].self, from: take(metaCount))
        let recordBytes = try take(recordCount * MemoryLayout<Record>.stride)
        index.records = [Record](unsafeUninitializedCapacity: recordCount) { buf, count in
            _ = recordBytes.copyBytes(to: UnsafeMutableRawBufferPointer(buf))
            count = recordCount
        }
        index.names = [UInt8](try take(nameCount))
        index.lowerNames = [UInt8](try take(lowerCount))
        let orderBytes = try take(orderCount * MemoryLayout<Int32>.stride)
        index.order = [Int32](unsafeUninitializedCapacity: orderCount) { buf, count in
            _ = orderBytes.copyBytes(to: UnsafeMutableRawBufferPointer(buf))
            count = orderCount
        }
        var children: [Int32: [Int32]] = [:]
        for (i, r) in index.records.enumerated() where r.parent >= 0 && !r.isDeleted {
            children[r.parent, default: []].append(Int32(i))
        }
        index.children = children
        index.rebuildRank()
        return index
    }
}
