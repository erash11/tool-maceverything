#if canImport(CoreServices)
import XCTest
@testable import EverythingCore

/// Tests that touch the real file system, FSEvents and sockets.
final class MacTests: XCTestCase {
    var dir: String!

    override func setUpWithError() throws {
        let base = IndexService.canonical(NSTemporaryDirectory())
        dir = base + "/mev-" + UUID().uuidString.prefix(8)
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir + "/a/b/c", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: dir + "/empty", withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1234).write(to: URL(fileURLWithPath: dir + "/a/one.txt"))
        try Data().write(to: URL(fileURLWithPath: dir + "/a/b/two.PDF"))
        try Data().write(to: URL(fileURLWithPath: dir + "/a/b/c/thrée ünïcode.md"))
        try fm.createSymbolicLink(atPath: dir + "/link", withDestinationPath: dir + "/a")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    func sorted(_ entries: [ScannedEntry]?) -> [ScannedEntry] {
        (entries ?? []).sorted { $0.name < $1.name }
    }

    func testBulkListingMatchesFoundation() {
        for sub in ["", "/a", "/a/b", "/a/b/c", "/empty"] {
            let bulk = sorted(Scanner.listBulk(dir + sub))
            let plain = sorted(Scanner.listFoundation(dir + sub))
            XCTAssertEqual(bulk, plain, "listing differs for \(sub)")
        }
        let a = sorted(Scanner.listBulk(dir + "/a"))
        XCTAssertEqual(a.first { $0.name == "one.txt" }?.size, 1234)
        XCTAssertNil(Scanner.listBulk(dir + "/does-not-exist"))
    }

    func testBulkListingOfLargeFolder() throws {
        let big = dir + "/big"
        try FileManager.default.createDirectory(atPath: big, withIntermediateDirectories: true)
        for i in 0..<5000 {
            FileManager.default.createFile(atPath: big + "/file-\(i)-with-a-longer-name-to-fill-buffers.dat", contents: nil)
        }
        XCTAssertEqual(Scanner.listBulk(big)?.count, 5000)
    }

    func testScanTreeAndSearch() {
        let index = FileIndex()
        let root = index.addRoot(dir)
        let stats = Scanner().scanTree(into: index, root: root, rootPath: dir)
        XCTAssertEqual(stats.entries, 8) // a, empty, link, one.txt, b, two.PDF, c, thrée ünïcode.md
        index.sortIfNeeded(force: true)
        XCTAssertEqual(index.search(Query.parse("ünï")).hits.map(\.name), ["thrée ünïcode.md"])
        XCTAssertEqual(index.search(Query.parse("*.pdf")).hits.map(\.path), [dir + "/a/b/two.PDF"])
        // Symlinks are indexed but not followed.
        XCTAssertNil(index.lookup(dir + "/link/one.txt"))
    }

