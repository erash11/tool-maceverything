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

extension FileIndex {
    /// Runs `query` across every live record, split over all CPU cores.
    public func search(_ query: Query, options: SearchOptions = SearchOptions()) -> SearchResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let ids = matchingIds(query)
        var sorted = ids
        switch options.sort {
        case .name:
            if options.descending { sorted.reverse() }
        case .path:
            let paths = Dictionary(uniqueKeysWithValues: ids.map { ($0, path(of: $0).lowercased()) })
            sorted.sort { options.descending ? paths[$0]! > paths[$1]! : paths[$0]! < paths[$1]! }
        case .size:
            sorted.sort {
                let a = records[Int($0)].size, b = records[Int($1)].size
                return options.descending ? a > b : a < b
            }
        case .modified:
            sorted.sort {
                let a = records[Int($0)].modified, b = records[Int($1)].modified
                return options.descending ? a > b : a < b
            }
        }
        let lo = min(options.offset, sorted.count)
        let wanted = max(options.limit, 0)
        let hi = wanted >= sorted.count - lo ? sorted.count : lo + wanted
        let hits = sorted[lo..<hi].map { id -> SearchHit in
            let r = records[Int(id)]
            return SearchHit(path: path(of: id), name: name(of: id), isDirectory: r.isDirectory,
                             size: r.size, modified: r.modified)
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        return SearchResult(total: ids.count, hits: hits, milliseconds: ms)
    }

    /// Ids of live records matching `query`, in name order.
    public func matchingIds(_ query: Query) -> [Int32] {
        let regexes = compileRegexes(query)
        let fromOrder = scan(order, query, regexes)
        if unsorted.isEmpty { return fromOrder }
        var extra = scan(unsorted, query, regexes)
        extra.sort(by: lowerBytesLess)
        return merge(fromOrder, extra)
    }

    private func compileRegexes(_ query: Query) -> [String: NSRegularExpression] {
        var out: [String: NSRegularExpression] = [:]
        for group in query.groups {
            for term in group {
                if case let .regex(pattern, _) = term, out[pattern] == nil {
                    out[pattern] = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                }
            }
        }
        return out
    }

    private func merge(_ a: [Int32], _ b: [Int32]) -> [Int32] {
        var out: [Int32] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if lowerBytesLess(b[j], a[i]) { out.append(b[j]); j += 1 } else { out.append(a[i]); i += 1 }
        }
        out.append(contentsOf: a[i...])
        out.append(contentsOf: b[j...])
        return out
    }

    private func scan(_ ids: [Int32], _ query: Query, _ regexes: [String: NSRegularExpression]) -> [Int32] {
        if ids.isEmpty { return [] }
        let chunkCount = max(1, min(ProcessInfo.processInfo.activeProcessorCount * 4, ids.count / 4096 + 1))
        let chunkSize = (ids.count + chunkCount - 1) / chunkCount
        var partial = [[Int32]](repeating: [], count: chunkCount)
        let partialLock = NSLock()
        records.withUnsafeBufferPointer { recs in
            lowerNames.withUnsafeBufferPointer { lower in
                ids.withUnsafeBufferPointer { idBuf in
                    DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                        let lo = chunk * chunkSize
                        let hi = min(lo + chunkSize, idBuf.count)
                        if lo >= hi { return }
                        var found: [Int32] = []
                        var pathCache: [Int32: [UInt8]] = [:]
                        for k in lo..<hi {
                            let id = idBuf[k]
                            let r = recs[Int(id)]
                            if r.isDeleted { continue }
                            if matches(query, id: id, record: r, recs: recs, lower: lower,
                                       regexes: regexes, pathCache: &pathCache) {
                                found.append(id)
                            }
                        }
                        partialLock.lock()
                        partial[chunk] = found
                        partialLock.unlock()
                    }
                }
            }
        }
        return partial.flatMap { $0 }
    }

    private func matches(_ query: Query, id: Int32, record r: Record,
                         recs: UnsafeBufferPointer<Record>, lower: UnsafeBufferPointer<UInt8>,
                         regexes: [String: NSRegularExpression],
                         pathCache: inout [Int32: [UInt8]]) -> Bool {
        let start = Int(r.lowerStart), len = Int(r.lowerLength)
        for group in query.groups {
            var any = false
            for term in group {
                let hit: Bool
                switch term {
                case let .contains(needle, negated):
                    hit = bytesContain(lower, start, len, needle) != negated
                case let .glob(pattern, negated):
                    hit = globMatch(lower, start, len, pattern) != negated
                case let .ext(suffixes, negated):
                    hit = suffixes.contains { bytesHaveSuffix(lower, start, len, $0) } != negated
                case let .pathContains(needle, negated):
                    var full = parentPath(r.parent, recs: recs, lower: lower, cache: &pathCache)
                    if !full.isEmpty && full.last != UInt8(ascii: "/") { full.append(UInt8(ascii: "/")) }
                    full.append(contentsOf: lower[start..<start + len])
                    let found = full.withUnsafeBufferPointer { bytesContain($0, 0, $0.count, needle) }
                    hit = found != negated
                case let .regex(pattern, negated):
                    if let re = regexes[pattern] {
                        let s = String(decoding: UnsafeBufferPointer(rebasing: lower[start..<start + len]), as: UTF8.self)
                        let found = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
                        hit = found != negated
                    } else {
                        hit = false
                    }
                case let .size(cmp, value):
                    hit = !r.isDirectory && compare(r.size, cmp, value)
                case let .modified(cmp, dayStart, dayEnd):
                    switch cmp {
                    case .equal: hit = r.modified >= dayStart && r.modified < dayEnd
                    case .greater: hit = r.modified >= dayEnd
                    case .greaterOrEqual: hit = r.modified >= dayStart
                    case .less: hit = r.modified < dayStart
                    case .lessOrEqual: hit = r.modified < dayEnd
                    }
                case .filesOnly:
                    hit = !r.isDirectory
                case .foldersOnly:
                    hit = r.isDirectory
                }
                if hit { any = true; break }
            }
            if !any { return false }
        }
        return true
    }

    private func compare(_ a: Int64, _ cmp: Query.Comparison, _ b: Int64) -> Bool {
        switch cmp {
        case .less: return a < b
        case .lessOrEqual: return a <= b
        case .greater: return a > b
        case .greaterOrEqual: return a >= b
        case .equal: return a == b
        }
    }

    /// Lowercase full path of a directory, cached per search chunk because siblings share it.
    private func parentPath(_ id: Int32, recs: UnsafeBufferPointer<Record>, lower: UnsafeBufferPointer<UInt8>,
                            cache: inout [Int32: [UInt8]]) -> [UInt8] {
        if id < 0 { return [] }
        if let hit = cache[id] { return hit }
        let r = recs[Int(id)]
        var out = parentPath(r.parent, recs: recs, lower: lower, cache: &cache)
        if !out.isEmpty && out.last != UInt8(ascii: "/") { out.append(UInt8(ascii: "/")) }
        let s = Int(r.lowerStart)
        out.append(contentsOf: lower[s..<s + Int(r.lowerLength)])
        cache[id] = out
        return out
    }
}
