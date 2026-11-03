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
        static let temp: UInt8 = 9, never: UInt8 = 10, sizeRange: UInt8 = 11
        static let cased: UInt8 = 12, casedGlob: UInt8 = 13, word: UInt8 = 14, length: UInt8 = 15
    }

    var terms: [Term] = []
    var groupStart: [Int] = []
    var groupCount: [Int] = []
    var bytes: [UInt8] = []
    var slotStart: [Int] = []
    var slotLength: [Int] = []
    var regexes: [NSRegularExpression?] = []
    /// Same patterns compiled to run over newline-joined names; nil when not line-safe.
    var lineRegexes: [NSRegularExpression?] = []
    /// Per regex: the required literal's offset and length in `bytes` (length 0 when none).
    var regexLiteralStart: [Int] = []
    var regexLiteralLength: [Int] = []
    /// Index into `terms` of each path: term; its PathTable is built per scan.
    var pathTerms: [Int] = []
    var hasRegex = false
    var hasTemp = false

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
            t.b = Int64(pathTerms.count) // which PathTable
            pathTerms.append(terms.count)
        case let .glob(n, neg):
            t.kind = Kind.glob; t.negated = neg; t.start = addBytes(n); t.length = n.count
        case let .regex(pattern, neg):
            t.kind = Kind.regex; t.negated = neg; t.start = regexes.count
            regexes.append(try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
            lineRegexes.append(RegexSupport.isLineSafe(pattern)
                ? try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines])
                : nil)
            hasRegex = true
            // A literal every match must contain lets most names skip the regex engine.
            if let literal = RegexSupport.requiredLiteral(pattern) {
                let lit = Array(literal.utf8)
                t.a = Int64(addBytes(lit))
                t.b = Int64(lit.count)
            }
            regexLiteralStart.append(Int(t.a))
            regexLiteralLength.append(Int(t.b))
        case let .ext(list, neg):
            t.kind = Kind.ext; t.negated = neg; t.start = slotStart.count; t.length = list.count
            for suffix in list {
                slotStart.append(addBytes(suffix))
                slotLength.append(suffix.count)
            }
        case let .size(cmp, value, neg):
            t.kind = Kind.size; t.negated = neg; t.cmp = CompiledQuery.cmpCode(cmp); t.a = value
        case let .sizeRange(cmp, low, high, neg):
            t.kind = Kind.sizeRange; t.negated = neg; t.cmp = CompiledQuery.cmpCode(cmp); t.a = low; t.b = high
        case let .modified(cmp, start, end, neg):
            t.kind = Kind.modified; t.negated = neg; t.cmp = CompiledQuery.cmpCode(cmp); t.a = start; t.b = end
        case let .cased(low, cased, glob, neg):
            t.kind = glob ? Kind.casedGlob : Kind.cased; t.negated = neg
            t.start = addBytes(low); t.length = low.count
            t.a = Int64(addBytes(cased)); t.b = Int64(cased.count)
        case let .wholeWord(n, neg):
            t.kind = Kind.word; t.negated = neg; t.start = addBytes(n); t.length = n.count
        case let .length(cmp, n, neg):
            t.kind = Kind.length; t.negated = neg; t.cmp = CompiledQuery.cmpCode(cmp); t.a = n
        case .filesOnly:
            t.kind = Kind.files
        case .foldersOnly:
            t.kind = Kind.folders
        case let .temp(neg):
            t.kind = Kind.temp; t.negated = neg
            hasTemp = true
        case .invalid:
            t.kind = Kind.never // negated stays false, so "!size:huge" matches nothing too
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
        let temp = compiled.hasTemp ? tempMask() : []

        records.withUnsafeBufferPointer { recs in
        names.withUnsafeBufferPointer { nameBytes in
        lowerNames.withUnsafeBufferPointer { lower in
        compiled.terms.withUnsafeBufferPointer { terms in
        compiled.bytes.withUnsafeBufferPointer { qbytes in
        compiled.slotStart.withUnsafeBufferPointer { slotStart in
        compiled.slotLength.withUnsafeBufferPointer { slotLength in
        compiled.groupStart.withUnsafeBufferPointer { groupStart in
        compiled.groupCount.withUnsafeBufferPointer { groupCount in
        temp.withUnsafeBufferPointer { tempMask in
        partial.withUnsafeMutableBufferPointer { out in
            // One table per path: term, built in a single pass before the parallel scan.
            let tables = compiled.pathTerms.map { k in
                PathTable(needle: qbytes, nStart: terms[k].start, n: terms[k].length, recs: recs, lower: lower)
            }
            let views = tables.map(\.view)
            views.withUnsafeBufferPointer { pathViews in
            let ctx = MatchContext(recs: recs, names: nameBytes, lower: lower, terms: terms, qbytes: qbytes,
                                   slotStart: slotStart, slotLength: slotLength,
                                   groupStart: groupStart, groupCount: groupCount,
                                   regexes: compiled.regexes, pathViews: pathViews, temp: tempMask)
            DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                let lo = chunk * chunkSize
                let hi = min(lo + chunkSize, count)
                if lo >= hi { return }
                var found: [Int32] = []
                // Regex terms run once over the chunk's names joined by newlines; the result
                // says, per name, match / no match / unknown (then matched on its own).
                let regexHits = compiled.hasRegex
                    ? RegexSupport.chunkHits(lineRegexes: compiled.lineRegexes,
                                             literalStart: compiled.regexLiteralStart,
                                             literalLength: compiled.regexLiteralLength, qbytes: qbytes,
                                             recs: recs, lower: lower, lo: lo, hi: hi)
                    : []
                regexHits.withUnsafeBufferPointer { hits in
                    for id in lo..<hi {
                        let r = recs[id]
                        if r.flags & 2 != 0 { continue }
                        if ctx.matches(r, id: id, local: id - lo, chunkLength: hi - lo, regexHits: hits) {
                            found.append(Int32(id))
                        }
                    }
                }
                out[chunk] = found
            }
            }
            withExtendedLifetime(tables) {}
        }}}}}}}}}}}
        return partial.flatMap { $0 }
    }
}

