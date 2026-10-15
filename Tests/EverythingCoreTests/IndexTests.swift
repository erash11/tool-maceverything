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
        let root = index.addRoot("/x")
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
        let today = Int64(cal.startOfDay(for: now).timeIntervalSince1970)
        index.add(ScannedEntry(name: "new.txt", isDirectory: false, size: 1, modified: today + 60), parent: root)
        index.add(ScannedEntry(name: "old.txt", isDirectory: false, size: 1, modified: today - 86_400 * 3), parent: root)
        let q = Query.parse("dm:today", now: now, calendar: cal)
        XCTAssertEqual(index.search(q).hits.map(\.name), ["new.txt"])
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
}
