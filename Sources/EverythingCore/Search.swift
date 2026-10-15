import Foundation

public enum SortKey: String, Codable {
    case name, path, size, modified
}

public struct SearchOptions {
    public var limit: Int
    public var offset: Int
    public var sort: SortKey
    public var descending: Bool

    public init(limit: Int = 100, offset: Int = 0, sort: SortKey = .name, descending: Bool = false) {
        self.limit = limit
        self.offset = offset
        self.sort = sort
        self.descending = descending
    }
}

public struct SearchHit: Codable, Equatable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Int64
}

public struct SearchResult: Codable {
    public var total: Int
    public var hits: [SearchHit]
    public var milliseconds: Double
}

// MARK: - Compiled query

/// A query flattened into plain values, so the per-record loop does no reference counting.
struct CompiledQuery {
    struct Term {
        var kind: UInt8      // see Kind
        var negated: Bool
        var start: Int       // byte offset into `bytes`, slot index (ext) or regex index
        var length: Int      // byte length, or slot count (ext)
        var cmp: UInt8
        var a: Int64
        var b: Int64
    }

    enum Kind {
        static let contains: UInt8 = 0, path: UInt8 = 1, glob: UInt8 = 2, regex: UInt8 = 3, ext: UInt8 = 4
        static let size: UInt8 = 5, modified: UInt8 = 6, files: UInt8 = 7, folders: UInt8 = 8
    }

    var terms: [Term] = []
    var groupStart: [Int] = []
    var groupCount: [Int] = []
    var bytes: [UInt8] = []
    var slotStart: [Int] = []
    var slotLength: [Int] = []
    var regexes: [NSRegularExpression?] = []
    var needsPath = false

    init(_ query: Query) {
        for group in query.groups {
            groupStart.append(terms.count)
            groupCount.append(group.count)
            for term in group { terms.append(compile(term)) }
        }
    }

    private mutating func addBytes(_ b: [UInt8]) -> Int {
        let start = bytes.count
        bytes.append(contentsOf: b)
        return start
    }

    private static func cmpCode(_ c: Query.Comparison) -> UInt8 {
        switch c {
        case .less: return 0
        case .lessOrEqual: return 1
        case .greater: return 2
        case .greaterOrEqual: return 3
        case .equal: return 4
        }
    }

    private mutating func compile(_ term: Query.Term) -> Term {
        var t = Term(kind: 0, negated: false, start: 0, length: 0, cmp: 0, a: 0, b: 0)
        switch term {
        case let .contains(n, neg):
            t.kind = Kind.contains; t.negated = neg; t.start = addBytes(n); t.length = n.count
        case let .pathContains(n, neg):
            t.kind = Kind.path; t.negated = neg; t.start = addBytes(n); t.length = n.count
            needsPath = true
        case let .glob(n, neg):
            t.kind = Kind.glob; t.negated = neg; t.start = addBytes(n); t.length = n.count
        case let .regex(pattern, neg):
            t.kind = Kind.regex; t.negated = neg; t.start = regexes.count
            regexes.append(try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
        case let .ext(list, neg):
            t.kind = Kind.ext; t.negated = neg; t.start = slotStart.count; t.length = list.count
            for suffix in list {
                slotStart.append(addBytes(suffix))
                slotLength.append(suffix.count)
            }
        case let .size(cmp, value):
            t.kind = Kind.size; t.cmp = CompiledQuery.cmpCode(cmp); t.a = value
        case let .modified(cmp, start, end):
            t.kind = Kind.modified; t.cmp = CompiledQuery.cmpCode(cmp); t.a = start; t.b = end
        case .filesOnly:
            t.kind = Kind.files
        case .foldersOnly:
            t.kind = Kind.folders
        }
        return t
    }
}

// MARK: - Search

extension FileIndex {
    /// Runs `query` across every live record, split over all CPU cores.
    public func search(_ query: Query, options: SearchOptions = SearchOptions()) -> SearchResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let matched = matchingIdsInIdOrder(query)
        let total = matched.count
        let offset = min(max(options.offset, 0), total)
        let limit = max(options.limit, 0)
        let end = limit >= total - offset ? total : offset + limit

