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

    func testRejectsGarbage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("hello world, not an index".utf8).write(to: url)
        XCTAssertThrowsError(try FileIndex.load(from: url))
    }
}