    func testServiceFollowsChangesAndSurvivesRestart() throws {
        let indexURL = URL(fileURLWithPath: dir + "-index.bin")
        defer { try? FileManager.default.removeItem(at: indexURL) }
        let service = IndexService(roots: [dir], indexURL: indexURL)
        service.start()
        XCTAssertTrue(service.ready)

        func count(_ q: String) -> Int {
            service.index.read { $0.search(Query.parse(q)).total }
        }
        XCTAssertEqual(count("one.txt"), 1)

        let fm = FileManager.default
        fm.createFile(atPath: dir + "/a/b/fresh-file.txt", contents: nil)
        try fm.createDirectory(atPath: dir + "/moved-in/deep", withIntermediateDirectories: true)
        fm.createFile(atPath: dir + "/moved-in/deep/inner.txt", contents: nil)
        try fm.removeItem(atPath: dir + "/a/one.txt")

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            service.sync()
            if count("fresh-file") == 1 && count("inner.txt") == 1 && count("one.txt") == 0 { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertEqual(count("fresh-file"), 1)
        XCTAssertEqual(count("inner.txt"), 1)
        XCTAssertEqual(count("one.txt"), 0)

        service.stop()

        // Change while stopped, then restart: the saved event id replays it.
        fm.createFile(atPath: dir + "/while-stopped.txt", contents: nil)
        Thread.sleep(forTimeInterval: 1.5)
        let again = IndexService(roots: [dir], indexURL: indexURL)
        again.start()
        let deadline2 = Date().addingTimeInterval(15)
        var found = 0
        while Date() < deadline2 {
            again.sync()
            found = again.index.read { $0.search(Query.parse("while-stopped")).total }
            if found == 1 { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertEqual(found, 1)
        XCTAssertEqual(again.index.read { $0.search(Query.parse("fresh-file")).total }, 1)
        again.stop()
    }

    func testUnreadableFolderIsReportedAndKept() throws {
        let index = FileIndex()
        let root = index.addRoot(dir)
        Scanner().scanTree(into: index, root: root, rootPath: dir)
        let b = index.lookup(dir + "/a/b")!
        chmod(dir + "/a/b", 0)
        defer { chmod(dir + "/a/b", 0o755) }
        XCTAssertFalse(Scanner().refresh(index, dir: b, path: dir + "/a/b", recursive: false))
        XCTAssertNotNil(index.lookup(dir + "/a/b/two.PDF"), "an unreadable folder must not lose its entries")
    }

    func testDeletedRootIsEmptied() throws {
        let service = IndexService(roots: [dir], indexURL: URL(fileURLWithPath: dir + "-root.bin"))
        service.start()
        XCTAssertEqual(service.index.read { $0.search(Query.parse("two.pdf")).total }, 1)
        try FileManager.default.removeItem(atPath: dir)
        let deadline = Date().addingTimeInterval(15)
        var left = 1
        while Date() < deadline {
            service.sync()
            left = service.index.read { $0.search(Query.parse("two.pdf")).total }
            if left == 0 { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertEqual(left, 0)
        service.stop()
    }

    func testRootsAreNormalized() {
        let ex = Scanner.defaultExclusions
        XCTAssertEqual(IndexService.normalizeRoots([dir, dir + "/", dir + "/a"], exclusions: ex), [dir])
        XCTAssertEqual(IndexService.normalizeRoots(["/", "/Volumes/Work", "/Users"], exclusions: ex),
                       ["/", "/Volumes/Work"])
        XCTAssertEqual(IndexService.normalizeRoots([dir + "/a", dir + "/empty"], exclusions: ex),
                       [dir + "/a", dir + "/empty"])
    }

    func testConcurrentRescansAreSerialized() {
        let service = IndexService(roots: [dir], indexURL: URL(fileURLWithPath: dir + "-rescan.bin"))
        service.start()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in _ = service.handle(IPCRequest(command: "rescan")) }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(service.index.read { $0.search(Query.parse("two.pdf")).total }, 1)
        service.stop()
    }

    func testIPCRoundTrip() throws {
        let socketPath = "/tmp/mev-\(UUID().uuidString.prefix(8)).sock"
        let service = IndexService(roots: [dir], indexURL: URL(fileURLWithPath: dir + "-ipc.bin"))
        service.start()
        let server = IPCServer(socketPath: socketPath) { service.handle($0) }
        try server.start()
        defer { server.stop(); service.stop() }

        let response = try IPC.send(IPCRequest(command: "search", query: "two", limit: 10), socketPath: socketPath)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.hits.map(\.name), ["two.PDF"])

        let status = try IPC.send(IPCRequest(command: "status"), socketPath: socketPath)
        XCTAssertEqual(status.status?.ready, true)
        XCTAssertGreaterThan(status.status?.entries ?? 0, 5)

        XCTAssertThrowsError(try IPC.send(IPCRequest(command: "status"), socketPath: "/tmp/none.sock"))
    }
}
#endif