        let page: [Int32]
        switch options.sort {
        case .name:
            page = Array(nameOrdered(matched, first: end, descending: options.descending)[offset..<end])
        case .path:
            let paths = matched.map { path(of: $0).lowercased() }
            var idx = Array(0..<matched.count)
            idx.sort { options.descending ? paths[$0] > paths[$1] : paths[$0] < paths[$1] }
            page = idx[offset..<end].map { matched[$0] }
        case .size, .modified:
            let bySize = options.sort == .size
            var sorted = matched
            sorted.sort {
                let ra = records[Int($0)], rb = records[Int($1)]
                let a = bySize ? ra.size : ra.modified, b = bySize ? rb.size : rb.modified
                return options.descending ? a > b : a < b
            }
            page = Array(sorted[offset..<end])
        }

        let hits = page.map { id -> SearchHit in
            let r = records[Int(id)]
            return SearchHit(path: path(of: id), name: name(of: id), isDirectory: r.isDirectory,
                             size: r.size, modified: r.modified)
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        return SearchResult(total: total, hits: hits, milliseconds: ms)
    }

    /// Ids of live records matching `query`, in name order.
    public func matchingIds(_ query: Query) -> [Int32] {
        let ids = matchingIdsInIdOrder(query)
        return nameOrdered(ids, first: ids.count, descending: false)
    }

    /// The first `first` of `ids` in name order. Uses each id's rank in the presorted `order`
    /// (a bitmap walk, no comparisons) and merges in ids added since the last sort.
    func nameOrdered(_ ids: [Int32], first: Int, descending: Bool) -> [Int32] {
        if first == 0 { return [] }
        var unranked: [Int32] = []
        var bits = [UInt64](repeating: 0, count: (order.count + 63) / 64)
        for id in ids {
            let rk = rank[Int(id)]
            if rk >= 0 {
                bits[Int(rk) >> 6] |= 1 << UInt64(rk & 63)
            } else {
                unranked.append(id)
            }
        }
        var ranked: [Int32] = []
        ranked.reserveCapacity(min(first, ids.count))
        if descending {
            var w = bits.count - 1
            while w >= 0 && ranked.count < first {
                var word = bits[w]
                while word != 0 && ranked.count < first {
                    let bit = 63 - word.leadingZeroBitCount
                    ranked.append(order[w * 64 + bit])
                    word &= ~(UInt64(1) << UInt64(bit))
                }
                w -= 1
            }
        } else {
            var w = 0
            while w < bits.count && ranked.count < first {
                var word = bits[w]
                while word != 0 && ranked.count < first {
                    let bit = word.trailingZeroBitCount
                    ranked.append(order[w * 64 + bit])
                    word &= word - 1
                }
                w += 1
            }
        }
        if unranked.isEmpty { return ranked }
        unranked.sort(by: lowerBytesLess)
        if descending { unranked.reverse() }
        var out: [Int32] = []
        out.reserveCapacity(min(first, ranked.count + unranked.count))
        var i = 0, j = 0
        while out.count < first && (i < ranked.count || j < unranked.count) {
            let takeUnranked: Bool
            if i >= ranked.count {
                takeUnranked = true
            } else if j >= unranked.count {
                takeUnranked = false
            } else {
                takeUnranked = descending ? lowerBytesLess(ranked[i], unranked[j])
                                          : lowerBytesLess(unranked[j], ranked[i])
            }
            if takeUnranked { out.append(unranked[j]); j += 1 } else { out.append(ranked[i]); i += 1 }
        }
        return out
    }

