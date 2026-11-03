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
        case size(Comparison, Int64, negated: Bool)
        /// An inclusive byte range [low, high]: `size:1mb..10mb`, `size:huge`. `=` is inside it,
        /// `>` above it, `>=` from its low end, `<` below it, `<=` up to its high end.
        case sizeRange(Comparison, Int64, Int64, negated: Bool)
        case modified(Comparison, Int64, Int64, negated: Bool) // [start, end) seconds since 1970
        /// `case:Report`: the name as stored (precomposed) holds this text, case kept (precomposed too).
        /// `glob` = whole-name wildcards.
        case cased([UInt8], glob: Bool, negated: Bool)
        /// `ww:report`: the name holds this text as a whole word (see wordBytes).
        case wholeWord([UInt8], negated: Bool)
        /// `len:>200`: the name's length in characters.
        case length(Comparison, Int64, negated: Bool)
        case filesOnly
        case foldersOnly
        /// Temp and generated files, and everything inside temp folders (see TempFiles).
        case temp(negated: Bool)
        /// A filter whose value can't be read (`size:huge`, `dm:lastweek`, `ext:`). Matches nothing,
        /// even negated: skipping it would turn the search into "everything".
        case invalid(String)
    }

    public enum Comparison: Equatable { case less, lessOrEqual, greater, greaterOrEqual, equal }

    public var isEmpty: Bool { groups.isEmpty }

    /// Parses Everything-style syntax: `foo bar`, `"exact phrase"`, `a | b`, `!skip`, `*.pdf`,
    /// `ext:pdf;docx`, `path:Football`, `drive:Work`, `size:>1gb`, `dm:today`, `regex:^IMG_\d+`,
    /// `file:`, `folder:`; modifiers `case:Report`, `ww:report`, `wfn:notes.txt`, `startwith:q`,
    /// `endwith:.txt`; `len:>200`.
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Query {
        var groups: [[Term]] = []
        var joinNext = false
        for token in tokenize(text) {
            if token == "|" {
                joinNext = !groups.isEmpty
                continue
            }
            let term = parseTerm(token, now: now, calendar: calendar)
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
            // "|" separates alternatives, except inside a regex: term, where it is alternation.
            if !inQuotes && ch == "|" && !current.lowercased().drop(while: { $0 == "!" }).hasPrefix("regex:") {
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append("|")
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func parseTerm(_ raw: String, now: Date, calendar: Calendar) -> Term {
        var token = raw
        var negated = false
        if token.hasPrefix("!") && token.count > 1 {
            negated = true
            token.removeFirst()
        }
        let lower = FileIndex.searchForm(token)

        // "!file:" means folders and "!folder:" means files.
        if lower == "file:" { return negated ? .foldersOnly : .filesOnly }
        if lower == "folder:" { return negated ? .filesOnly : .foldersOnly }
        if lower == "temp:" { return .temp(negated: negated) }
        if let filter = FileFilter.forKeyword(lower), let list = FileFilter.extensions[filter] {
            return .ext(list.map { Array(("." + $0).utf8) }, negated: negated)
        }
        if let modifier = textModifiers.first(where: { lower.hasPrefix($0) }) {
            // The modifier is ASCII, so dropping its length from `token` keeps the value's case.
            let value = String(token.dropFirst(modifier.count))
            let low = FileIndex.searchForm(value)
            let wild = low.contains("*") || low.contains("?")
            // shortcut: one modifier per term, name text only; chain them (`case:ww:x`) or allow
            // paths when asked. Until then those match nothing, not the literal text.
            guard !low.isEmpty, !low.contains("/"), !textModifiers.contains(where: { low.hasPrefix($0) }) else {
                return .invalid(raw)
            }
            switch modifier {
            case "case:":
                return .cased(Array(value.precomposedStringWithCanonicalMapping.utf8), glob: wild, negated: negated)
            case "ww:", "wholeword:":
                return wild ? .invalid(raw) : .wholeWord(Array(low.utf8), negated: negated)
            // Wildcards inside the value keep their meaning.
            case "startwith:": return .glob(Array((low + "*").utf8), negated: negated)
            case "endwith:": return .glob(Array(("*" + low).utf8), negated: negated)
            default: return .glob(Array(low.utf8), negated: negated) // wfn: with no wildcard is the exact name
            }
        }
        if lower.hasPrefix("len:") {
            let (cmp, rest) = comparison(String(lower.dropFirst(4)))
            guard !rest.isEmpty, rest.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int64(rest) else {
                return .invalid(raw)
            }
            return .length(cmp, n, negated: negated)
        }
        if lower.hasPrefix("ext:") {
            let exts = lower.dropFirst(4).split(separator: ";").map { Array(("." + $0).utf8) }
            return exts.isEmpty ? .invalid(raw) : .ext(exts, negated: negated)
        }
        if lower.hasPrefix("drive:") {
            // drive:CRASHBOX means everything under /Volumes/CRASHBOX.
            let name = lower.dropFirst(6).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return name.isEmpty ? .invalid(raw) : .pathContains(Array("/volumes/\(name)/".utf8), negated: negated)
        }
        if lower.hasPrefix("path:") {
            let value = String(lower.dropFirst(5))
            return value.isEmpty ? .invalid(raw) : .pathContains(Array(value.utf8), negated: negated)
        }
        if lower.hasPrefix("regex:") {
            let pattern = String(token.dropFirst(6))
            // A pattern that won't compile matches nothing; as .regex, "!regex:([" would match all.
            guard !pattern.isEmpty, (try? NSRegularExpression(pattern: pattern)) != nil else { return .invalid(raw) }
            return .regex(pattern, negated: negated)
        }
        if lower.hasPrefix("size:") {
            let (cmp, rest) = comparison(String(lower.dropFirst(5)))
            if let (low, high) = parseSizeRange(rest) { return .sizeRange(cmp, low, high, negated: negated) }
            guard let bytes = parseSize(rest) else { return .invalid(raw) }
            return .size(cmp, bytes, negated: negated)
        }
        if lower.hasPrefix("dm:") {
            let (cmp, rest) = comparison(String(lower.dropFirst(3)))
            guard let (start, end) = parseDay(rest, now: now, calendar: calendar) else { return .invalid(raw) }
            if end == Int64.max {
                // A rolling window has only a cutoff: ">" and ">=" mean since it, "<" and "<=" before it.
                let since: Comparison
                switch cmp {
                case .greater, .greaterOrEqual: since = .greaterOrEqual
                case .less, .lessOrEqual: since = .less
                case .equal: since = .equal
                }
                return .modified(since, start, end, negated: negated)
            }
            return .modified(cmp, start, end, negated: negated)
        }
        if lower.contains("*") || lower.contains("?") {
            return .glob(Array(lower.utf8), negated: negated)
        }
        if lower.contains("/") {
            return .pathContains(Array(lower.utf8), negated: negated)
        }
        return .contains(Array(lower.utf8), negated: negated)
    }

    /// Everything's text modifiers, as typed (lowercase).
    static let textModifiers = ["case:", "ww:", "wholeword:", "wfn:", "wholefilename:", "startwith:", "endwith:"]

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
        guard let bytes = Int64(s), bytes >= 0 else { return nil } // no negative sizes, as with units
        return bytes
    }

    /// Everything's size names, as inclusive byte ranges.
    static let sizeNames: [String: (Int64, Int64)] = [
        "empty": (0, 0),
        "tiny": (1, 10 << 10), // empty files are `empty`, not tiny
        "small": ((10 << 10) + 1, 100 << 10),
        "medium": ((100 << 10) + 1, 1 << 20),
        "large": ((1 << 20) + 1, 16 << 20),
        "huge": ((16 << 20) + 1, 128 << 20),
        "gigantic": ((128 << 20) + 1, Int64.max),
    ]

    /// `huge`, or `low..high` with sizes as in parseSize (either end may be a size name).
    static func parseSizeRange(_ s: String) -> (Int64, Int64)? {
        if let named = sizeNames[s] { return named }
        let ends = s.components(separatedBy: "..")
        // Exactly one "..", and no stray dot next to it ("0...2gb" is not 0 to 0.2 GB).
        guard ends.count == 2, !ends[0].hasSuffix("."), !ends[1].hasPrefix(".") else { return nil }
        let a = ends[0], b = ends[1]
        guard let low = sizeNames[a]?.0 ?? parseSize(a), let high = sizeNames[b]?.1 ?? parseSize(b),
              low <= high else { return nil }
        return (low, high)
    }

    /// Returns the [start, end) of the day, period or range named by `s`:
    /// `today`, `yesterday`; `thisweek`/`lastweek`, `thismonth`/`lastmonth`, `thisyear`/`lastyear`
    /// (calendar periods; `this`/`current` and `last`/`prev`/`previous` all work); `last7days`,
    /// `past3weeks`, `last12hours` (rolling: from that far back, with no end, so future dates count; `days`
    /// counts today as one); `2026`, `2026-10`, `2026-10-15`; and `a..b`, from the start of a to
    /// the end of b.
    static func parseDay(_ s: String, now: Date, calendar: Calendar) -> (Int64, Int64)? {
        guard s.contains("..") else { return parseOneDay(s, now: now, calendar: calendar) }
        // Exactly one "..": no recursion, so a long chain of them can't run deep.
        let ends = s.components(separatedBy: "..")
        // A rolling window has no end, so it can't be a range endpoint ("2026..last7days").
        guard ends.count == 2,
              !ends.contains(where: { parseRolling($0, now: now, today: calendar.startOfDay(for: now), calendar: calendar) != nil }),
              let (a, _) = parseOneDay(ends[0], now: now, calendar: calendar),
              let (_, b) = parseOneDay(ends[1], now: now, calendar: calendar),
              a < b else { return nil }
        return (a, b)
    }

    /// One day, period or date (no range); see parseDay.
    static func parseOneDay(_ s: String, now: Date, calendar: Calendar) -> (Int64, Int64)? {
        func secs(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970) }
        let today = calendar.startOfDay(for: now)
        // Day edges come from the calendar: where a time change skips midnight, a day starts at
        // 01:00, and "today + 1 day" would land an hour into tomorrow.
        let tomorrow = calendar.dateInterval(of: .day, for: now)?.end
            ?? calendar.date(byAdding: .day, value: 1, to: today)!
        func period(_ unit: Calendar.Component, back: Int) -> (Int64, Int64)? {
            guard let day = calendar.date(byAdding: unit, value: -back, to: today),
                  let interval = calendar.dateInterval(of: unit, for: day) else { return nil }
            return (secs(interval.start), secs(interval.end))
        }
        let units: [(String, Calendar.Component)] = [("week", .weekOfYear), ("month", .month), ("year", .year)]
        for (name, unit) in units {
            if ["this", "current"].contains(where: { s == $0 + name }) { return period(unit, back: 0) }
            if ["last", "prev", "previous"].contains(where: { s == $0 + name }) { return period(unit, back: 1) }
        }
        if s == "today" { return (secs(today), secs(tomorrow)) }
        if s == "yesterday" {
            return (secs(calendar.startOfDay(for: calendar.date(byAdding: .day, value: -1, to: today)!)), secs(today))
        }
        if let start = parseRolling(s, now: now, today: today, calendar: calendar) {
            // Open-ended, as in Everything: a file dated in the future is still "in the last 7 days".
            return (secs(start), Int64.max)
        }
        return parseDate(s, calendar: calendar).map { (secs($0.start), secs($0.end)) }
    }

    /// `last7days`, `past3weeks`, `last12hours`: the start of that rolling window.
    static func parseRolling(_ s: String, now: Date, today: Date, calendar: Calendar) -> Date? {
        guard let prefix = ["last", "past"].first(where: { s.hasPrefix($0) }) else { return nil }
        let rest = s.dropFirst(prefix.count)
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        var unit = String(rest.dropFirst(digits.count))
        if unit.hasSuffix("s") { unit.removeLast() }
        guard let n = Int(digits), n > 0, n <= 100_000 else { return nil }
        let back: (Calendar.Component, Int)
        switch unit {
        case "hour": return calendar.date(byAdding: .hour, value: -n, to: now)
        case "day": back = (.day, -(n - 1)) // today is day 1
        case "week": back = (.weekOfYear, -n)
        case "month": back = (.month, -n)
        case "year": back = (.year, -n)
        default: return nil
        }
        // From the start of that day (moving from a 01:00 start keeps 01:00 otherwise).
        return calendar.date(byAdding: back.0, value: back.1, to: today).map(calendar.startOfDay)
    }

    /// `2026`, `2026-10` or `2026-10-15`: that year, month or day. Every part must be a number, and
    /// the date must exist as written (no 2026-02-30, no month 13).
    static func parseDate(_ s: String, calendar: Calendar) -> DateInterval? {
        let fields = s.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count),
              fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let parts = fields.compactMap { Int($0) }
        guard parts.count == fields.count else { return nil }
        let year = parts[0], month = parts.count > 1 ? parts[1] : 1, day = parts.count > 2 ? parts[2] : 1
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: start) == year,
              calendar.component(.month, from: start) == month,
              calendar.component(.day, from: start) == day else { return nil }
        let unit: Calendar.Component = parts.count == 1 ? .year : parts.count == 2 ? .month : .day
        // The calendar's own interval, so the end is the next period's real start.
        return calendar.dateInterval(of: unit, for: start)
    }
}