/// Everything the per-record test reads, as unsafe buffers.
struct MatchContext {
    let recs: UnsafeBufferPointer<Record>
    /// Names as stored (case kept), for case:.
    let names: UnsafeBufferPointer<UInt8>
    let lower: UnsafeBufferPointer<UInt8>
    let terms: UnsafeBufferPointer<CompiledQuery.Term>
    let qbytes: UnsafeBufferPointer<UInt8>
    let slotStart: UnsafeBufferPointer<Int>
    let slotLength: UnsafeBufferPointer<Int>
    let groupStart: UnsafeBufferPointer<Int>
    let groupCount: UnsafeBufferPointer<Int>
    let regexes: [NSRegularExpression?]
    let pathViews: UnsafeBufferPointer<PathTable.View>
    /// tempMask() for queries with temp:, else empty.
    let temp: UnsafeBufferPointer<UInt8>

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

    /// case: on the name as stored. ASCII names are read in place; others are precomposed first,
    /// because macOS stores accents decomposed while typed text is precomposed.
    func casedMatch(_ r: Record, glob: Bool, nStart: Int, n: Int) -> Bool {
        let s = Int(r.nameStart), len = Int(r.nameLength)
        var ascii = true
        var i = s
        while i < s + len { if names[i] >= 0x80 { ascii = false; break }; i += 1 }
        if ascii {
            return glob ? globBytes(names, s, len, qbytes, nStart, n) : containsBytes(names, s, len, qbytes, nStart, n)
        }
        let stored = String(decoding: UnsafeBufferPointer(rebasing: names[s..<s + len]), as: UTF8.self)
        let form = Array(stored.precomposedStringWithCanonicalMapping.utf8)
        return form.withUnsafeBufferPointer {
            glob ? globBytes($0, 0, $0.count, qbytes, nStart, n) : containsBytes($0, 0, $0.count, qbytes, nStart, n)
        }
    }

