import Foundation

enum RegexSupport {
    /// The longest literal that every match of `pattern` must contain, lowercased for matching
    /// against lowercase names, or nil when none can be proven. Used to skip names cheaply
    /// before running the regex engine. Conservative: anything it does not understand
    /// (alternation, groups, classes, escapes such as \d) ends the current literal run.
    static func requiredLiteral(_ pattern: String) -> String? {
        // Give up on constructs whose extent this scanner cannot follow: alternation, group
        // modes such as (?x) (which can make spaces insignificant), nested or POSIX classes,
        // and quoted runs.
        for bad in ["|", "(?", "[[", "[:", "\\Q"] where pattern.contains(bad) { return nil }
        let chars = Array(pattern)
        var best: [Character] = []
        var run: [Character] = []
        var depth = 0
        func flush() {
            if run.count > best.count { best = run }
            run = []
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                i += 1
                guard i < chars.count else { flush(); break }
                let e = chars[i]
                if e.isLetter || e.isNumber {
                    // Only escapes that take no argument are safe to step over. Others
                    // (\x41, \u00e9, \p{L}, \cJ, \0101, \k<n>, \1, ...) are followed by
                    // characters that are not literal text, so no literal can be proven.
                    guard "bBdDwWsS".contains(e) else { return nil }
                    flush()
                } else if depth == 0 {
                    run.append(e) // \. \_ \- \( ... are the character itself
                }
            case "[":
                flush()
                i += 1
                if i < chars.count && chars[i] == "^" { i += 1 }
                if i < chars.count && chars[i] == "]" { i += 1 }
                while i < chars.count && chars[i] != "]" {
                    if chars[i] == "\\" { i += 1 }
                    i += 1
                }
            case "(":
                flush()
                depth += 1
            case ")":
                flush()
                depth = max(depth - 1, 0)
            case ".", "^", "$":
                flush()
            case "*", "?":
                // The atom before is optional; if it was a literal character, drop it.
                if !run.isEmpty { run.removeLast() }
                flush()
            case "{":
                if !run.isEmpty { run.removeLast() } // {0,n} can make it optional
                flush()
                while i < chars.count && chars[i] != "}" { i += 1 }
            case "+":
                flush() // one or more: the run so far is still required
            default:
                if depth == 0 { run.append(c) }
            }
            i += 1
        }
        flush()
        guard !best.isEmpty else { return nil }
        return FileIndex.searchForm(String(best))
    }

    /// UTF-16 code units contributed by one UTF-8 byte (the lead byte carries the count).
    @inline(__always)
    static func utf16Units(_ b: UInt8) -> Int {
        if b & 0xC0 == 0x80 { return 0 } // continuation byte
        return b >= 0xF0 ? 2 : 1         // 4-byte sequences are surrogate pairs
    }

    /// Whether running `pattern` over names joined by newlines gives the same per-name answer
    /// as running it on each name. Rejects constructs that can see or match across a name's
    /// edges without the match itself spanning two names (lookaround, absolute anchors,
    /// inline flags, explicit newlines or whitespace). Matches that do span two names are
    /// detected at run time instead.
    static func isLineSafe(_ pattern: String) -> Bool {
        let unsafe = ["(?", "\\A", "\\z", "\\Z", "\\G", "\\n", "\\r", "\\s", "\\R", "\\v", "\\h", "\\N", "\\x", "\\u", "\\0", "\\c"]
        return !unsafe.contains { pattern.contains($0) }
    }

    /// Per name in one search chunk, for each regex term: 1 match, 0 no match, -1 unknown
    /// (the caller then matches that name on its own). For each line-safe regex, the names
    /// that contain its required literal (all names when it has none) are joined by "\n" and
    /// the regex runs once over that text; names without the literal are 0 at once.
    static func chunkHits(lineRegexes: [NSRegularExpression?], literalStart: [Int], literalLength: [Int],
                          qbytes: UnsafeBufferPointer<UInt8>, recs: UnsafeBufferPointer<Record>,
                          lower: UnsafeBufferPointer<UInt8>, lo: Int, hi: Int) -> [Int8] {
        let n = hi - lo
        var hits = [Int8](repeating: -1, count: lineRegexes.count * n)
        let newline = UInt8(ascii: "\n")
        for (k, regex) in lineRegexes.enumerated() {
            guard let re = regex else { continue }
            let litStart = literalStart[k], litLength = literalLength[k]
            var bytes: [UInt8] = []
            var lineStart: [Int] = []   // UTF-16 offset of each joined name
            var lineRecord: [Int] = []  // local index of each joined name
            var unit = 0
            var sawNewline = false
            for id in lo..<hi {
                let r = recs[id]
                if r.flags & 2 != 0 { continue }
                let start = Int(r.lowerStart), len = Int(r.lowerLength)
                if litLength > 0 && !containsBytes(lower, start, len, qbytes, litStart, litLength) {
                    hits[k * n + id - lo] = 0
                    continue
                }
                lineStart.append(unit)
                lineRecord.append(id - lo)
                for b in start..<start + len {
                    let c = lower[b]
                    // ICU's multiline anchors also break lines at \r, U+0085, U+2028 and
                    // U+2029 (UTF-8 C2 85, E2 80 A8, E2 80 A9).
                    if c == newline || c == 0x0D
                        || (c == 0xC2 && b + 1 < start + len && lower[b + 1] == 0x85)
                        || (c == 0xE2 && b + 2 < start + len && lower[b + 1] == 0x80
                            && (lower[b + 2] == 0xA8 || lower[b + 2] == 0xA9)) {
                        sawNewline = true
                    }
                    bytes.append(c)
                    unit += utf16Units(c)
                }
                bytes.append(newline)
                unit += 1
            }
            // A name with a newline would split into two lines: leave candidates unknown.
            if sawNewline || lineStart.isEmpty { continue }
            // The UTF-16 offsets computed above must match the string (a leading byte order
            // mark could be dropped by the conversion); otherwise leave these names unknown.
            guard let text = NSString(bytes: bytes, length: bytes.count, encoding: String.Encoding.utf8.rawValue),
                  text.length == unit
            else { continue }
            let total = unit
            var matched = [Bool](repeating: false, count: lineStart.count)
            var spanned = false
            re.enumerateMatches(in: text as String, options: [], range: NSRange(location: 0, length: total)) { result, _, stop in
                guard let range = result?.range, range.location < total else { return }
                // The line holding the match start, by binary search.
                var a = 0, b = lineStart.count - 1
                while a < b {
                    let m = (a + b + 1) / 2
                    if lineStart[m] <= range.location { a = m } else { b = m - 1 }
                }
                let lineEnd = (a + 1 < lineStart.count ? lineStart[a + 1] : total) - 1 // the "\n"
                if range.location + range.length > lineEnd {
                    spanned = true // a match ran into the next name: per-line answers unreliable
                    stop.pointee = true
                    return
                }
                matched[a] = true
            }
            if spanned { continue }
            for (l, local) in lineRecord.enumerated() { hits[k * n + local] = matched[l] ? 1 : 0 }
        }
        return hits
    }
}
