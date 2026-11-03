import XCTest
@testable import EverythingCore

final class IndexTests: XCTestCase {
    /// /data
    ///   Reports/  q1 report.pdf (2 MB), Q2 Report.docx
    ///   film/     game1.mp4 (3 GB), notes.txt
    func makeIndex() -> FileIndex {
        let index = FileIndex()
        let root = index.addRoot("/data")
        let reports = index.add(ScannedEntry(name: "Reports", isDirectory: true, size: 0, modified: 100), parent: root)
        index.add(ScannedEntry(name: "q1 report.pdf", isDirectory: false, size: 2 << 20, modified: 100), parent: reports)
        index.add(ScannedEntry(name: "Q2 Report.docx", isDirectory: false, size: 10, modified: 200), parent: reports)
        let film = index.add(ScannedEntry(name: "film", isDirectory: true, size: 0, modified: 100), parent: root)
        index.add(ScannedEntry(name: "game1.mp4", isDirectory: false, size: 3 << 30, modified: 300), parent: film)
        index.add(ScannedEntry(name: "notes.txt", isDirectory: false, size: 5, modified: 300), parent: film)
        index.sortIfNeeded(force: true)
        return index
    }

    func names(_ index: FileIndex, _ q: String) -> [String] {
        index.search(Query.parse(q), options: SearchOptions(limit: 1000)).hits.map(\.name)
    }

    func testPathsAndLookup() {
        let index = makeIndex()
        let id = index.lookup("/data/film/game1.mp4")
        XCTAssertNotNil(id)
        XCTAssertEqual(index.path(of: id!), "/data/film/game1.mp4")
        XCTAssertNil(index.lookup("/data/film/missing"))
        XCTAssertEqual(index.lookup("/data/"), index.lookup("/data"))
    }

    func testRootSlashPath() {
        let index = FileIndex()
        let root = index.addRoot("/")
        let users = index.add(ScannedEntry(name: "Users", isDirectory: true, size: 0, modified: 0), parent: root)
        let f = index.add(ScannedEntry(name: "a.txt", isDirectory: false, size: 0, modified: 0), parent: users)
        XCTAssertEqual(index.path(of: f), "/Users/a.txt")
        XCTAssertEqual(index.lookup("/Users/a.txt"), f)
    }

    func testSubstringIsCaseInsensitiveAndSorted() {
        XCTAssertEqual(names(makeIndex(), "report"), ["q1 report.pdf", "Q2 Report.docx", "Reports"])
    }

    func testAndOrNot() {
        let index = makeIndex()
        XCTAssertEqual(names(index, "report pdf"), ["q1 report.pdf"])
        XCTAssertEqual(names(index, "game | notes"), ["game1.mp4", "notes.txt"])
        XCTAssertEqual(names(index, "report !docx !reports"), ["q1 report.pdf"])
    }

    func testPhraseGlobExt() {
        let index = makeIndex()
        XCTAssertEqual(names(index, "\"q1 report\""), ["q1 report.pdf"])
        XCTAssertEqual(names(index, "*.mp4"), ["game1.mp4"])
        XCTAssertEqual(names(index, "game?.*"), ["game1.mp4"])
        XCTAssertEqual(names(index, "ext:pdf;docx"), ["q1 report.pdf", "Q2 Report.docx"])
    }

    func testPathSizeAndKind() {
        let index = makeIndex()
        XCTAssertEqual(names(index, "path:film/"), ["game1.mp4", "notes.txt"])
        XCTAssertEqual(names(index, "film/notes"), ["notes.txt"])
        XCTAssertEqual(names(index, "size:>1gb"), ["game1.mp4"])
        XCTAssertEqual(names(index, "size:<=10"), ["notes.txt", "Q2 Report.docx"])
        // Roots are named by their full path, so "/data" sorts first.
        XCTAssertEqual(names(index, "folder:"), ["/data", "film", "Reports"])
    }

    func testRegex() {
        XCTAssertEqual(names(makeIndex(), "regex:^game\\d"), ["game1.mp4"])
    }

    func testDateModified() {
        let index = FileIndex()
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
        let today = Int64(cal.startOfDay(for: now).timeIntervalSince1970)
        let root = index.addRoot("/x", modified: today + 30)
        index.add(ScannedEntry(name: "new.txt", isDirectory: false, size: 1, modified: today + 60), parent: root)
        index.add(ScannedEntry(name: "old.txt", isDirectory: false, size: 1, modified: today - 86_400 * 3), parent: root)
        let q = Query.parse("dm:today", now: now, calendar: cal)
        XCTAssertEqual(index.search(q).hits.map(\.name), ["/x", "new.txt"])
        let q2 = Query.parse("dm:<2026-10-15", now: now, calendar: cal)
        XCTAssertEqual(index.search(q2).hits.map(\.name), ["old.txt"])
    }

    func testReplaceChildrenAndRemove() {
        let index = makeIndex()
        let film = index.lookup("/data/film")!
        let newDirs = index.replaceChildren(of: film, with: [
            ScannedEntry(name: "game1.mp4", isDirectory: false, size: 7, modified: 400),
            ScannedEntry(name: "clips", isDirectory: true, size: 0, modified: 400),
        ])
        XCTAssertEqual(newDirs.count, 1)
        XCTAssertNil(index.lookup("/data/film/notes.txt"))
        XCTAssertEqual(index.records[Int(index.lookup("/data/film/game1.mp4")!)].size, 7)
        XCTAssertEqual(names(index, "clips"), ["clips"])

        index.remove(index.lookup("/data/Reports")!)
        XCTAssertEqual(names(index, "report"), [])
        XCTAssertEqual(index.liveCount, 4) // /data, film, game1.mp4, clips
    }

    func testUnsortedMergesInOrder() {
        let index = makeIndex()
        let root = index.lookup("/data")!
        index.add(ScannedEntry(name: "aaa report", isDirectory: false, size: 0, modified: 0), parent: root)
        XCTAssertEqual(names(index, "report"), ["aaa report", "q1 report.pdf", "Q2 Report.docx", "Reports"])
    }

    func testCompactedKeepsLiveRecords() {
        let index = makeIndex()
        index.remove(index.lookup("/data/film")!)
        let c = index.compacted()
        XCTAssertEqual(c.deletedCount, 0)
        XCTAssertEqual(c.records.count, index.liveCount)
        XCTAssertNotNil(c.lookup("/data/Reports/q1 report.pdf"))
        XCTAssertNil(c.lookup("/data/film"))
    }

    func testSortBySizeDescending() {
        let r = makeIndex().search(Query.parse("file:"), options: SearchOptions(limit: 2, sort: .size, descending: true))
        XCTAssertEqual(r.total, 4)
        XCTAssertEqual(r.hits.map(\.name), ["game1.mp4", "q1 report.pdf"])
    }

    func testHostileInputDoesNotTrap() {
        let index = makeIndex()
        let r = index.search(Query.parse("report"), options: SearchOptions(limit: 5, offset: -1))
        XCTAssertEqual(r.hits.count, 3)
        XCTAssertEqual(index.search(Query.parse("report"), options: SearchOptions(limit: -4)).hits.count, 0)
        XCTAssertEqual(index.search(Query.parse("report"), options: SearchOptions(limit: Int.max, offset: 2)).hits.count, 1)
        for q in ["size:nanb", "size:infgb", "size:1e999b", "size:-5kb", "dm:99999999-1-1", "regex:([", "ext:", "path:"] {
            _ = index.search(Query.parse(q))
        }
        XCTAssertEqual(index.search(Query.parse("size:nanb")).total, 0)
    }

    func testUnreadableFilterMatchesNothing() {
        // Skipping these used to leave an empty query, which matched every file.
        let index = makeIndex()
        XCTAssertEqual(index.search(Query.parse("")).total, 7)
        for q in ["dm:lastfortnight", "dm:2026-10-15..2026-10-01", "size:10mb..5mb", "size:enormous",
                  "ext:", "path:", "drive:", "regex:", "!size:enormous", "!dm:lastfortnight",
                  "report dm:nonsense", "report | size:enormous", "size:enormous | dm:nonsense",
                  "regex:([", "!regex:([", "report | !regex:([", "dm:2026-10-x-15", "!dm:2026-10-x-15",
                  "dm:2026-02-30", "!dm:2026-1x-01", "dm:-2026-10-15", "dm:2026-13", "dm:last0days",
                  "dm:last3fortnights", "dm:2026..", "size:..5mb",
                  "case:", "!case:", "ww:", "wfn:", "startwith:", "endwith:", "ww:rep*", "case:ww:Report",
                  "case:a/b", "!ww:x/y", "len:", "len:abc", "len:>", "len:-1", "len:99999999999999999999"] {
            let r = index.search(Query.parse(q))
            XCTAssertEqual(r.total, q.hasPrefix("report |") ? 3 : 0, q)
        }
        // Real dates still parse, with or without zero padding.
        for q in ["dm:2026-10-15", "dm:2026-1-5", "dm:<2026-10-15", "dm:2026", "dm:2026-10", "size:huge"] {
            XCTAssertNotEqual(Query.parse(q).groups, [[.invalid(q)]], q)
        }
        XCTAssertEqual(Query.parse("size:enormous").groups, [[.invalid("size:enormous")]])
        XCTAssertEqual(Query.parse("!dm:lastfortnight").groups, [[.invalid("!dm:lastfortnight")]])
    }

