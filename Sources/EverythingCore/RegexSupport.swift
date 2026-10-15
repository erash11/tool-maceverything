import Foundation

enum RegexSupport {
    /// The longest literal that every match of `pattern` must contain, lowercased for matching
    /// against lowercase names, or nil when none can be proven. Used to skip names cheaply
    /// before running the regex engine. Conservative: anything it does not understand
    /// (alternation, groups, classes, escapes such as \d) ends the current literal run.
    static func requiredLiteral(_ pattern: String) -> String? {
        if pattern.contains("|") { return nil }
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
                    flush() // \d, \w, \b, \1, \x41, ... are not plain literals
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
}
