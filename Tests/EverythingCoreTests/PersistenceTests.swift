import XCTest
@testable import EverythingCore

final class PersistenceTests: XCTestCase {
    func testRoundTrip() throws {
        let index = IndexTests().makeIndex()
        index.remove(index.lookup("/data/film/notes.txt")!)
        index.volumeState["/data"] = .init(volumeUUID: "ABC", lastEventId: 42)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("index.bin")
        try index.save(to: url)

        let loaded = try FileIndex.load(from: url)
        XCTAssertEqual(loaded.liveCount, index.liveCount)
        XCTAssertEqual(loaded.volumeState["/data"], .init(volumeUUID: "ABC", lastEventId: 42))
        XCTAssertNil(loaded.lookup("/data/film/notes.txt"))
        let names = loaded.search(Query.parse("report")).hits.map(\.name)
        XCTAssertEqual(names, ["q1 report.pdf", "Q2 Report.docx", "Reports"])

        // Loaded indexes stay editable.
        let film = loaded.lookup("/data/film")!
        loaded.add(ScannedEntry(name: "new.mov", isDirectory: false, size: 1, modified: 1), parent: film)
        XCTAssertNotNil(loaded.lookup("/data/film/new.mov"))
    }

    func testSnapshotIsUnaffectedByLaterChanges() throws {
        // The daemon writes a snapshot off its update queue while changes keep applying.
        let index = IndexTests().makeIndex()
        index.volumeState["/data"] = .init(volumeUUID: "ABC", lastEventId: 7)
        let snap = index.snapshot()
        let film = index.lookup("/data/film")!
        index.add(ScannedEntry(name: "after.mov", isDirectory: false, size: 1, modified: 1), parent: film)
        index.remove(index.lookup("/data/film/notes.txt")!)
        index.volumeState["/data"] = .init(volumeUUID: "ABC", lastEventId: 8)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("index.bin")
        try snap.save(to: url)
        let loaded = try FileIndex.load(from: url)
        XCTAssertEqual(loaded.liveCount, 7)
        XCTAssertNotNil(loaded.lookup("/data/film/notes.txt"))
        XCTAssertNil(loaded.lookup("/data/film/after.mov"))
        XCTAssertEqual(loaded.volumeState["/data"]?.lastEventId, 7)
        // The live index has both changes.
        XCTAssertNotNil(index.lookup("/data/film/after.mov"))
        XCTAssertNil(index.lookup("/data/film/notes.txt"))
    }

    func testRejectsGarbage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("hello world, not an index".utf8).write(to: url)
        XCTAssertThrowsError(try FileIndex.load(from: url))
    }

    func testRejectsOutOfRangeNameOffsets() throws {
        let index = IndexTests().makeIndex()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try index.save(to: url)
        var bytes = [UInt8](try Data(contentsOf: url))
        let metaCount = bytes[44..<52].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        let nameStart = 52 + metaCount + FileIndex.recordBytes + 4 // record 1, nameStart field
        for k in 0..<4 { bytes[nameStart + k] = 0xFF }
        try Data(bytes).write(to: url)
        XCTAssertThrowsError(try FileIndex.load(from: url)) { error in
            XCTAssertTrue("\(error)".contains("corrupt"), "\(error)")
        }
    }

    func testRejectsTruncatedFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try IndexTests().makeIndex().save(to: url)
        let bytes = try Data(contentsOf: url)
        try bytes.prefix(bytes.count - 3).write(to: url)
        XCTAssertThrowsError(try FileIndex.load(from: url))
    }
}