    func matches(_ r: Record, id: Int, local: Int, chunkLength: Int, regexHits: UnsafeBufferPointer<Int8>) -> Bool {
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
                    hit = pathViews[Int(t.b)].matches(r, start: start, len: len, needle: qbytes,
                                                       nStart: t.start, lower: lower)
                case CompiledQuery.Kind.regex:
                    let known: Int8 = regexHits.isEmpty ? -1 : regexHits[t.start * chunkLength + local]
                    if known >= 0 {
                        hit = known == 1
                    } else if t.b > 0 && !containsBytes(lower, start, len, qbytes, Int(t.a), Int(t.b)) {
                        hit = false // lacks a literal every match needs
                    } else if let re = regexes[t.start] {
                        let s = String(decoding: UnsafeBufferPointer(rebasing: lower[start..<start + len]), as: UTF8.self)
                        hit = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
                    } else {
                        hit = false
                    }
                case CompiledQuery.Kind.size:
                    hit = r.flags & 1 == 0 && compare(r.size, t.cmp, t.a)
                case CompiledQuery.Kind.sizeRange:
                    // Folders have no size here, as with size:.
                    if r.flags & 1 != 0 {
                        hit = false
                    } else {
                        switch t.cmp {
                        case 4: hit = r.size >= t.a && r.size <= t.b
                        case 2: hit = r.size > t.b
                        case 3: hit = r.size >= t.a
                        case 0: hit = r.size < t.a
                        default: hit = r.size <= t.b
                        }
                    }
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
                case CompiledQuery.Kind.temp:
                    hit = temp[id] != 0
                case CompiledQuery.Kind.never:
                    hit = false
                case CompiledQuery.Kind.cased, CompiledQuery.Kind.casedGlob:
                    // The lowercase test first: it is cheap and rules out most names.
                    let glob = t.kind == CompiledQuery.Kind.casedGlob
                    hit = glob ? globBytes(lower, start, len, qbytes, t.start, t.length)
                               : containsBytes(lower, start, len, qbytes, t.start, t.length)
                    if hit { hit = casedMatch(r, glob: glob, nStart: Int(t.a), n: Int(t.b)) }
                case CompiledQuery.Kind.word:
                    hit = wordBytes(lower, start, len, qbytes, t.start, t.length)
                case CompiledQuery.Kind.length:
                    hit = compare(characterCount(lower, start, len), t.cmp, t.a)
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

/// A letter or digit, for ww:. Bytes of non-ASCII characters count as letters; `_`, `-`, `.`,
/// spaces and other ASCII punctuation separate words.
@inline(__always)
func isWordByte(_ b: UInt8) -> Bool {
    b >= 0x80 || (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
}

/// containsBytes, where the match must start and end at a word edge: the name's start or end, or
/// a separator byte next to it (see isWordByte).
func wordBytes(_ hay: UnsafeBufferPointer<UInt8>, _ start: Int, _ len: Int,
               _ needle: UnsafeBufferPointer<UInt8>, _ nStart: Int, _ n: Int) -> Bool {
    if n == 0 || n > len { return false }
    let first = needle[nStart]
    let end = start + len
    var i = start
    while i <= end - n {
        if hay[i] == first {
            var j = 1
            while j < n && hay[i + j] == needle[nStart + j] { j += 1 }
            if j == n && (i == start || !isWordByte(hay[i - 1])) && (i + n == end || !isWordByte(hay[i + n])) {
                return true
            }
        }
        i += 1
    }
    return false
}

/// Characters (Unicode scalars) in a UTF-8 name: every byte that doesn't continue a character.
/// shortcut: an accent that has no precomposed form, or an emoji sequence, counts as several.
@inline(__always)
func characterCount(_ hay: UnsafeBufferPointer<UInt8>, _ start: Int, _ len: Int) -> Int64 {
    var count: Int64 = 0
    var i = start
    while i < start + len {
        if hay[i] & 0xC0 != 0x80 { count += 1 }
        i += 1
    }
    return count
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