    func testTextModifiers() {
        // makeIndex names: /data, Reports, q1 report.pdf, Q2 Report.docx, film, game1.mp4, notes.txt.
        let index = makeIndex()
        XCTAssertEqual(names(index, "case:Report"), ["Q2 Report.docx", "Reports"])
        XCTAssertEqual(names(index, "CASE:report"), ["q1 report.pdf"])
        XCTAssertEqual(names(index, "report !case:Report"), ["q1 report.pdf"])
        XCTAssertEqual(names(index, "case:Q?*"), ["Q2 Report.docx"])
        XCTAssertEqual(names(index, "ww:report"), ["q1 report.pdf", "Q2 Report.docx"]) // not Reports
        XCTAssertEqual(names(index, "wholeword:REPORT"), ["q1 report.pdf", "Q2 Report.docx"])
        XCTAssertEqual(names(index, "ww:game"), []) // in game1 the digit is part of the word
        XCTAssertEqual(names(index, "ww:mp4"), ["game1.mp4"])
        XCTAssertEqual(names(index, "ww:\"q1 report\""), ["q1 report.pdf"])
        XCTAssertEqual(names(index, "!ww:report file:"), ["game1.mp4", "notes.txt"])
        XCTAssertEqual(names(index, "wfn:notes.txt"), ["notes.txt"])
        XCTAssertEqual(names(index, "wholefilename:NOTES.TXT"), ["notes.txt"])
        XCTAssertEqual(names(index, "wfn:notes"), [])
        XCTAssertEqual(names(index, "startwith:q"), ["q1 report.pdf", "Q2 Report.docx"])
        XCTAssertEqual(names(index, "startwith:report"), ["Reports"])
        XCTAssertEqual(names(index, "endwith:.txt"), ["notes.txt"])
        XCTAssertEqual(names(index, "len:9"), ["game1.mp4", "notes.txt"])
        XCTAssertEqual(names(index, "len:>12"), ["q1 report.pdf", "Q2 Report.docx"])
        XCTAssertEqual(names(index, "len:<5"), ["film"])
        XCTAssertEqual(names(index, "!len:<=12 file:"), ["q1 report.pdf", "Q2 Report.docx"])
        XCTAssertEqual(Query.parse("image:").groups, Query.parse("pic:").groups)
        XCTAssertEqual(Query.parse("!IMAGE:").groups, Query.parse("!pic:").groups)
    }

    func testCaseAndLengthWithAccents() {
        // macOS stores accents decomposed (e + U+0301); typed text is precomposed (U+00E9).
        let index = FileIndex()
        let root = index.addRoot("/d")
        index.add(ScannedEntry(name: "Re\u{301}sume\u{301}.pdf", isDirectory: false, size: 1, modified: 0), parent: root)
        index.sortIfNeeded(force: true)
        XCTAssertEqual(index.search(Query.parse("case:R\u{E9}sum\u{E9}")).total, 1)
        XCTAssertEqual(index.search(Query.parse("case:r\u{E9}sum\u{E9}")).total, 0)
        XCTAssertEqual(index.search(Query.parse("ww:r\u{E9}sum\u{E9}")).total, 1)
        XCTAssertEqual(index.search(Query.parse("ww:r\u{E9}sum")).total, 0) // an accented letter is a letter
        XCTAssertEqual(index.search(Query.parse("len:10")).total, 1) // 10 characters, 12 bytes
        // ? is one character, however many bytes it takes.
        XCTAssertEqual(index.search(Query.parse("r?sum?.pdf")).total, 1)
        XCTAssertEqual(index.search(Query.parse("case:R?sum?.pdf")).total, 1)
        XCTAssertEqual(index.search(Query.parse("wfn:r??sum?.pdf")).total, 0)
        XCTAssertEqual(index.search(Query.parse("*?.pdf")).total, 1)
    }

    func testRegexesThatLookEqualAreKeptApart() {
        // "e" + U+0301 and "é" are equal Swift Strings but different patterns; the index form is precomposed.
        let index = FileIndex()
        let root = index.addRoot("/d")
        index.add(ScannedEntry(name: "e\u{301}.txt", isDirectory: false, size: 1, modified: 0), parent: root)
        index.sortIfNeeded(force: true)
        let q = Query.parse("regex:^e\u{301}\\. | regex:^\u{E9}\\.")
        XCTAssertEqual(CompiledQuery(q).regexes.count, 2)
        XCTAssertEqual(index.search(q).total, 1)
    }

    func testCaseWhereLowercaseDependsOnContext() {
        // "ΟΣ" lowercases to "ος" (final sigma), but a lone "Σ" to "σ": a lowercase first test would miss it.
        let index = FileIndex()
        let root = index.addRoot("/d")
        index.add(ScannedEntry(name: "\u{39F}\u{3A3}", isDirectory: false, size: 1, modified: 0), parent: root)
        index.add(ScannedEntry(name: "\u{1F600}.txt", isDirectory: false, size: 1, modified: 0), parent: root)
        index.sortIfNeeded(force: true)
        XCTAssertEqual(index.search(Query.parse("case:\u{3A3}")).total, 1)
        XCTAssertEqual(index.search(Query.parse("!case:\u{3A3} file:")).total, 1) // only the emoji file
        XCTAssertEqual(index.search(Query.parse("?.txt")).total, 1) // one 4-byte character
        XCTAssertEqual(index.search(Query.parse("len:5 *.txt")).total, 1)
        // "İ" lowercases to "i" + a combining dot: two characters where the name has one.
        index.add(ScannedEntry(name: "\u{130}.md", isDirectory: false, size: 1, modified: 0), parent: root)
        XCTAssertEqual(index.search(Query.parse("case:?.md")).total, 1)
        XCTAssertEqual(index.search(Query.parse("!case:?.md file:")).total, 2)
        XCTAssertEqual(index.search(Query.parse("case:*.md")).total, 1)
        // "H" + U+0331 lowercases and composes to "ẖ", which holds no "h"; the stored name still has "H".
        index.add(ScannedEntry(name: "H\u{331}.rtf", isDirectory: false, size: 1, modified: 0), parent: root)
        XCTAssertEqual(index.search(Query.parse("case:H *.rtf")).total, 1)
        XCTAssertEqual(index.search(Query.parse("case:*H*")).total, 1)
        XCTAssertEqual(index.search(Query.parse("!case:H *.rtf")).total, 0)
        XCTAssertEqual(index.search(Query.parse("case:h *.rtf")).total, 0)
    }

