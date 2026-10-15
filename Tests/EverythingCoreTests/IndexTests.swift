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
        XCTAssertTrue(Query.parse("size:nanb").isEmpty)
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
                        "a[^q]*txt", "^a(?=1)", "^(?i)A", "\\.txt\\s?$", "zzz"] {
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
}
