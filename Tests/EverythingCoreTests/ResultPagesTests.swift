import XCTest
@testable import EverythingCore

final class ResultPagesTests: XCTestCase {
    func hits(_ names: [String]) -> [SearchHit] {
        names.map { SearchHit(path: "/d/\($0)", name: $0, isDirectory: false, size: 0, modified: 0) }
    }

    func page(_ names: [String], total: Int) -> SearchResult {
        SearchResult(total: total, hits: hits(names), milliseconds: 0)
    }

    func testPagesAppendUntilTotal() {
        var p = ResultPages()
        p.reset(with: page(["a", "b"], total: 5))
        XCTAssertTrue(p.hasMore)
        XCTAssertEqual(p.nextOffset, 2)
        p.append(page(["c", "d", "e"], total: 5))
        XCTAssertEqual(p.hits.map(\.name), ["a", "b", "c", "d", "e"])
        XCTAssertFalse(p.hasMore)
    }

    func testRepeatedRowsAreSkippedButCountTowardTheOffset() {
        // A file created above the page boundary pushes "b" into the next page too.
        var p = ResultPages()
        p.reset(with: page(["a", "b"], total: 4))
        p.append(page(["b", "c"], total: 4))
        XCTAssertEqual(p.hits.map(\.name), ["a", "b", "c"])
        XCTAssertEqual(p.nextOffset, 4)
        XCTAssertFalse(p.hasMore)
    }

    func testEmptyPageStopsLoading() {
        var p = ResultPages()
        p.reset(with: page(["a"], total: 10))
        p.append(page([], total: 10)) // the matches shrank meanwhile
        XCTAssertFalse(p.hasMore)
        XCTAssertEqual(p.hits.count, 1)
    }

    func testResetForgetsTheOldSearch() {
        var p = ResultPages()
        p.reset(with: page(["a", "b"], total: 9))
        p.reset(with: page(["b"], total: 1))
        XCTAssertEqual(p.hits.map(\.name), ["b"])
        XCTAssertEqual(p.nextOffset, 1)
        XCTAssertFalse(p.hasMore)
    }

    func testNearEnd() {
        var p = ResultPages()
        let names = (0..<ResultPages.prefetchMargin + 10).map { "f\($0)" }
        p.reset(with: page(names, total: 1000))
        XCTAssertFalse(p.isNearEnd("/d/f0"))
        XCTAssertFalse(p.isNearEnd("/d/f9"))
        XCTAssertTrue(p.isNearEnd("/d/f10"))
        XCTAssertTrue(p.isNearEnd("/d/f\(names.count - 1)"))
        XCTAssertFalse(p.isNearEnd("/d/missing"))
    }
}
