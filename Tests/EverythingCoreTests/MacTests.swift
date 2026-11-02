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
        var code: Int32 = 0
        XCTAssertNil(Scanner.listBulk(dir + "/a/b", error: &code))
        XCTAssertEqual(code, EACCES)
        // Permission denied is final, not a temporary failure: handled (no retry), entries kept.
        XCTAssertTrue(Scanner().refresh(index, dir: b, path: dir + "/a/b", recursive: false))
        XCTAssertNotNil(index.lookup(dir + "/a/b/two.PDF"), "an unreadable folder must not lose its entries")
    }

    func testRefreshStopsWhenCancelled() throws {
        let index = FileIndex()
        let root = index.addRoot(dir)
        Scanner().scanTree(into: index, root: root, rootPath: dir)
        FileManager.default.createFile(atPath: dir + "/a/late.txt", contents: nil)
        let failures = Scanner().refreshFailures(SharedIndex(index), dir: root, path: dir, recursive: true,
                                                 cancelled: { true })
        XCTAssertEqual(failures, [])
        XCTAssertNil(index.lookup(dir + "/a/late.txt"), "a cancelled refresh must not keep walking")
        XCTAssertTrue(Scanner().refresh(index, dir: root, path: dir, recursive: true))
        XCTAssertNotNil(index.lookup(dir + "/a/late.txt"))
    }

    func testBrowserCachesAreSkippedByName() throws {
        let cache = dir + "/a/Cache/Cache_Data"
        try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cache + "/f_000001", contents: nil)
        let index = FileIndex()
        let root = index.addRoot(dir)
        Scanner().scanTree(into: index, root: root, rootPath: dir)
        XCTAssertNotNil(index.lookup(cache), "the cache folder itself is still listed")
        XCTAssertNil(index.lookup(cache + "/f_000001"), "its contents are not")
        XCTAssertTrue(Scanner().refresh(index, dir: root, path: dir, recursive: true))
        XCTAssertNil(index.lookup(cache + "/f_000001"), "a refresh does not walk into it either")
        let all = FileIndex()
        Scanner(excludedNames: []).scanTree(into: all, root: all.addRoot(dir), rootPath: dir)
        XCTAssertNotNil(all.lookup(cache + "/f_000001"), "an empty name list indexes caches again")
        let service = IndexService(roots: [dir], indexURL: URL(fileURLWithPath: dir + "-names.bin"))
        XCTAssertTrue(service.isExcluded(cache + "/f_000002"))
        XCTAssertFalse(service.isExcluded(dir + "/a/Cache"))
    }

    func testCloudFoldersAreExcludedByDefault() throws {
        let home = NSHomeDirectory()
        let cloud = ["/Library/CloudStorage", "/Library/Mobile Documents", "/Library/Application Support/FileProvider"]
        XCTAssertEqual(Scanner.cloudExclusions(home: "/h"), Set(cloud.map { "/h" + $0 }))
        XCTAssertTrue(Scanner.defaultExclusions.isSuperset(of: cloud.map { home + $0 }))

        // The walk lists each cloud folder but never goes inside it.
        let drive = dir + "/Library/CloudStorage/GoogleDrive-me@x.com"
        try FileManager.default.createDirectory(atPath: drive + "/.tmp", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: drive + "/plan.docx", contents: nil)
        let index = FileIndex()
        let root = index.addRoot(dir)
        let scanner = Scanner(exclusions: Scanner.cloudExclusions(home: dir))
        scanner.scanTree(into: index, root: root, rootPath: dir)
        XCTAssertNotNil(index.lookup(dir + "/Library/CloudStorage"), "the cloud folder itself is listed")
        XCTAssertNil(index.lookup(drive), "its accounts are not")
        XCTAssertTrue(scanner.refresh(index, dir: root, path: dir, recursive: true))
        XCTAssertNil(index.lookup(drive + "/plan.docx"), "a refresh does not walk into it either")

        // Changes inside them are ignored, so the daemon never re-lists them.
        let service = IndexService(roots: ["/"], indexURL: URL(fileURLWithPath: dir + "-cloud.bin"))
        for folder in cloud.map({ home + $0 }) {
            XCTAssertTrue(service.isExcluded(folder))
            XCTAssertTrue(service.isExcluded(folder + "/GoogleDrive-me@x.com/.tmp"))
        }
        XCTAssertFalse(service.isExcluded(home + "/Library/Application Support/MacEverything"))

        // Opting back in: an account added as a location is its own root and is watched.
        let account = home + "/Library/CloudStorage/GoogleDrive-me@x.com"
        XCTAssertEqual(IndexService.normalizeRoots(["/", account], exclusions: Scanner.defaultExclusions),
                       ["/", account])
        let optedIn = IndexService(roots: ["/", account], indexURL: URL(fileURLWithPath: dir + "-cloud2.bin"))
        XCTAssertFalse(optedIn.isExcluded(account + "/.tmp"))
        XCTAssertTrue(optedIn.isExcluded(home + "/Library/Application Support/FileProvider/x"))
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

        // The folder comes back (a drive plugged in again): maintenance re-lists it.
        try FileManager.default.createDirectory(atPath: dir + "/back", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/back/returned.txt", contents: nil)
        service.maintenanceNow()
        service.sync()
        XCTAssertEqual(service.index.read { $0.search(Query.parse("returned.txt")).total }, 1)
        service.stop()
    }

    /// When FSEvents drops events the whole root is re-listed, which took minutes on a 2.6M-entry
    /// Mac and blocked every later change until it finished (2026-11-02: a new file showed
    /// after 81 s). Newer changes must be listed ahead of that walk, and the saved cursor must
    /// stay behind the drop until the walk is done.
    func testChangesAreListedAheadOfAWholeRootRescan() throws {
        for i in 0..<20 {
            try FileManager.default.createDirectory(atPath: dir + "/deep/d\(i)", withIntermediateDirectories: true)
        }
        let service = IndexService(roots: [dir], indexURL: URL(fileURLWithPath: dir + "-walk.bin"))
        service.sliceSeconds = 0 // one folder per slice
        service.stepsByHand = true // only the events below, listed slice by slice
        service.start()
        defer { service.stop() }
        let before = service.appliedEventId(for: dir) ?? 0
        func event(_ path: String, dropped: Bool = false, id: UInt64) -> Watcher.Event {
            Watcher.Event(path: path, mustScanSubDirs: dropped, rootChanged: false, historyDone: false,
                          dropped: dropped, id: id)
        }
        func count(_ q: String) -> Int { service.index.read { $0.search(Query.parse(q)).total } }

        service.receive([event("/", dropped: true, id: before + 10)], root: dir)
        service.flushSliceNow() // lists the root only; a, deep and empty are next
        XCTAssertEqual(service.foldersLeftToList, 3)

        // a/b/c is three folders below the top of the walk, so only its own event can list it now.
        FileManager.default.createFile(atPath: dir + "/a/b/c/fresh.txt", contents: nil)
        XCTAssertEqual(count("fresh.txt"), 0)
        service.receive([event(dir + "/a/b/c/", id: before + 20)], root: dir)
        service.flushSliceNow()
        XCTAssertEqual(count("fresh.txt"), 1, "a new change must not wait for the rescan")
        XCTAssertEqual(service.foldersLeftToList, 3, "the rescan is still under way")
        XCTAssertLessThan(service.appliedEventId(for: dir) ?? 0, before + 10,
                          "the cursor must not pass the dropped events before the rescan is done")

        // FSEvents asks for a subtree scan of a/b: listed now, not after the whole walk.
        FileManager.default.createFile(atPath: dir + "/a/b/c/subtree.txt", contents: nil)
        service.receive([Watcher.Event(path: dir + "/a/b/", mustScanSubDirs: true, rootChanged: false,
                                       historyDone: false, id: before + 25)], root: dir)
        service.flushSliceNow() // lists a/b
        service.flushSliceNow() // lists a/b/c
        XCTAssertEqual(count("subtree.txt"), 1)
        XCTAssertEqual(service.passesWaiting, 0)
        XCTAssertEqual(service.foldersLeftToList, 3, "the root walk is still under way")

        // Dropped again: queued as a second pass, not a restart that could never finish.
        service.receive([event("/", dropped: true, id: before + 30)], root: dir)
        service.flushSliceNow()
        XCTAssertEqual(service.passesWaiting, 1, "a restart would have dropped the first pass instead")
        XCTAssertGreaterThan(service.foldersLeftToList, 0)

        service.sync()
        XCTAssertEqual(service.foldersLeftToList, 0)
        XCTAssertEqual(service.passesWaiting, 0)
        XCTAssertGreaterThanOrEqual(service.appliedEventId(for: dir) ?? 0, before + 30)
        XCTAssertEqual(count("two.pdf"), 1)
        XCTAssertEqual(count("\"path:/deep/d\""), 20)
    }

    /// A 5000-file delete overflows the FSEvents queue, so its own events are the dropped ones.
    /// Folders that changed just before are listed first instead of minutes into the walk.
    func testRecentlyChangedFoldersAreListedFirstAfterDroppedEvents() throws {
        let service = IndexService(roots: [dir], indexURL: URL(fileURLWithPath: dir + "-recent.bin"))
        service.sliceSeconds = 0
        service.stepsByHand = true
        service.start()
        defer { service.stop() }
        let before = service.appliedEventId(for: dir) ?? 0
        func event(_ path: String, dropped: Bool = false, id: UInt64) -> Watcher.Event {
            Watcher.Event(path: path, mustScanSubDirs: dropped, rootChanged: false, historyDone: false,
                          dropped: dropped, id: id)
        }
        service.receive([event(dir + "/a/b/c/", id: before + 1)], root: dir)
        service.flushSliceNow()

        FileManager.default.createFile(atPath: dir + "/a/b/c/during-drop.txt", contents: nil)
        service.receive([event("/", dropped: true, id: before + 2)], root: dir)
        service.flushSliceNow() // one folder: the recently changed a/b/c, not the root
        XCTAssertEqual(service.index.read { $0.search(Query.parse("during-drop")).total }, 1)
        XCTAssertGreaterThan(service.foldersLeftToList, 0, "the walk of the root is still to come")
        service.sync()
        XCTAssertEqual(service.foldersLeftToList, 0)
    }

    func testOnlyNewRootsAreScannedOnLoad() throws {
        let other = dir + "-other"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: other + "/other-file.txt", contents: nil)
        defer { try? FileManager.default.removeItem(atPath: other) }
        let indexURL = URL(fileURLWithPath: dir + "-roots.bin")
        let first = IndexService(roots: [dir], indexURL: indexURL)
        first.start()
        first.stop()

        var lines: [String] = []
        let lock = NSLock()
        let second = IndexService(roots: [dir, other], indexURL: indexURL) { line in
            lock.lock(); lines.append(line); lock.unlock()
        }
        second.start()
        defer { second.stop() }
        lock.lock(); defer { lock.unlock() }
        XCTAssertTrue(lines.contains { $0.hasPrefix("scanned \(other)") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("scanned \(self.dir):") }, "\(lines)")
        XCTAssertEqual(second.index.read { $0.search(Query.parse("other-file")).total }, 1)
        XCTAssertEqual(second.index.read { $0.search(Query.parse("two.pdf")).total }, 1)
    }

    func testRootsAreNormalized() {
        let ex = Scanner.defaultExclusions
        XCTAssertEqual(IndexService.normalizeRoots([dir, dir + "/", dir + "/a"], exclusions: ex), [dir])
        XCTAssertEqual(IndexService.normalizeRoots(["/", "/Volumes/Work", "/Users"], exclusions: ex),
                       ["/", "/Volumes/Work"])
        XCTAssertEqual(IndexService.normalizeRoots([dir + "/a", dir + "/empty"], exclusions: ex),
                       [dir + "/a", dir + "/empty"])
    }

    /// Runs only when CI provides a mounted disk image (MEV_TEST_VOLUME), to exercise the
    /// per-device FSEvents stream used for /Volumes roots.
    func testExternalVolumeUsesPerDeviceStream() throws {
        guard let volume = ProcessInfo.processInfo.environment["MEV_TEST_VOLUME"] else {
            throw XCTSkip("set MEV_TEST_VOLUME to a mounted volume under /Volumes")
        }
        let root = volume + "/mev-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertTrue(Watcher(root: root) { _ in }.isPerDevice)

        let indexURL = URL(fileURLWithPath: dir + "-vol.bin")
        let service = IndexService(roots: [root], indexURL: indexURL)
        service.start()
        func waitFor(_ s: IndexService, _ q: String) -> Int {
            let deadline = Date().addingTimeInterval(15)
            var n = 0
            while Date() < deadline {
                s.sync()
                n = s.index.read { $0.search(Query.parse(q)).total }
                if n == 1 { break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            return n
        }
        FileManager.default.createFile(atPath: root + "/sub/on-volume.txt", contents: nil)
        XCTAssertEqual(waitFor(service, "on-volume"), 1)
        service.stop()

        FileManager.default.createFile(atPath: root + "/sub/while-stopped-vol.txt", contents: nil)
        Thread.sleep(forTimeInterval: 1.5)
        let again = IndexService(roots: [root], indexURL: indexURL)
        again.start()
        XCTAssertEqual(waitFor(again, "while-stopped-vol"), 1)
        again.stop()
    }

    func testEventTargets() {
        func ev(_ path: String, scan: Bool = false, rootChanged: Bool = false, dropped: Bool = false) -> Watcher.Event {
            Watcher.Event(path: path, mustScanSubDirs: scan, rootChanged: rootChanged, historyDone: false,
                          dropped: dropped, id: 1)
        }
        let root = "/Users/me"
        XCTAssertTrue(IndexService.target(for: ev("/Users/me/Docs/"), root: root)! == ("/Users/me/Docs", false))
        XCTAssertTrue(IndexService.target(for: ev("/", scan: true, dropped: true), root: root)! == (root, true))
        XCTAssertTrue(IndexService.target(for: ev("/", scan: true), root: root)! == (root, true))
        XCTAssertTrue(IndexService.target(for: ev("/Users/me", rootChanged: true), root: root)! == (root, true))
        XCTAssertTrue(IndexService.target(for: ev("/System/Volumes/Data/Users/me/x/"), root: root)! == ("/Users/me/x", false))
        XCTAssertTrue(IndexService.target(for: ev("/etc/", scan: true), root: "/")! == ("/etc", true))
        XCTAssertNil(IndexService.target(for: ev(""), root: root))
    }

    /// searchfs() must produce exactly the paths, kinds, sizes and dates of the folder walk.
    func testSearchFSMatchesWalkOnVolume() throws {
        guard let volume = ProcessInfo.processInfo.environment["MEV_TEST_VOLUME"] else {
            throw XCTSkip("set MEV_TEST_VOLUME to a mounted volume under /Volumes")
        }
        let base = volume + "/sfs-" + UUID().uuidString.prefix(8)
        let fm = FileManager.default
        try fm.createDirectory(atPath: base + "/a/b/c", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: base + "/empty", withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4321).write(to: URL(fileURLWithPath: base + "/a/size.bin"))
        try Data().write(to: URL(fileURLWithPath: base + "/a/b/thrée ünïcode.md"))
        for i in 0..<3000 { fm.createFile(atPath: base + "/a/b/c/f\(i).txt", contents: nil) }
        try fm.createSymbolicLink(atPath: base + "/link", withDestinationPath: base + "/a")
        defer { try? fm.removeItem(atPath: base) }

        let found = SearchFS.listVolume(volume)
        if let error = found.error { throw XCTSkip("searchfs unavailable on this volume: \(error)") }
        let viaSearch = FileIndex()
        SearchFS.buildTree(found.entries, volumePath: volume, into: viaSearch, root: viaSearch.addRoot(volume))
        let viaWalk = FileIndex()
        Scanner(exclusions: [], excludedNames: []).scanTree(into: viaWalk, root: viaWalk.addRoot(volume), rootPath: volume)

        func describe(_ index: FileIndex) -> Set<String> {
            Set((0..<Int32(index.records.count)).compactMap { id -> String? in
                let r = index.records[Int(id)]
                let p = index.path(of: id)
                guard p.hasPrefix(base) else { return nil }
                return "\(p)|\(r.isDirectory)|\(r.size)|\(r.modified)"
            })
        }
        let a = describe(viaSearch), b = describe(viaWalk)
        XCTAssertEqual(a.count, 3008, "entries under the test folder via searchfs")
        XCTAssertEqual(a.subtracting(b), [], "only in searchfs")
        XCTAssertEqual(b.subtracting(a), [], "only in walk")
    }

    func testSaveBeforeReadyKeepsTheIndexFile() throws {
        let url = URL(fileURLWithPath: dir + "-early.bin")
        try Data("existing index".utf8).write(to: url)
        let service = IndexService(roots: [dir], indexURL: url) // not started: not ready
        XCTAssertFalse(service.handle(IPCRequest(command: "save")).ok)
        try service.save()
        XCTAssertEqual(try String(contentsOf: url), "existing index")
    }

    func testScanReportsProgress() {
        let index = FileIndex()
        let root = index.addRoot(dir)
        var seen: [Int] = []
        let lock = NSLock()
        let stats = Scanner().scanTree(into: index, root: root, rootPath: dir) { n in
            lock.lock(); seen.append(n); lock.unlock()
        }
        XCTAssertFalse(seen.isEmpty)
        XCTAssertEqual(seen.max(), stats.entries)
        XCTAssertNil(IndexService(roots: [dir]).status().scannedSoFar, "no progress when not scanning")
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

        // An oversized request is refused without taking the daemon down.
        let huge = String(repeating: "x", count: IPC.maxRequestBytes * 2)
        // The server may hang up mid-write, so a send error is as acceptable as a refusal.
        if let refused = try? IPC.send(IPCRequest(command: "search", query: huge), socketPath: socketPath) {
            XCTAssertFalse(refused.ok)
        }
        XCTAssertTrue(try IPC.send(IPCRequest(command: "status"), socketPath: socketPath).ok)
    }
}
#endif