    /// Scans records in memory order (sequential reads), split into chunks across cores.
    func matchingIdsInIdOrder(_ query: Query) -> [Int32] {
        let compiled = CompiledQuery(query)
        let count = records.count
        if count == 0 { return [] }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let chunkCount = max(1, min(cores * 4, (count + 16_383) / 16_384))
        let chunkSize = (count + chunkCount - 1) / chunkCount
        var partial = [[Int32]](repeating: [], count: chunkCount)

        records.withUnsafeBufferPointer { recs in
        lowerNames.withUnsafeBufferPointer { lower in
        compiled.terms.withUnsafeBufferPointer { terms in
        compiled.bytes.withUnsafeBufferPointer { qbytes in
        compiled.slotStart.withUnsafeBufferPointer { slotStart in
        compiled.slotLength.withUnsafeBufferPointer { slotLength in
        compiled.groupStart.withUnsafeBufferPointer { groupStart in
        compiled.groupCount.withUnsafeBufferPointer { groupCount in
        partial.withUnsafeMutableBufferPointer { out in
            let ctx = MatchContext(recs: recs, lower: lower, terms: terms, qbytes: qbytes,
                                   slotStart: slotStart, slotLength: slotLength,
                                   groupStart: groupStart, groupCount: groupCount,
                                   regexes: compiled.regexes)
            DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                let lo = chunk * chunkSize
                let hi = min(lo + chunkSize, count)
                if lo >= hi { return }
                var found: [Int32] = []
                var paths = PathCache()
                for id in lo..<hi {
                    let r = recs[id]
                    if r.flags & 2 != 0 { continue }
                    if ctx.matches(r, paths: &paths) { found.append(Int32(id)) }
                }
                out[chunk] = found
            }
        }}}}}}}}}
        return partial.flatMap { $0 }
    }
}

/// Everything the per-record test reads, as unsafe buffers.
struct MatchContext {
    let recs: UnsafeBufferPointer<Record>
    let lower: UnsafeBufferPointer<UInt8>
    let terms: UnsafeBufferPointer<CompiledQuery.Term>
    let qbytes: UnsafeBufferPointer<UInt8>
    let slotStart: UnsafeBufferPointer<Int>
    let slotLength: UnsafeBufferPointer<Int>
    let groupStart: UnsafeBufferPointer<Int>
    let groupCount: UnsafeBufferPointer<Int>
    let regexes: [NSRegularExpression?]

    @inline(__always)
    func compare(_ v: Int64, _ cmp: UInt8, _ target: Int64) -> Bool {
        switch cmp {
        case 0: return v < target
        case 1: return v <= target
        case 2: return v > target
        case 3: return v >= target
        default: return v == target
        }
    }

    func matches(_ r: Record, paths: inout PathCache) -> Bool {
        let start = Int(r.lowerStart), len = Int(r.lowerLength)
        let groups = groupStart.count
        var g = 0
        while g < groups {
            let first = groupStart[g], n = groupCount[g]
            var any = false
            var k = first
            while k < first + n {
                let t = terms[k]
                var hit: Bool
                switch t.kind {
                case CompiledQuery.Kind.contains:
                    hit = containsBytes(lower, start, len, qbytes, t.start, t.length)
                case CompiledQuery.Kind.glob:
                    hit = globBytes(lower, start, len, qbytes, t.start, t.length)
                case CompiledQuery.Kind.ext:
                    hit = false
                    for s in t.start..<t.start + t.length
                    where suffixBytes(lower, start, len, qbytes, slotStart[s], slotLength[s]) {
                        hit = true
                        break
                    }
                case CompiledQuery.Kind.path:
                    hit = pathContains(r, start, len, t, &paths)
                case CompiledQuery.Kind.regex:
                    if let re = regexes[t.start] {
                        let s = String(decoding: UnsafeBufferPointer(rebasing: lower[start..<start + len]), as: UTF8.self)
                        hit = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
                    } else {
                        hit = false
                    }
                case CompiledQuery.Kind.size:
                    hit = r.flags & 1 == 0 && compare(r.size, t.cmp, t.a)
                case CompiledQuery.Kind.modified:
                    switch t.cmp {
                    case 4: hit = r.modified >= t.a && r.modified < t.b
                    case 2: hit = r.modified >= t.b
                    case 3: hit = r.modified >= t.a
                    case 0: hit = r.modified < t.a
                    default: hit = r.modified < t.b
                    }
                case CompiledQuery.Kind.files:
                    hit = r.flags & 1 == 0
                default:
                    hit = r.flags & 1 != 0
                }
                if t.negated { hit = !hit }
                if hit { any = true; break }
                k += 1
            }
            if !any { return false }
            g += 1
        }
        return true
    }