    func testFolderFunctions() {
        // makeIndex: /data (depth 1) holds Reports and film (2), each holding two files (3).
        let index = makeIndex()
        XCTAssertEqual(names(index, "parent:/data"), ["film", "Reports"])
        XCTAssertEqual(names(index, "parent:/DATA/reports"), ["q1 report.pdf", "Q2 Report.docx"])
        XCTAssertEqual(names(index, "infolder:/data/Reports/"), ["q1 report.pdf", "Q2 Report.docx"])
        XCTAssertEqual(names(index, "file: !parent:/data/film"), ["q1 report.pdf", "Q2 Report.docx"])
        XCTAssertEqual(names(index, "parent:/data/nope"), [])
        XCTAssertEqual(names(index, "!parent:/data/nope").count, 7) // a missing folder holds nothing
        XCTAssertEqual(names(index, "\"parent:/data/reports/q1 report.pdf\""), []) // a file holds nothing
        XCTAssertEqual(names(index, "depth:1"), ["/data"])
        XCTAssertEqual(names(index, "depth:2"), ["film", "Reports"])
        XCTAssertEqual(names(index, "parents:>2"), ["game1.mp4", "notes.txt", "q1 report.pdf", "Q2 Report.docx"])
        XCTAssertEqual(names(index, "!depth:3"), ["/data", "film", "Reports"])
        XCTAssertEqual(names(index, "childcount:2"), ["/data", "film", "Reports"])
        XCTAssertEqual(names(index, "childcount:0"), []) // files never match
        XCTAssertEqual(names(index, "empty:"), [])

        // A folder emptied by a rescan, then a file removed.
        let film = index.lookup("/data/film")!
        index.replaceChildren(of: film, with: [])
        XCTAssertEqual(names(index, "empty:"), ["film"])
        XCTAssertEqual(names(index, "childcount:0"), ["film"])
        XCTAssertEqual(names(index, "childcount:2"), ["/data", "Reports"])
        index.remove(index.lookup("/data/Reports/q1 report.pdf")!)
        XCTAssertEqual(names(index, "childcount:1"), ["Reports"])
        XCTAssertEqual(names(index, "!empty:"), ["/data", "Q2 Report.docx", "Reports"])
        XCTAssertEqual(names(index, "empty: | parent:/data/reports"), ["film", "Q2 Report.docx"])

        // Depth counts path parts, so a root like /Volumes/X starts at 2. The longest root wins, and
        // a case-sensitive volume can hold Users and users: parent: finds both. The walk of / records
        // Volumes without entering it; the root /Volumes/X counts as in it.
        let disk = FileIndex()
        let top = disk.addRoot("/")
        let upper = disk.add(ScannedEntry(name: "Users", isDirectory: true, size: 0, modified: 0), parent: top)
        let lower = disk.add(ScannedEntry(name: "users", isDirectory: true, size: 0, modified: 0), parent: top)
        disk.add(ScannedEntry(name: "a.txt", isDirectory: false, size: 1, modified: 0), parent: upper)
        disk.add(ScannedEntry(name: "b.txt", isDirectory: false, size: 1, modified: 0), parent: lower)
        disk.add(ScannedEntry(name: "Volumes", isDirectory: true, size: 0, modified: 0), parent: top)
        let vol = disk.addRoot("/Volumes/X")
        let a = disk.add(ScannedEntry(name: "a", isDirectory: true, size: 0, modified: 0), parent: vol)
        disk.add(ScannedEntry(name: "deep.txt", isDirectory: false, size: 1, modified: 0), parent: a)
        let docs = disk.add(ScannedEntry(name: "My Docs", isDirectory: true, size: 0, modified: 0), parent: vol)
        disk.add(ScannedEntry(name: "c.txt", isDirectory: false, size: 1, modified: 0), parent: docs)
        disk.sortIfNeeded(force: true)
        XCTAssertEqual(names(disk, "depth:0"), ["/"])
        XCTAssertEqual(names(disk, "depth:2"), ["/Volumes/X", "a.txt", "b.txt"])
        XCTAssertEqual(names(disk, "depth:3 | parent:/volumes"), ["/Volumes/X", "a", "My Docs"])
        XCTAssertEqual(names(disk, "parent:/Volumes/"), ["/Volumes/X"])
        XCTAssertEqual(names(disk, "!parent:/volumes depth:2"), ["a.txt", "b.txt"])
        XCTAssertEqual(names(disk, "depth:4"), ["c.txt", "deep.txt"])
        XCTAssertEqual(names(disk, "parent:/"), ["Users", "users", "Volumes"])
        XCTAssertEqual(names(disk, "parent:/USERS"), ["a.txt", "b.txt"])
        XCTAssertEqual(names(disk, "parent:/Volumes/x"), ["a", "My Docs"])
        XCTAssertEqual(names(disk, "\"parent:/volumes/x/my docs\""), ["c.txt"])
        XCTAssertEqual(names(disk, "parent:/volumes/xy"), [])
        XCTAssertEqual(names(disk, "childcount:1"), ["a", "My Docs", "Users", "users", "Volumes"])
        XCTAssertEqual(names(disk, "empty:"), [])

        // When the folder already lists a child of the root's name, the root isn't counted twice.
        let twice = FileIndex()
        let slash = twice.addRoot("/")
        let volumes = twice.add(ScannedEntry(name: "Volumes", isDirectory: true, size: 0, modified: 0), parent: slash)
        twice.add(ScannedEntry(name: "X", isDirectory: true, size: 0, modified: 0), parent: volumes)
        twice.addRoot("/Volumes/X")
        twice.addRoot("/elsewhere/Y") // its folder isn't indexed
        twice.sortIfNeeded(force: true)
        XCTAssertEqual(names(twice, "parent:/volumes"), ["X"])
        XCTAssertEqual(names(twice, "childcount:1"), ["/", "Volumes"])
        XCTAssertEqual(names(twice, "parent:/elsewhere"), [])
        XCTAssertEqual(names(twice, "empty:"), ["/elsewhere/Y", "/Volumes/X", "X"])

        // On a case-sensitive volume, a folder x is not the root X: both count, and the root is in
        // Volumes, not in volumes. An accent encoded another way is the same name.
        let cased = FileIndex()
        let top2 = cased.addRoot("/")
        let vols = cased.add(ScannedEntry(name: "Volumes", isDirectory: true, size: 0, modified: 0), parent: top2)
        cased.add(ScannedEntry(name: "x", isDirectory: true, size: 0, modified: 0), parent: vols)
        cased.add(ScannedEntry(name: "Cafe\u{301}", isDirectory: true, size: 0, modified: 0), parent: vols)
        cased.add(ScannedEntry(name: "volumes", isDirectory: true, size: 0, modified: 0), parent: top2)
        cased.addRoot("/Volumes/X")
        cased.addRoot("/Volumes/Caf\u{E9}")
        cased.sortIfNeeded(force: true)
        XCTAssertEqual(cased.search(Query.parse("parent:/volumes")).total, 3) // Café, x and the root X
        XCTAssertEqual(cased.search(Query.parse("parent:/volumes case:X")).total, 1) // the root X only
        XCTAssertEqual(names(cased, "childcount:3"), ["Volumes"])
        XCTAssertEqual(names(cased, "empty: depth:1"), ["volumes"]) // the root X is in Volumes only

        // A root can sit inside another root's walk (/Users under /). parent: walks from every root
        // the path starts with, so the folder users that / holds isn't lost, and the root /users/Y
        // counts in users only.
        let overlap = FileIndex()
        let o = overlap.addRoot("/")
        let ou = overlap.add(ScannedEntry(name: "Users", isDirectory: true, size: 0, modified: 0), parent: o)
        overlap.add(ScannedEntry(name: "a.txt", isDirectory: false, size: 1, modified: 0), parent: ou)
        let ol = overlap.add(ScannedEntry(name: "users", isDirectory: true, size: 0, modified: 0), parent: o)
        overlap.add(ScannedEntry(name: "b.txt", isDirectory: false, size: 1, modified: 0), parent: ol)
        let usersRoot = overlap.addRoot("/Users")
        overlap.add(ScannedEntry(name: "r.txt", isDirectory: false, size: 1, modified: 0), parent: usersRoot)
        overlap.addRoot("/users/Y")
        overlap.sortIfNeeded(force: true)
        XCTAssertEqual(names(overlap, "parent:/users"), ["/users/Y", "a.txt", "b.txt", "r.txt"])
        XCTAssertEqual(names(overlap, "parent:/"), ["Users", "users"]) // the root /Users is the folder Users
        XCTAssertEqual(names(overlap, "childcount:2"), ["/", "users"])

        // One spelling per folder path; a path naming more than maxParentFolders folders (case
        // spellings on a case-sensitive volume) matches nothing, negated too.
        XCTAssertEqual(Query.parse("parent://data//Reports/").groups, Query.parse("parent:/data/reports").groups)
        XCTAssertEqual(Query.parse("parent://").groups, Query.parse("parent:/").groups)
        let many = FileIndex()
        let m = many.addRoot("/")
        let letters = Array("abcdefghijklm")
        for i in 0...Query.maxParentFolders {
            let name = String(letters.enumerated().map { i >> $0.offset & 1 == 1 ? Character($0.element.uppercased()) : $0.element })
            many.add(ScannedEntry(name: name, isDirectory: true, size: 0, modified: 0), parent: m)
        }
        many.addRoot("/abcdefghijklm/R") // a root in one of those folders
        many.sortIfNeeded(force: true)
        XCTAssertEqual(many.search(Query.parse("parent:/abcdefghijklm")).total, 0)
        XCTAssertEqual(many.search(Query.parse("!parent:/abcdefghijklm")).total, 0)
        XCTAssertEqual(many.search(Query.parse("parent:/")).total, Query.maxParentFolders + 1)
        // Only the folders a path ends at count, not those passed on the way.
        XCTAssertEqual(many.search(Query.parse("parent:/abcdefghijklm/missing")).total, 0)
        XCTAssertEqual(many.search(Query.parse("!parent:/abcdefghijklm/missing")).total, Query.maxParentFolders + 3)
        // A root's own folder is found by its exact path, with no limit: R is in abcdefghijklm only.
        XCTAssertEqual(names(many, "childcount:1"), ["abcdefghijklm"])

        // After these filters, ">" compares inside a group, as after size:.
        XCTAssertEqual(Query.parse("<depth:>2>").groups, Query.parse("depth:>2").groups)
        XCTAssertEqual(Query.parse("<!parents:>2 file:>").groups, Query.parse("!parents:>2 file:").groups)
        XCTAssertEqual(Query.parse("<childcount:>1>").groups, Query.parse("childcount:>1").groups)
        XCTAssertEqual(Query.parse("<empty:>").groups, Query.parse("empty:").groups)
        for bad in ["parent:", "parent:data", "infolder:~/x", "depth:", "depth:x", "parents:>", "childcount:-1",
                    "childcount:99999999999999999999", "!depth:2.5"] {
            XCTAssertEqual(Query.parse(bad).groups, [[.invalid(bad)]], bad)
        }
    }

