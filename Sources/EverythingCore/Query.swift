import Foundation

/// A parsed search. Groups are ANDed; the alternatives inside a group are ORed.
public struct Query {
    public var groups: [[Term]]

    public init(groups: [[Term]]) { self.groups = groups }

    public enum Term: Equatable {
        case contains([UInt8], negated: Bool)          // lowercase bytes, matched against the name
        case pathContains([UInt8], negated: Bool)      // lowercase bytes, matched against the full path
        case glob([UInt8], negated: Bool)              // lowercase wildcard pattern, whole name
        case regex(String, negated: Bool)
        case ext([[UInt8]], negated: Bool)             // ".pdf" style lowercase suffixes
        case size(Comparison, Int64)
        case modified(Comparison, Int64, Int64)        // [start, end) seconds since 1970
        case filesOnly
        case foldersOnly
    }

    public enum Comparison: Equatable { case less, lessOrEqual, greater, greaterOrEqual, equal }

    public var isEmpty: Bool { groups.isEmpty }

    /// Parses Everything-style syntax: `foo bar`, `"exact phrase"`, `a | b`, `!skip`, `*.pdf`,
    /// `ext:pdf;docx`, `path:Football`, `size:>1gb`, `dm:today`, `regex:^IMG_\d+`, `file:`, `folder:`.
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Query {
        var groups: [[Term]] = []
        var joinNext = false
        for token in tokenize(text) {
            if token == "|" {
                joinNext = !groups.isEmpty
                continue
            }
            guard let term = parseTerm(token, now: now, calendar: calendar) else { continue }
            if joinNext, !groups.isEmpty {
                groups[groups.count - 1].append(term)
            } else {
                groups.append([term])
            }
            joinNext = false
        }
        return Query(groups: groups)
    }

    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in text {
            if ch == "\"" {
                inQuotes.toggle()
                continue
            }
            if !inQuotes && (ch == " " || ch == "\t" || ch == "\n") {
                if !current.isEmpty { tokens.append(current); current = "" }
                continue
            }
            if !inQuotes && ch == "|" {
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append("|")
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func parseTerm(_ raw: String, now: Date, calendar: Calendar) -> Term? {
        var token = raw
        var negated = false
        if token.hasPrefix("!") && token.count > 1 {
            negated = true
            token.removeFirst()
        }
        let lower = FileIndex.searchForm(token)

        if lower == "file:" { return .filesOnly }
        if lower == "folder:" { return .foldersOnly }
        if lower.hasPrefix("ext:") {
            let exts = lower.dropFirst(4).split(separator: ";").map { Array(("." + $0).utf8) }
            return exts.isEmpty ? nil : .ext(exts, negated: negated)
        }
        if lower.hasPrefix("path:") {
            let value = String(lower.dropFirst(5))
            return value.isEmpty ? nil : .pathContains(Array(value.utf8), negated: negated)
        }
        if lower.hasPrefix("regex:") {
            let pattern = String(token.dropFirst(6))
            return pattern.isEmpty ? nil : .regex(pattern, negated: negated)
        }
        if lower.hasPrefix("size:") {
            let (cmp, rest) = comparison(String(lower.dropFirst(5)))
            guard let bytes = parseSize(rest) else { return nil }
            return .size(cmp, bytes)
        }
        if lower.hasPrefix("dm:") {
            let (cmp, rest) = comparison(String(lower.dropFirst(3)))
            guard let (start, end) = parseDay(rest, now: now, calendar: calendar) else { return nil }
            return .modified(cmp, start, end)
        }
        if lower.contains("*") || lower.contains("?") {
            return .glob(Array(lower.utf8), negated: negated)
        }
        if lower.contains("/") {
            return .pathContains(Array(lower.utf8), negated: negated)
        }
        return .contains(Array(lower.utf8), negated: negated)
    }

    static func comparison(_ s: String) -> (Comparison, String) {
        if s.hasPrefix(">=") { return (.greaterOrEqual, String(s.dropFirst(2))) }
        if s.hasPrefix("<=") { return (.lessOrEqual, String(s.dropFirst(2))) }
        if s.hasPrefix(">") { return (.greater, String(s.dropFirst())) }
        if s.hasPrefix("<") { return (.less, String(s.dropFirst())) }
        if s.hasPrefix("=") { return (.equal, String(s.dropFirst())) }
        return (.equal, s)
    }

    static func parseSize(_ s: String) -> Int64? {
        let units: [(String, Int64)] = [("tb", 1 << 40), ("gb", 1 << 30), ("mb", 1 << 20), ("kb", 1 << 10), ("b", 1)]
        for (suffix, mult) in units where s.hasSuffix(suffix) {
            guard let n = Double(s.dropLast(suffix.count)) else { return nil }
            let bytes = n * Double(mult)
            // Double(_:) accepts "nan", "inf" and 1e999; converting those to Int64 would trap.
            guard bytes.isFinite, bytes >= 0, bytes < 9.2e18 else { return nil }
            return Int64(bytes)
        }
        return Int64(s)
    }

    /// Returns the [start, end) of the day or range named by `s`.
    static func parseDay(_ s: String, now: Date, calendar: Calendar) -> (Int64, Int64)? {
        let today = calendar.startOfDay(for: now)
        func secs(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970) }
        switch s {
        case "today":
            return (secs(today), secs(calendar.date(byAdding: .day, value: 1, to: today)!))
        case "yesterday":
            return (secs(calendar.date(byAdding: .day, value: -1, to: today)!), secs(today))
        case "thisweek", "last7days":
            return (secs(calendar.date(byAdding: .day, value: -6, to: today)!),
                    secs(calendar.date(byAdding: .day, value: 1, to: today)!))
        default:
            let parts = s.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
            else { return nil }
            return (secs(day), secs(calendar.date(byAdding: .day, value: 1, to: day)!))
        }
    }
}