    /// Does "parent path / name" contain the needle? Siblings are stored next to each other,
    /// so the parent's answer and the tail of its path are reused across consecutive records.
    func pathContains(_ r: Record, _ start: Int, _ len: Int, _ t: CompiledQuery.Term,
                      _ paths: inout PathCache) -> Bool {
        if r.parent != paths.lastParent || paths.lastTerm != t.start {
            let full = parentPath(r.parent, cache: &paths.dirs)
            paths.lastParent = r.parent
            paths.lastTerm = t.start
            paths.parentHit = full.withUnsafeBufferPointer { containsBytes($0, 0, $0.count, qbytes, t.start, t.length) }
            // Only the last (needle length - 1) bytes can start a match that runs into the name.
            var tail = Array(full.suffix(max(t.length - 1, 0)))
            if !full.isEmpty && full.last != UInt8(ascii: "/") { tail.append(UInt8(ascii: "/")) }
            paths.tail = tail
        }
        if paths.parentHit { return true }
        var joined = paths.tail
        joined.append(contentsOf: lower[start..<start + len])
        return joined.withUnsafeBufferPointer { containsBytes($0, 0, $0.count, qbytes, t.start, t.length) }
    }

    /// Lowercase full path of a directory, cached per chunk because siblings share it.
    func parentPath(_ id: Int32, cache: inout [Int32: [UInt8]]) -> [UInt8] {
        if id < 0 { return [] }
        if let hit = cache[id] { return hit }
        let r = recs[Int(id)]
        var out = parentPath(r.parent, cache: &cache)
        if !out.isEmpty && out.last != UInt8(ascii: "/") { out.append(UInt8(ascii: "/")) }
        let s = Int(r.lowerStart)
        out.append(contentsOf: lower[s..<s + Int(r.lowerLength)])
        cache[id] = out
        return out
    }
}

// MARK: - Byte matching

@inline(__always)
func containsBytes(_ hay: UnsafeBufferPointer<UInt8>, _ start: Int, _ len: Int,
                   _ needle: UnsafeBufferPointer<UInt8>, _ nStart: Int, _ n: Int) -> Bool {
    if n == 0 { return true }
    if n > len { return false }
    let first = needle[nStart]
    var i = start
    let last = start + len - n
    while i <= last {
        if hay[i] == first {
            var j = 1
            while j < n && hay[i + j] == needle[nStart + j] { j += 1 }
            if j == n { return true }
        }
        i += 1
    }
    return false
}

/// Matches `*` and `?` against the whole name.
func globBytes(_ hay: UnsafeBufferPointer<UInt8>, _ start: Int, _ len: Int,
               _ pattern: UnsafeBufferPointer<UInt8>, _ pStart: Int, _ pLen: Int) -> Bool {
    let star = UInt8(ascii: "*"), question = UInt8(ascii: "?")
    var s = 0, p = 0
    var starP = -1, starS = 0
    while s < len {
        if p < pLen && (pattern[pStart + p] == question || pattern[pStart + p] == hay[start + s]) {
            s += 1; p += 1
        } else if p < pLen && pattern[pStart + p] == star {
            starP = p; starS = s; p += 1
        } else if starP >= 0 {
            p = starP + 1; starS += 1; s = starS
        } else {
            return false
        }
    }
    while p < pLen && pattern[pStart + p] == star { p += 1 }
    return p == pLen
}

@inline(__always)
func suffixBytes(_ hay: UnsafeBufferPointer<UInt8>, _ start: Int, _ len: Int,
                 _ suffix: UnsafeBufferPointer<UInt8>, _ sStart: Int, _ n: Int) -> Bool {
    if n > len { return false }
    let off = start + len - n
    var i = 0
    while i < n {
        if hay[off + i] != suffix[sStart + i] { return false }
        i += 1
    }
    return true
}

/// Per-chunk scratch state for path terms.
struct PathCache {
    var dirs: [Int32: [UInt8]] = [:]
    var lastParent: Int32 = -2
    var lastTerm = -1
    var parentHit = false
    var tail: [UInt8] = []
}