    func testTypeMatchesKinds() {
        // Kind texts come from the system and are localized, so only this code's own "document" is
        // written out: the folder and PDF kinds are asked for, and the rest is checked against each
        // record's kind.
        let index = makeIndex()
        let root = index.lookup("/data")!
        let tool = index.add(ScannedEntry(name: "Tool.app", isDirectory: true, size: 0, modified: 0), parent: root)
        index.add(ScannedEntry(name: "Info.plist", isDirectory: false, size: 1, modified: 0), parent: tool)
        // A hidden folder named like a package is a folder, as a child or as a root (whose name is its path).
        index.add(ScannedEntry(name: ".app", isDirectory: true, size: 0, modified: 0), parent: root)
        index.addRoot("/Volumes/.app")
        for name in ["x.zzqq", ".bashrc", "trailing.", "noext", "a.8f3a9b2c4d5e6f7a8b9c", "R\u{E9}sum\u{E9}.PDF", "pic.jpeg"] {
            index.add(ScannedEntry(name: name, isDirectory: false, size: 1, modified: 0), parent: root)
        }
        index.sortIfNeeded(force: true)
        let folderKind = String(decoding: FileKinds.kindText(extension: "", isDirectory: true), as: UTF8.self)
        let pdfKind = String(decoding: FileKinds.kindText(extension: "pdf", isDirectory: false), as: UTF8.self)
        XCTAssertNotEqual(pdfKind, "document")
        XCTAssertEqual(names(index, "\"type:\(pdfKind)\""), ["q1 report.pdf", "R\u{E9}sum\u{E9}.PDF"])
        XCTAssertEqual(names(index, "\"TYPE:\(pdfKind.uppercased())\" !ext:pdf"), [])
        XCTAssertEqual(names(index, "\"type:\(folderKind)\""), [".app", "/data", "/Volumes/.app", "film", "Reports"]) // Tool.app is a package
        XCTAssertEqual(names(index, "\"type:\(folderKind)\" | \"type:\(pdfKind)\""),
                       [".app", "/data", "/Volumes/.app", "film", "q1 report.pdf", "Reports", "R\u{E9}sum\u{E9}.PDF"])
        for name in ["x.zzqq", ".bashrc", "trailing.", "noext", "a.8f3a9b2c4d5e6f7a8b9c"] {
            XCTAssertTrue(names(index, "type:document").contains(name), name) // no declared type
        }
        XCTAssertEqual(Query.parse("type:").groups, [[.invalid("type:")]])

        // Every record's kind through the same helpers, then each needle against it.
        func kind(_ id: Int) -> String {
            let r = index.records[id]
            let bytes: [UInt8] = index.lowerNames.withUnsafeBufferPointer { lower in
                let ext = FileKinds.extensionRange(lower, Int(r.lowerStart), Int(r.lowerLength))
                    .map { String(decoding: UnsafeBufferPointer(rebasing: lower[$0]), as: UTF8.self) } ?? ""
                return FileKinds.kindText(extension: ext, isDirectory: r.isDirectory)
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        let live = index.records.indices.filter { !index.records[$0].isDeleted }
        for needle in ["pdf", "folder", "document", "image", "movie", "text", "pdf*", "*e", "?older", "application"] {
            let expected = Set(live.filter { id in
                let k = kind(id)
                return needle.contains("*") || needle.contains("?") ? fnmatch(needle, k, 0) == 0 : k.contains(needle)
            }.map { Int32($0) })
            XCTAssertEqual(Set(index.matchingIds(Query.parse("type:\(needle)"))), expected, needle)
            XCTAssertEqual(Set(index.matchingIds(Query.parse("!type:\(needle)"))), Set(live.map { Int32($0) }).subtracting(expected), needle)
        }
        XCTAssertNotEqual(kind(Int(tool)), kind(Int(root))) // Tool.app has its own kind

        // The cached kinds grow with the index.
        index.add(ScannedEntry(name: "late.pdf", isDirectory: false, size: 1, modified: 0), parent: root)
        XCTAssertEqual(names(index, "\"type:\(pdfKind)\""), ["late.pdf", "q1 report.pdf", "R\u{E9}sum\u{E9}.PDF"])
    }

    func testGroups() {
        // makeIndex names: /data, Reports, q1 report.pdf, Q2 Report.docx, film, game1.mp4, notes.txt.
        let index = makeIndex()
        XCTAssertEqual(names(index, "<report pdf> | notes"), ["notes.txt", "q1 report.pdf"])
        XCTAssertEqual(names(index, "notes|<report pdf>"), ["notes.txt", "q1 report.pdf"])
        XCTAssertEqual(index.search(Query.parse("!<report pdf>")).total, 6)
        XCTAssertEqual(names(index, "<game | notes> !txt"), ["game1.mp4"])
        XCTAssertEqual(names(index, "report <pdf | docx>"), ["q1 report.pdf", "Q2 Report.docx"])
        XCTAssertEqual(names(index, "<<report>>"), names(index, "report"))
        XCTAssertEqual(names(index, "<report"), names(index, "report")) // left open: closes at the end
        XCTAssertEqual(names(index, "<>report"), names(index, "report"))
        // Comparisons inside groups: ">" right after ":" compares, a later ">" closes.
        XCTAssertEqual(names(index, "<size:>1gb>"), ["game1.mp4"])
        XCTAssertEqual(names(index, "<size:<1kb file:> | game"), ["game1.mp4", "notes.txt", "Q2 Report.docx"])
        XCTAssertEqual(names(index, "<regex:^game >"), ["game1.mp4"])
        XCTAssertEqual(names(index, "<film/ file:>"), ["game1.mp4", "notes.txt"])
        XCTAssertEqual(names(index, "<report folder:>|game"), ["game1.mp4", "Reports"])
        XCTAssertEqual(names(index, "<file:>report"), ["q1 report.pdf", "Q2 Report.docx"])
        XCTAssertEqual(names(index, "<file:><report>"), ["q1 report.pdf", "Q2 Report.docx"])
        XCTAssertEqual(names(index, "<!size:>1gb file:>"), ["notes.txt", "q1 report.pdf", "Q2 Report.docx"])
        // With no value after it, ">" closes: <size:> is an unreadable size: in its own group.
        XCTAssertEqual(names(index, "<size:> report"), [])
        XCTAssertEqual(names(index, "<size:>|notes"), ["notes.txt"])
        XCTAssertEqual(names(index, "regex:(?<n>game)"), ["game1.mp4"])
        // Any number of "!" before regex: keeps "|" inside the word, as before groups existed.
        XCTAssertEqual(Query.tokenize("!!regex:a|b"), [.word("!!regex:a|b")])
        XCTAssertEqual(Query.tokenize("!regex:a|b"), [.word("!regex:a|b")])
        XCTAssertEqual(Query.tokenize("!<a>"), [.open(negated: true), .word("a"), .close])
        XCTAssertEqual(Query.tokenize("!!<a>"), [.word("!!<a>")])
        // !<file: report> = folders, or files without "report".
        XCTAssertEqual(names(index, "!<file: report>"), ["/data", "film", "game1.mp4", "notes.txt", "Reports"])
        // An unreadable term stays unreadable under negation: !<report size:enormous> is !report.
        XCTAssertEqual(names(index, "!<report size:enormous>"), ["/data", "film", "game1.mp4", "notes.txt"])
        // Outside a group "<" and ">" are text; inside quotes too.
        XCTAssertEqual(Query.parse("report>").groups, [[.contains(Array("report>".utf8), negated: false)]])
        XCTAssertEqual(Query.parse("\"<a>\"").groups, [[.contains(Array("<a>".utf8), negated: false)]])
        // A path needle repeated by the expansion builds one table.
        XCTAssertEqual(CompiledQuery(Query.parse("<q1 report> | film/")).pathTerms.count, 1)
        XCTAssertEqual(names(index, "<q1 report> | film/"), ["game1.mp4", "notes.txt", "q1 report.pdf"])
    }

    func testGroupLimits() {
        let index = makeIndex()
        let eight = "<a b c d e f g h>"
        XCTAssertEqual(Query.parse(eight + "|" + eight).groups.count, 64)
        let sixteen = "<a b c d e f g h i j k l m n o p>"
        let tooBig = Query.parse([sixteen, sixteen, sixteen].joined(separator: "|"))
        XCTAssertEqual(tooBig.groups.count, 1)
        XCTAssertEqual(index.search(tooBig).total, 0)
        XCTAssertEqual(index.search(Query.parse(String(repeating: "<", count: 32) + "report")).total, 3)
        XCTAssertEqual(index.search(Query.parse(String(repeating: "<", count: 33) + "report")).total, 0)
        XCTAssertEqual(index.search(Query.parse(String(repeating: "!<", count: 50_000) + "report")).total, 0)
        XCTAssertEqual(index.search(Query.parse(String(repeating: "<a>|", count: 50_000) + "report")).total, 0)
        func zz(_ n: Int) -> String { Array(repeating: "zz", count: n).joined(separator: " ") }
        // A regex repeated by the expansion is compiled once; distinct regexes and paths are capped.
        let repeated = Query.parse("<regex:^q >|<" + zz(100) + ">")
        XCTAssertEqual(repeated.groups.count, 100)
        XCTAssertEqual(CompiledQuery(repeated).regexes.count, 1)
        XCTAssertEqual(index.search(repeated).total, 2) // q1 report.pdf, Q2 Report.docx
        // " | " with spaces: inside a regex: word "|" is alternation.
        let sixteenRegexes = (1...16).map { "regex:x\($0)" }.joined(separator: " | ")
        XCTAssertNotEqual(Query.parse(sixteenRegexes).groups, [[.invalid(sixteenRegexes)]])
        let seventeenRegexes = sixteenRegexes + " | regex:x17"
        XCTAssertEqual(Query.parse(seventeenRegexes).groups, [[.invalid(seventeenRegexes)]])
        let sixteenPaths = (1...16).map { "p\($0)/" }.joined(separator: "|")
        XCTAssertNotEqual(Query.parse(sixteenPaths).groups, [[.invalid(sixteenPaths)]])
        XCTAssertEqual(Query.parse(sixteenPaths + "|p17/").groups, [[.invalid(sixteenPaths + "|p17/")]])
        // A long needle repeated by the expansion is stored once.
        let long = String(repeating: "y", count: 10_000)
        let spread = Query.parse("<" + long + " q>|<" + zz(60) + ">")
        XCTAssertEqual(spread.groups.count, 120)
        XCTAssertLessThan(CompiledQuery(spread).bytes.count, 10_100)
        // A long ext: list repeated by the expansion shares its slots...
        let exts = "ext:" + (1...10).map { "e\($0)" }.joined(separator: ";") + ";mp4"
        let manyExts = Query.parse("<" + exts + " q>|<" + zz(18) + ">") // 18 × 12 + 18 × 2 = 252 tests
        XCTAssertEqual(manyExts.groups.count, 36)
        XCTAssertEqual(CompiledQuery(manyExts).slotStart.count, 11)
        XCTAssertEqual(index.search(manyExts).total, 0)
        // ...but each copy is tested per record, so past 256 tests per record nothing matches.
        let tooManyTests = "<" + exts + " q>|<" + zz(19) + ">" // 266 tests
        XCTAssertEqual(Query.parse(tooManyTests).groups, [[.invalid(tooManyTests)]])
        let ext256 = "ext:" + (1...256).map { "e\($0)" }.joined(separator: ";")
        XCTAssertNotEqual(Query.parse(ext256).groups, [[.invalid(ext256)]])
        let ext257 = ext256 + ";e257"
        XCTAssertEqual(Query.parse(ext257).groups, [[.invalid(ext257)]])
        let or257 = (1...257).map { "w\($0)" }.joined(separator: "|")
        XCTAssertEqual(Query.parse(or257).groups, [[.invalid(or257)]])
        // The limits hold for queries ANDed after parsing too (the search window adds its scope).
        let filmPaths = Query.parse((["film/"] + (1...15).map { "p\($0)/" }).joined(separator: "|"))
        let dataPaths = Query.parse((["data/"] + (1...15).map { "r\($0)/" }).joined(separator: "|"))
        XCTAssertEqual(index.search(filmPaths).total, 2)
        XCTAssertEqual(index.search(dataPaths).total, 6)
        XCTAssertEqual(index.search(filmPaths.and(dataPaths)).total, 0)
        let ext255txt = Query.parse("ext:" + (1...255).map { "e\($0)" }.joined(separator: ";") + ";txt")
        XCTAssertEqual(index.search(ext255txt).total, 1) // notes.txt; 256 tests
        XCTAssertEqual(index.search(Query.parse("notes").and(ext255txt)).total, 0) // 257 tests in all
        // More words than the term cap match nothing, before any is read; at the test budget is fine.
        XCTAssertEqual(index.search(Query.parse(zz(4097))).total, 0)
        XCTAssertEqual(Query.parse(zz(256)).groups.count, 256)
        XCTAssertEqual(Query.parse(zz(257)).groups, [[.invalid(zz(257))]])
        // Long words full of ">" or "|" stay cheap: each check reads only the word's first characters.
        let started = Date()
        _ = Query.parse("<regex:" + String(repeating: ">", count: 60_000))
        _ = Query.parse("<" + String(repeating: "!", count: 30_000) + String(repeating: ">", count: 30_000))
        _ = Query.parse("<size" + String(repeating: ">", count: 60_000))
        // Refused before the work: a huge ext: list is split only to 257 pieces, and 4,000 regex words
        // are counted before any is compiled.
        let hugeExt = "ext:" + (1...60_000).map { "e\($0)" }.joined(separator: ";")
        XCTAssertEqual(Query.parse(hugeExt).groups, [[.invalid(hugeExt)]])
        let manyRegexes = (1...4000).map { "regex:x\($0)" }.joined(separator: " ")
        XCTAssertEqual(Query.parse(manyRegexes).groups, [[.invalid(manyRegexes)]])
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        // One pattern repeated counts once.
        let sameRegex = Array(repeating: "regex:x", count: 40).joined(separator: " | ")
        XCTAssertNotEqual(Query.parse(sameRegex).groups, [[.invalid(sameRegex)]])
    }

    func testSizeNamesAndRanges() {
        // makeIndex: q1 report.pdf 2 MB, Q2 Report.docx 10 B, game1.mp4 3 GB, notes.txt 5 B.
        let index = makeIndex()
        XCTAssertEqual(names(index, "size:tiny"), ["notes.txt", "Q2 Report.docx"])
        XCTAssertEqual(names(index, "size:large"), ["q1 report.pdf"])
        XCTAssertEqual(names(index, "size:gigantic"), ["game1.mp4"])
        XCTAssertEqual(names(index, "size:empty"), [])
        XCTAssertEqual(names(index, "size:1mb..10gb"), ["game1.mp4", "q1 report.pdf"])
        XCTAssertEqual(names(index, "size:5..10"), ["notes.txt", "Q2 Report.docx"]) // both ends included
        XCTAssertEqual(names(index, "size:tiny..small"), ["notes.txt", "Q2 Report.docx"])
        XCTAssertEqual(names(index, "size:>large"), ["game1.mp4"])
        XCTAssertEqual(names(index, "size:<large"), ["notes.txt", "Q2 Report.docx"])
        XCTAssertEqual(names(index, "size:>=large"), ["game1.mp4", "q1 report.pdf"])
        XCTAssertEqual(names(index, "file: !size:tiny"), ["game1.mp4", "q1 report.pdf"])
        XCTAssertEqual(names(index, "size:tiny | size:gigantic"), ["game1.mp4", "notes.txt", "Q2 Report.docx"])

        // Boundaries: empty is 0 bytes only, tiny is 1 byte to 10 KB.
        let edge = FileIndex()
        let root = edge.addRoot("/e")
        for (name, size) in [("zero", Int64(0)), ("one", Int64(1)), ("tenk", Int64(10 << 10)), ("over", Int64((10 << 10) + 1))] {
            edge.add(ScannedEntry(name: name, isDirectory: false, size: size, modified: 0), parent: root)
        }
        edge.sortIfNeeded(force: true)
        XCTAssertEqual(names(edge, "size:empty"), ["zero"])
        XCTAssertEqual(names(edge, "size:tiny"), ["one", "tenk"])
        XCTAssertEqual(names(edge, "size:small"), ["over"])
        // Negative sizes are unreadable, with or without a unit, also inside a range.
        XCTAssertEqual(names(index, "size:0..2.5gb"), ["notes.txt", "q1 report.pdf", "Q2 Report.docx"]) // decimals still work
        for q in ["size:-1", "size:-1..10", "size:-1b..10b", "size:>=-1..10", "!size:-1..10", "size:5..-1",
                  "size:0...2gb", "size:0....2gb", "size:1..2..3"] {
            XCTAssertEqual(Query.parse(q).groups, [[.invalid(q)]], q)
        }
    }

    func testDatePeriodsAndRanges() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 1 // weeks start on Sunday: this week is Sun 10-11 to Sat 10-17
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Int64 {
            Int64(cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!.timeIntervalSince1970)
        }
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))! // a Thursday
        let index = FileIndex()
        let root = index.addRoot("/x", modified: 0)
        for (name, time) in [("a", at(2026, 10, 15, 10)), ("b", at(2026, 10, 12)), ("c", at(2026, 10, 6)),
                             ("d", at(2026, 9, 20)), ("e", at(2025, 6, 1)), ("f", at(2026, 10, 15, 1))] {
            index.add(ScannedEntry(name: name, isDirectory: false, size: 1, modified: time), parent: root)
        }
        index.sortIfNeeded(force: true)
        func dm(_ q: String) -> [String] {
            index.search(Query.parse("file: dm:" + q, now: now, calendar: cal), options: SearchOptions(limit: 100))
                .hits.map(\.name)
        }
        XCTAssertEqual(dm("today"), ["a", "f"])
        XCTAssertEqual(dm("thisweek"), ["a", "b", "f"])
        XCTAssertEqual(dm("currentweek"), ["a", "b", "f"])
        XCTAssertEqual(dm("lastweek"), ["c"])
        XCTAssertEqual(dm("prevweek"), ["c"])
        XCTAssertEqual(dm("thismonth"), ["a", "b", "c", "f"])
        XCTAssertEqual(dm("lastmonth"), ["d"])
        XCTAssertEqual(dm("thisyear"), ["a", "b", "c", "d", "f"])
        XCTAssertEqual(dm("lastyear"), ["e"])
        XCTAssertEqual(dm("2025"), ["e"])
        XCTAssertEqual(dm("2026-09"), ["d"])
        XCTAssertEqual(dm("2026-10-05..2026-10-12"), ["b", "c"])
        XCTAssertEqual(dm("2026-09..2026-10-06"), ["c", "d"])
        XCTAssertEqual(dm("last6hours"), ["a"])
        XCTAssertEqual(dm("last7days"), ["a", "b", "f"]) // 10-09 through today
        XCTAssertEqual(dm("past3weeks"), ["a", "b", "c", "f"]) // from 09-24
        XCTAssertEqual(dm(">lastmonth"), ["a", "b", "c", "f"])
        XCTAssertEqual(dm("<thisyear"), ["e"])
        XCTAssertEqual(dm("<=lastweek"), ["c", "d", "e"])
        // One ".." only; a long chain is rejected without deep recursion.
        XCTAssertEqual(dm("2026..2026..2026"), [])
        let chain = "dm:" + Array(repeating: "2026", count: 50_000).joined(separator: "..")
        XCTAssertEqual(Query.parse(chain).groups, [[.invalid(chain)]])
    }

    func testRollingWindowsIncludeFutureDates() {
        // Everything's default: "last 6 hours" runs from 6 hours ago with no end.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
        let t = Int64(now.timeIntervalSince1970)
        let index = FileIndex()
        let root = index.addRoot("/x", modified: 0)
        let day: Int64 = 86_400
        let files: [(String, Int64)] = [("past", t - 3600), ("old", t - day * 30), ("tomorrow", t + day),
                                        ("future", t + day * 400)]
        for (name, time) in files {
            index.add(ScannedEntry(name: name, isDirectory: false, size: 1, modified: time), parent: root)
        }
        index.sortIfNeeded(force: true)
        func dm(_ q: String) -> [String] {
            index.search(Query.parse("file: " + q, now: now, calendar: cal), options: SearchOptions(limit: 100))
                .hits.map(\.name)
        }
        XCTAssertEqual(dm("dm:last6hours"), ["future", "past", "tomorrow"])
        XCTAssertEqual(dm("dm:last7days"), ["future", "past", "tomorrow"])
        XCTAssertEqual(dm("!dm:last7days"), ["old"])
        XCTAssertEqual(dm("dm:<last7days"), ["old"])
        // Comparisons against a rolling window compare with its cutoff.
        XCTAssertEqual(dm("dm:>last7days"), ["future", "past", "tomorrow"])
        XCTAssertEqual(dm("dm:>=last7days"), ["future", "past", "tomorrow"])
        XCTAssertEqual(dm("dm:<=last7days"), ["old"])
        // A rolling window can't be a range endpoint.
        for q in ["dm:2026..last7days", "dm:>2026..last7days", "dm:last7days..2026", "dm:<=past2weeks..today"] {
            XCTAssertEqual(Query.parse(q, now: now, calendar: cal).groups, [[.invalid(q)]], q)
        }
        XCTAssertEqual(dm("dm:today"), ["past"]) // calendar days still end at midnight
    }

    func testDayEdgesWhenATimeChangeSkipsMidnight() {
        // Sao Paulo skipped from 00:00 to 01:00 on 2018-11-04, so that day began at 01:00.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Int64 {
            Int64(cal.date(from: DateComponents(year: 2018, month: 11, day: d, hour: h, minute: m))!.timeIntervalSince1970)
        }
        let now = cal.date(from: DateComponents(year: 2018, month: 11, day: 4, hour: 12))!
        let index = FileIndex()
        let root = index.addRoot("/x", modified: 0)
        for (name, time) in [("noon4", at(4, 12)), ("early5", at(5, 0, 30)), ("late3", at(3, 23, 30))] {
            index.add(ScannedEntry(name: name, isDirectory: false, size: 1, modified: time), parent: root)
        }
        index.sortIfNeeded(force: true)
        func dm(_ q: String) -> [String] {
            index.search(Query.parse("file: dm:" + q, now: now, calendar: cal), options: SearchOptions(limit: 100))
                .hits.map(\.name)
        }
        XCTAssertEqual(dm("today"), ["noon4"])
        XCTAssertEqual(dm("2018-11-04"), ["noon4"])
        XCTAssertEqual(dm("2018-11-05"), ["early5"])
        XCTAssertEqual(dm("yesterday"), ["late3"])
        // Starts at the start of 11-03 (not 01:00); rolling windows are open-ended, so 11-05 counts.
        XCTAssertEqual(dm("last2days"), ["early5", "late3", "noon4"])
    }

    func testNegatedFilters() {
        let index = makeIndex()
        XCTAssertEqual(names(index, "file: !size:>1gb"), ["notes.txt", "q1 report.pdf", "Q2 Report.docx"])
        XCTAssertEqual(names(index, "!file:"), ["/data", "film", "Reports"])
        XCTAssertEqual(names(index, "report !folder:"), ["q1 report.pdf", "Q2 Report.docx"])
        XCTAssertEqual(names(index, "file: dm:<1970-01-02").count, 4)
        XCTAssertEqual(names(index, "file: !dm:<1970-01-02"), [])
    }

    func testRegexAlternationIsNotSplit() {
        XCTAssertEqual(names(makeIndex(), "regex:\\.(pdf|mp4)$"), ["game1.mp4", "q1 report.pdf"])
        XCTAssertEqual(Query.parse("regex:^(a|b)$").groups.count, 1)
    }

    func testEmptyingAHugeFolderIsLinear() {
        let index = FileIndex()
        let root = index.addRoot("/big")
        for i in 0..<100_000 {
            index.add(ScannedEntry(name: "f\(i)", isDirectory: false, size: 0, modified: 0), parent: root)
        }
        let started = Date()
        index.replaceChildren(of: root, with: [ScannedEntry(name: "f7", isDirectory: false, size: 1, modified: 0)])
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
        XCTAssertEqual(index.liveCount, 2)
        XCTAssertEqual(index.childIds(of: root).count, 1)
        XCTAssertNotNil(index.lookup("/big/f7"))
    }

    /// A tree with nested folders, accents and a root named "/", for brute-force comparisons.
    func makeDeepIndex() -> FileIndex {
        let index = FileIndex()
        let root = index.addRoot("/")
        var dirs: [Int32] = [root]
        let names = ["Users", "me", "Library", "Caches", "film", "Game Film", "thrée", "ünï", "lib", "x"]
        for (i, name) in names.enumerated() {
            let parent = dirs[i / 2]
            dirs.append(index.add(ScannedEntry(name: name, isDirectory: true, size: 0, modified: 0), parent: parent))
        }
        for (i, dir) in dirs.enumerated() {
            for file in ["a\(i).txt", "lib\(i).dylib", "Info.plist", "IMG_\(1000 + i).jpg", "thrée\(i).md", "\(i)"] {
                index.add(ScannedEntry(name: file, isDirectory: false, size: 0, modified: 0), parent: dir)
            }
        }
        index.sortIfNeeded(force: true)
        return index
    }

    func testSortOrdersMatchBruteForce() {
        let index = makeDeepIndex()
        let root = index.lookup("/")!
        // Siblings where path text order and folder-first order differ: "a b" < "a/" as text.
        let a = index.add(ScannedEntry(name: "a", isDirectory: true, size: 0, modified: 0), parent: root)
        index.add(ScannedEntry(name: "z.txt", isDirectory: false, size: 7, modified: 5), parent: a)
        index.add(ScannedEntry(name: "a b", isDirectory: true, size: 0, modified: 0), parent: root)
        index.add(ScannedEntry(name: "a-b", isDirectory: false, size: 7, modified: 9), parent: root)
        index.addRoot("/Volumes/X")
        index.sortIfNeeded(force: true)

        // Path order by its definition: compare the folder chains part by part, a folder first.
        func chain(_ id: Int32) -> [Int32] {
            var c = [id]
            while index.records[Int(c.last!)].parent >= 0 { c.append(index.records[Int(c.last!)].parent) }
            return c.reversed()
        }
        func pathLess(_ x: Int32, _ y: Int32) -> Bool {
            let cx = chain(x), cy = chain(y)
            for (p, q) in zip(cx, cy) where p != q { return index.lowerBytesLess(p, q) }
            return cx.count < cy.count
        }
        func live() -> [Int32] { index.records.indices.filter { !index.records[$0].isDeleted }.map { Int32($0) } }
        func sorted(_ sort: SortKey, _ descending: Bool, limit: Int = 10_000, offset: Int = 0) -> [String] {
            index.search(Query.parse(""), options: SearchOptions(limit: limit, offset: offset, sort: sort,
                                                                 descending: descending)).hits.map(\.path)
        }
        func check(_ label: String) {
            let byPath = live().sorted(by: pathLess).map { index.path(of: $0) }
            XCTAssertEqual(sorted(.path, false), byPath, label)
            XCTAssertEqual(sorted(.path, true), byPath.reversed(), label)
            for (sort, key) in [(SortKey.size, { (r: Record) in r.size }), (.modified, { (r: Record) in r.modified })] {
                let ids = live().sorted { key(index.records[Int($0)]) != key(index.records[Int($1)])
                    ? key(index.records[Int($0)]) < key(index.records[Int($1)]) : $0 < $1 }
                let asc = ids.map { index.path(of: $0) }
                XCTAssertEqual(sorted(sort, false), asc, label)
                XCTAssertEqual(sorted(sort, true), asc.reversed(), label)
                // A short page takes the heap; pages join up exactly, both ways.
                for desc in [false, true] {
                    let all = desc ? Array(asc.reversed()) : asc
                    XCTAssertEqual(sorted(sort, desc, limit: 5), Array(all.prefix(5)), label)
                    XCTAssertEqual(sorted(sort, desc, limit: 5) + sorted(sort, desc, limit: 7, offset: 5),
                                   Array(all.prefix(12)), label)
                }
            }
            XCTAssertEqual(sorted(.path, false, limit: 5) + sorted(.path, false, limit: 7, offset: 5),
                           Array(byPath.prefix(12)), label)
        }
        XCTAssertLessThan(sorted(.path, false).firstIndex(of: "/a/z.txt")!, sorted(.path, false).firstIndex(of: "/a b")!)
        check("fresh")
        // Added records (no name sort yet) rebuild the path order; a removal leaves it as it was.
        index.add(ScannedEntry(name: "A0", isDirectory: false, size: 3, modified: 1), parent: a)
        index.add(ScannedEntry(name: "mid", isDirectory: false, size: 3, modified: 1), parent: root)
        check("after add")
        index.remove(index.lookup("/a/z.txt")!)
        check("after remove")
    }

    func testTypeAndExtensionSortsMatchBruteForce() {
        let index = makeDeepIndex()
        let root = index.lookup("/")!
        let tool = index.add(ScannedEntry(name: "Tool.app", isDirectory: true, size: 0, modified: 0), parent: root)
        index.add(ScannedEntry(name: "Info.plist", isDirectory: false, size: 1, modified: 0), parent: tool)
        for name in ["b.txt", "A.TXT", ".bashrc", "noext", "x.zzqq", "z.pdf"] {
            index.add(ScannedEntry(name: name, isDirectory: false, size: 1, modified: 0), parent: root)
        }
        index.sortIfNeeded(force: true)

        func live() -> [Int32] { index.records.indices.filter { !index.records[$0].isDeleted }.map { Int32($0) } }
        func nameKey(_ id: Int32) -> Int64 { index.rank[Int(id)] >= 0 ? Int64(index.rank[Int(id)]) : Int64.max }
        // By definition: the column's text (lowercase bytes), then the name's place, then the id.
        func expected(_ text: (Int32) -> String) -> [String] {
            live().sorted { a, b in
                let ta = Array(FileIndex.searchForm(text(a)).utf8), tb = Array(FileIndex.searchForm(text(b)).utf8)
                if ta != tb { return ta.lexicographicallyPrecedes(tb) }
                if nameKey(a) != nameKey(b) { return nameKey(a) < nameKey(b) }
                return a < b
            }.map { index.path(of: $0) }
        }
        func sorted(_ sort: SortKey, _ descending: Bool, limit: Int = 10_000, offset: Int = 0) -> [String] {
            index.search(Query.parse(""), options: SearchOptions(limit: limit, offset: offset, sort: sort,
                                                                 descending: descending)).hits.map(\.path)
        }
        func kind(_ id: Int32) -> String {
            FileKinds.kindName(ofName: index.name(of: id), isDirectory: index.records[Int(id)].isDirectory)
        }
        func ext(_ id: Int32) -> String {
            FileKinds.extensionName(ofName: index.name(of: id), isDirectory: index.records[Int(id)].isDirectory)
        }
        func check(_ label: String) {
            for (sort, text) in [(SortKey.type, kind), (.ext, ext)] {
                let asc = expected(text)
                XCTAssertEqual(sorted(sort, false), asc, "\(sort) \(label)")
                XCTAssertEqual(sorted(sort, true), asc.reversed(), "\(sort) \(label)")
                XCTAssertEqual(sorted(sort, false, limit: 5) + sorted(sort, false, limit: 7, offset: 5),
                               Array(asc.prefix(12)), "\(sort) \(label)")
                XCTAssertEqual(sorted(sort, true, limit: 5), Array(asc.reversed().prefix(5)), "\(sort) \(label)")
            }
        }
        check("fresh")
        // Folders have no extension and come first; files sharing one keep name order.
        let byExt = sorted(.ext, false)
        XCTAssertLessThan(byExt.firstIndex(of: "/Tool.app")!, byExt.firstIndex(of: "/A.TXT")!)
        XCTAssertLessThan(byExt.firstIndex(of: "/A.TXT")!, byExt.firstIndex(of: "/b.txt")!)
        XCTAssertEqual(ext(index.lookup("/A.TXT")!), "txt")
        XCTAssertEqual(kind(index.lookup("/noext")!), "Document")
        // Records added since the last name sort go last among their kind or extension.
        index.add(ScannedEntry(name: "aaa.txt", isDirectory: false, size: 1, modified: 0), parent: root)
        check("after add")
    }

    func testPathTermsMatchBruteForce() {
        let index = makeDeepIndex()
        let all = (0..<Int32(index.records.count)).filter { !index.records[Int($0)].isDeleted }
        for needle in ["lib", "users/me", "me/library/c", "film/game", "/a", "e/", "/", "thrée/thr", "ünï/", "x/a1", "nothing-here"] {
            let n = FileIndex.searchForm(needle)
            let expected = Set(all.filter { FileIndex.searchForm(index.path(of: $0)).contains(n) })
            let got = Set(index.matchingIds(Query(groups: [[.pathContains(Array(n.utf8), negated: false)]])))
            XCTAssertEqual(got, expected, "path:\(needle)")
        }
    }

    func testRegexMatchesBruteForceAcrossAccents() throws {
        let index = makeDeepIndex()
        let all = (0..<Int32(index.records.count)).filter { !index.records[Int($0)].isDeleted }
        for pattern in ["^[0-9]+$", "\\.plist$", "^lib.*\\.dylib$", "^img_\\d+", "ée\\d", "^thrée\\d+\\.md$", "^a1", "(jpg|md)$",
                        // Not line-safe, or spanning names: these take the per-name fallback.
                        "a[^q]*txt", "^a(?=1)", "^(?i)A", "\\.txt\\s?$",
                        // Escapes with arguments and POSIX classes (no literal can be proven).
                        "thr\\u00e9e", "^\\x61\\d", "[[:digit:]]\\.txt", "zzz"] {
            let re = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let expected = Set(all.filter { id in
                let s = FileIndex.searchForm(index.name(of: id))
                return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
            })
            let got = Set(index.matchingIds(Query.parse("regex:" + pattern)))
            XCTAssertEqual(got, expected, "regex:\(pattern)")
            XCTAssertFalse(pattern != "zzz" && got.isEmpty, "regex:\(pattern) should match something")
        }
    }

    func testRequiredLiteral() {
        XCTAssertEqual(RegexSupport.requiredLiteral("^IMG_\\d+"), "img_")
        XCTAssertEqual(RegexSupport.requiredLiteral("\\.plist$"), ".plist")
        XCTAssertEqual(RegexSupport.requiredLiteral("^lib.*\\.dylib$"), ".dylib")
        XCTAssertEqual(RegexSupport.requiredLiteral("colou?r"), "colo")
        XCTAssertEqual(RegexSupport.requiredLiteral("ab{0,2}cd"), "cd")
        XCTAssertNil(RegexSupport.requiredLiteral("^[0-9]+$"))
        XCTAssertNil(RegexSupport.requiredLiteral("(jpg|png)$"))
        XCTAssertNil(RegexSupport.requiredLiteral("a|b"))
        XCTAssertEqual(RegexSupport.requiredLiteral("x(abc)?yz"), "yz")
    }

    func testLineSafety() {
        XCTAssertTrue(RegexSupport.isLineSafe("^img_\\d+\\.jpg$"))
        XCTAssertTrue(RegexSupport.isLineSafe("(jpg|png)$"))
        XCTAssertFalse(RegexSupport.isLineSafe("^a(?=1)"))
        XCTAssertFalse(RegexSupport.isLineSafe("\\Afoo"))
        XCTAssertFalse(RegexSupport.isLineSafe("a\\sb"))
        XCTAssertFalse(RegexSupport.isLineSafe("a\\cJb"))
    }

    func testRequiredLiteralGivesUpOnEscapesWithArguments() {
        for p in ["caf\\u00e9", "\\x41bc", "\\pLfoo", "\\cJx", "\\0101", "(?<n>a)\\k<n>",
                  "[[:digit:]]foo", "[a[bc]]x", "(?x)ab cd", "\\Qa.b\\E"] {
            XCTAssertNil(RegexSupport.requiredLiteral(p), p)
        }
        XCTAssertEqual(RegexSupport.requiredLiteral("img_\\d+\\.jpg"), "img_")
    }

    func testNegatedRegexWithAlternationStaysOneTerm() {
        let q = Query.parse("!regex:\\.(txt|md)$")
        XCTAssertEqual(q.groups.count, 1)
        XCTAssertEqual(q.groups[0].count, 1)
        let names = makeDeepIndex().search(Query.parse("file: !regex:\\.(txt|md|dylib|plist|jpg)$"),
                                           options: SearchOptions(limit: 1000)).hits.map(\.name)
        XCTAssertFalse(names.isEmpty)
        XCTAssertTrue(names.allSatisfy { Int($0) != nil }, "\(names)") // only the bare-number files remain
    }

    func testVeryLongPathNeedlesMatchNothingCheaply() {
        let index = makeDeepIndex()
        let huge = String(repeating: "x", count: 5000)
        XCTAssertEqual(index.search(Query.parse("path:" + huge)).total, 0)
        let medium = "/users/me/" + String(repeating: "y", count: 300)
        XCTAssertEqual(index.search(Query.parse("path:" + medium)).total, 0)
    }

    func testOtherLineTerminatorsDoNotSplitNames() {
        let index = FileIndex()
        let root = index.addRoot("/t")
        for name in ["a\rb", "b", "c\u{2028}b", "d\u{85}b"] {
            index.add(ScannedEntry(name: name, isDirectory: false, size: 0, modified: 0), parent: root)
        }
        index.sortIfNeeded(force: true)
        XCTAssertEqual(index.search(Query.parse("regex:^b")).hits.map(\.name), ["b"])
    }

    func testScopes() {
        let index = FileIndex()
        let mac = index.addRoot("/")
        let users = index.add(ScannedEntry(name: "Users", isDirectory: true, size: 0, modified: 0), parent: mac)
        index.add(ScannedEntry(name: "plan.txt", isDirectory: false, size: 1, modified: 0), parent: users)
        let lib = index.add(ScannedEntry(name: "Library", isDirectory: true, size: 0, modified: 0), parent: users)
        let cloud = index.add(ScannedEntry(name: "CloudStorage", isDirectory: true, size: 0, modified: 0), parent: lib)
        let gdrive = index.add(ScannedEntry(name: "GoogleDrive-me@x.com", isDirectory: true, size: 0, modified: 0), parent: cloud)
        index.add(ScannedEntry(name: "plan.docx", isDirectory: false, size: 1, modified: 0), parent: gdrive)
        let onedrive = index.add(ScannedEntry(name: "OneDrive-Work", isDirectory: true, size: 0, modified: 0), parent: cloud)
        index.add(ScannedEntry(name: "plan.xlsx", isDirectory: false, size: 1, modified: 0), parent: onedrive)
        let work = index.addRoot("/Volumes/Work Disk")
        index.add(ScannedEntry(name: "plan.mov", isDirectory: false, size: 1, modified: 0), parent: work)
        index.sortIfNeeded(force: true)

        func scoped(_ q: String, _ scope: SearchScope) -> [String] {
            index.search(Query.parse(q).and(Query.parse(scope.query)), options: SearchOptions(limit: 100)).hits.map(\.name)
        }
        XCTAssertEqual(scoped("plan", .all), ["plan.docx", "plan.mov", "plan.txt", "plan.xlsx"])
        XCTAssertEqual(scoped("plan", .thisMac), ["plan.docx", "plan.txt", "plan.xlsx"])
        XCTAssertEqual(scoped("plan", .cloud), ["plan.docx", "plan.xlsx"])
        XCTAssertEqual(scoped("plan", .cloudFolder("/Users/Library/CloudStorage/GoogleDrive-me@x.com")), ["plan.docx"])
        XCTAssertEqual(scoped("plan", .cloudFolder("/Users/Library/CloudStorage/OneDrive-Work")), ["plan.xlsx"])
        XCTAssertEqual(scoped("plan", .drive("/Volumes/Work Disk")), ["plan.mov"])
        // A typed "|" must not join the scope's group: the scope still applies.
        XCTAssertEqual(scoped("plan |", .drive("/Volumes/Work Disk")), ["plan.mov"])
        XCTAssertEqual(names(index, "plan \"drive:work disk\""), ["plan.mov"])
        XCTAssertEqual(names(index, "plan !drive:work disk"), [])  // "disk" becomes its own word
        XCTAssertEqual(names(index, "plan !\"drive:Work Disk\""), ["plan.docx", "plan.txt", "plan.xlsx"])
    }

    func testDriveKeywordAndScopeChoices() {
        XCTAssertEqual(Query.parse("drive:CRASHBOX").groups, [[.pathContains(Array("/volumes/crashbox/".utf8), negated: false)]])
        XCTAssertEqual(Query.parse("drive:/Volumes/").groups.count, 1)
        XCTAssertEqual(Query.parse("drive:").groups, [[.invalid("drive:")]])

        let none = SearchScope.choices(roots: ["/", "/Volumes/CRASHBOX"], home: "/h", exists: { _ in false })
        XCTAssertEqual(none, [.all, .thisMac, .drive("/Volumes/CRASHBOX")])
        let withCloud = SearchScope.choices(roots: ["/"], home: "/h", exists: { $0 == "/h/Library/CloudStorage" })
        XCTAssertEqual(withCloud, [.all, .thisMac, .cloud])

        let accounts = SearchScope.choices(
            roots: ["/", "/Volumes/CRASHBOX"], home: "/h",
            exists: { $0 == "/h/Library/CloudStorage" || $0 == "/h/Library/Mobile Documents/com~apple~CloudDocs" },
            list: { $0 == "/h/Library/CloudStorage" ? ["OneDrive-Baylor", ".DS_Store", "GoogleDrive-me@x.com", "Box-Box"] : [] })
        XCTAssertEqual(accounts, [.all, .thisMac, .cloud,
                                  .cloudFolder("/h/Library/CloudStorage/Box-Box"),
                                  .cloudFolder("/h/Library/CloudStorage/GoogleDrive-me@x.com"),
                                  .cloudFolder("/h/Library/CloudStorage/OneDrive-Baylor"),
                                  .cloudFolder("/h/Library/Mobile Documents"),
                                  .drive("/Volumes/CRASHBOX")])
        XCTAssertEqual(accounts.map(\.title), ["All", "This Mac", "Cloud", "Box", "Google Drive (me@x.com)",
                                               "OneDrive (Baylor)", "iCloud Drive", "CRASHBOX"])
        XCTAssertEqual(SearchScope.cloudFolder("/h/Library/CloudStorage/Dropbox").title, "Dropbox")

        for scope in [SearchScope.all, .thisMac, .cloud, .drive("/Volumes/My Drive"),
                      .cloudFolder("/h/Library/CloudStorage/GoogleDrive-me@x.com")] {
            XCTAssertEqual(SearchScope(id: scope.id), scope)
        }
        XCTAssertNil(SearchScope(id: "drive:"))
        XCTAssertNil(SearchScope(id: "cloud:"))
        XCTAssertEqual(SearchScope.drive("/Volumes/CRASHBOX").title, "CRASHBOX")
    }

    func testFileTypeFilters() {
        let index = makeIndex()
        func filtered(_ q: String, _ f: FileFilter) -> [String] {
            index.search(Query.parse(q).and(Query.parse(f.query)), options: SearchOptions(limit: 100)).hits.map(\.name)
        }
        XCTAssertEqual(filtered("", .video), ["game1.mp4"])
        XCTAssertEqual(filtered("", .document), ["notes.txt", "q1 report.pdf", "Q2 Report.docx"])
        XCTAssertEqual(filtered("report", .document), ["q1 report.pdf", "Q2 Report.docx"])
        XCTAssertEqual(filtered("", .folder), ["/data", "film", "Reports"]) // the root is a folder too
        XCTAssertEqual(filtered("", .audio), [])
        XCTAssertEqual(names(index, "!video: film/"), ["notes.txt"])
        XCTAssertEqual(names(index, "VIDEO:"), ["game1.mp4"])
        for f in FileFilter.allCases where f != .everything && f != .folder {
            XCTAssertEqual(FileFilter.forKeyword(f.keyword!), f)
            XCTAssertFalse(FileFilter.extensions[f]!.isEmpty)
        }
        XCTAssertEqual(FileFilter.compressed.title, "Compressed")
    }

    func testConfigLocations() throws {
        var config = ServiceConfig()
        XCTAssertEqual(config.resolvedRoots(defaults: ["/", "/Volumes/A"]), ["/", "/Volumes/A"])
        config.includeExternalVolumes = false
        XCTAssertEqual(config.resolvedRoots(defaults: ["/", "/Volumes/A"]), ["/"])
        config.includeExternalVolumes = nil
        config.extraRoots = ["/Volumes/No Such Share"]
        XCTAssertEqual(config.resolvedRoots(defaults: ["/"]), ["/", "/Volumes/No Such Share"])
        // A folder already inside an indexed root adds nothing (the Locations window says so).
        let current = IndexService.normalizeRoots(["/"], exclusions: Scanner.defaultExclusions)
        XCTAssertEqual(IndexService.normalizeRoots(current + ["/Users/someone/Documents"],
                                                   exclusions: Scanner.defaultExclusions), current)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mev-config-\(UUID().uuidString)/config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try config.save(to: url)
        XCTAssertEqual(ServiceConfig.load(from: url).extraRoots, ["/Volumes/No Such Share"])
    }

    func testTempFiles() {
        let index = FileIndex()
        let root = index.addRoot("/")
        func dir(_ name: String, _ parent: Int32) -> Int32 {
            index.add(ScannedEntry(name: name, isDirectory: true, size: 0, modified: 0), parent: parent)
        }
        func file(_ name: String, _ parent: Int32) {
            index.add(ScannedEntry(name: name, isDirectory: false, size: 1, modified: 0), parent: parent)
        }
        let proj = dir("proj", root)
        file("report.md", proj)
        file("report.md.swp", proj)
        file("~$report.docx", proj)
        file(".DS_Store", proj)
        let nm = dir("node_modules", proj)
        let pkg = dir("report-lib", nm)
        file("report.js", pkg)
        let priv = dir("private", root)
        let tmp = dir("tmp", priv)
        file("report.txt", tmp)
        index.sortIfNeeded(force: true)

        XCTAssertEqual(names(index, "report !temp:"), ["report.md"])
        XCTAssertEqual(names(index, "report temp:"),
                       ["report-lib", "report.js", "report.md.swp", "report.txt", "~$report.docx"])
        XCTAssertEqual(names(index, "report").count, 6)
        // The cached mask follows changes.
        file("report.tmp", proj)
        XCTAssertEqual(names(index, "report !temp:"), ["report.md"])
        file("report2.md", proj)
        XCTAssertEqual(names(index, "report !temp:"), ["report.md", "report2.md"])
    }
}
