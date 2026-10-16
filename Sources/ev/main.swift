import EverythingCore
import Foundation

let usage = """
usage: ev [options] <query>
       ev --status | --rescan | --save
       ev --index [root ...]     scan without the daemon and write the index file
       ev --bench [folder]       time the scanners and searches on one folder
       ev --bench-searchfs VOL   compare searchfs() with the folder walk on a whole volume

query syntax:
  foo bar           names containing both words      "exact phrase"
  a | b             either word                      !word   exclude
  *.pdf  game?.mp4  wildcards on the whole name       ext:pdf;docx
  path:Football     word anywhere in the full path   size:>1gb  size:<10kb
  drive:CRASHBOX    only that drive                  !path:/Volumes/   only this Mac
  audio: zip: doc: exe: pic: video:                  file types, as in Everything's filters
  !temp:            hide temp and generated files (node_modules, .git, caches, *.tmp)
  dm:today  dm:yesterday  dm:thisweek  dm:>2026-10-01
  regex:^IMG_\\d+    file:  folder:

options:
  -n, --limit N     results to print (default 100, 0 = all)
  --offset N        skip the first N results
  --sort KEY        name | path | size | modified
  --desc            reverse the sort
  --count           print only the number of matches
  --long            print size and modified date too
  --json            print the raw JSON response
  --direct          search the saved index file without the daemon
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func formatSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f
}()

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("-h") || args.contains("--help") {
    print(usage)
    exit(args.isEmpty ? 1 : 0)
}

var limit = 100, offset = 0
var sort = SortKey.name
var descending = false, countOnly = false, long = false, json = false, direct = false
var queryParts: [String] = []
var command: String?

var i = 0
func nextValue(_ flag: String) -> String {
    i += 1
    guard i < args.count else { fail("\(flag) needs a value") }
    return args[i]
}
while i < args.count {
    let a = args[i]
    switch a {
    case "-n", "--limit":
        guard let n = Int(nextValue(a)) else { fail("--limit needs a number") }
        limit = n
    case "--offset":
        guard let n = Int(nextValue(a)) else { fail("--offset needs a number") }
        offset = n
    case "--sort":
        guard let key = SortKey(rawValue: nextValue(a)) else { fail("--sort is name, path, size or modified") }
        sort = key
    case "--desc": descending = true
    case "--count": countOnly = true
    case "--long", "-l": long = true
    case "--json": json = true
    case "--direct": direct = true
    case "--status", "--rescan", "--save", "--index", "--bench", "--bench-searchfs", "--sync": command = a
    case "--": queryParts.append(contentsOf: args[(i + 1)...]); i = args.count
    default: queryParts.append(a)
    }
    i += 1
}

func printResult(_ result: SearchResult) {
    if countOnly { print(result.total); return }
    if json {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try! enc.encode(result), as: UTF8.self))
        return
    }
    for hit in result.hits {
        if long {
            let size = hit.isDirectory ? "<dir>" : formatSize(hit.size)
            let date = dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(hit.modified)))
            print("\(size.padding(toLength: 10, withPad: " ", startingAt: 0)) \(date)  \(hit.path)")
        } else {
            print(hit.path)
        }
    }
    if result.total > result.hits.count + offset && !json {
        FileHandle.standardError.write(Data("\(result.total) matches, showing \(result.hits.count) (\(String(format: "%.1f", result.milliseconds)) ms)\n".utf8))
    }
}

func searchDirect(_ text: String) {
    let url = FileIndex.defaultIndexURL
    let index: FileIndex
    do { index = try FileIndex.load(from: url) } catch {
        fail("no index at \(url.path) (\(error)). Run `ev --index` or start everythingd.")
    }
    let opts = SearchOptions(limit: limit == 0 ? Int.max : limit, offset: offset, sort: sort, descending: descending)
    printResult(index.search(Query.parse(text), options: opts))
}

func runBench(_ folder: String) {
    print("Benchmark on \(folder)")
    for (label, bulk) in [("getattrlistbulk", true), ("FileManager + lstat", false)] {
        let index = FileIndex()
        let root = index.addRoot(folder)
        let stats = Scanner(useBulk: bulk).scanTree(into: index, root: root, rootPath: folder)
        print(String(format: "  %@: %ld entries, %ld folders, %ld unreadable, %.2f s",
                     label, stats.entries, stats.directories, stats.unreadable, stats.seconds))
        for s in stats.slowest { print(String(format: "    slow folder: %.1f s  ", s.seconds) + s.path) }
    }
    let index = FileIndex()
    let root = index.addRoot(folder)
    Scanner().scanTree(into: index, root: root, rootPath: folder)
    let t0 = Date()
    index.sortIfNeeded(force: true)
    print(String(format: "  sort by name: %.2f s", Date().timeIntervalSince(t0)))
    for q in ["a", "report", "*.pdf", "ext:jpg;png", "path:lib", "path:contents/resources", "size:>10mb",
              "regex:^[0-9]+$", "regex:\\.plist$", "regex:^lib.*\\.dylib$", "video:", "doc: report", "report !temp:", "zzzzqqq"] {
        let r = index.search(Query.parse(q), options: SearchOptions(limit: 100))
        print(String(format: "  search %-26@ %8ld matches  %7.2f ms", q as NSString, r.total, r.milliseconds))
    }
}

/// Times searchfs() against the getattrlistbulk walk on one volume and compares the paths.
func runSearchFSBench(_ volume: String) {
    print("searchfs benchmark on \(volume)")
    let found = SearchFS.listVolume(volume)
    if let error = found.error {
        print("  searchfs: \(error)")
        return
    }
    let viaSearch = FileIndex()
    let searchRoot = viaSearch.addRoot(volume)
    let t0 = Date()
    let tree = SearchFS.buildTree(found.entries, volumePath: volume, into: viaSearch, root: searchRoot)
    let buildSeconds = Date().timeIntervalSince(t0)
    print(String(format: "  searchfs: %ld entries in %ld calls, %.2f s; tree %.2f s (%ld placed, %ld unreachable, root id %llu)",
                 found.entries.count, found.calls, found.seconds, buildSeconds, tree.added, tree.unreachable, tree.rootId))

    let viaWalk = FileIndex()
    let walkRoot = viaWalk.addRoot(volume)
    let stats = Scanner(exclusions: [], excludedNames: []).scanTree(into: viaWalk, root: walkRoot, rootPath: volume)
    print(String(format: "  getattrlistbulk walk: %ld entries, %ld unreadable folders, %.2f s",
                 stats.entries, stats.unreadable, stats.seconds))

    func paths(_ index: FileIndex) -> Set<String> {
        Set((0..<Int32(index.records.count)).filter { !index.records[Int($0)].isDeleted }.map { index.path(of: $0) })
    }
    let a = paths(viaSearch), b = paths(viaWalk)
    let onlySearch = a.subtracting(b), onlyWalk = b.subtracting(a)
    print("  only in searchfs: \(onlySearch.count), only in walk: \(onlyWalk.count)")
    for p in onlySearch.sorted().prefix(5) { print("    searchfs only: \(p)") }
    for p in onlyWalk.sorted().prefix(5) { print("    walk only: \(p)") }
}

switch command {
case "--status":
    do {
        let r = try IPC.send(IPCRequest(command: "status"))
        guard let s = r.status else { fail(r.error ?? "no status") }
        print("ready: \(s.ready)  scanning: \(s.scanning)")
        if s.scanning, let soFar = s.scannedSoFar {
            if let root = s.scanningRoot {
                print("scan progress: \(soFar.formatted()) entries so far (all roots), now in \(root)")
            } else if soFar > 0 {
                print("scan progress: all \(soFar.formatted()) entries listed; sorting names")
            }
        }
        print("entries: \(s.entries)")
        print("roots: \(s.roots.joined(separator: ", "))")
        if let secs = s.lastScanSeconds { print(String(format: "last full scan: %.1f s", secs)) }
        if let mem = s.memoryBytes { print("daemon memory: \(formatSize(Int64(mem)))") }
        if let stale = s.unwatchedRoots, !stale.isEmpty {
            print("warning: not watching \(stale.joined(separator: ", ")); results there may be stale (retried every minute)")
        }
    } catch { fail("\(error)") }
case "--rescan", "--save", "--sync":
    do {
        let r = try IPC.send(IPCRequest(command: String(command!.dropFirst(2))))
        print(r.ok ? "ok" : (r.error ?? "failed"))
    } catch { fail("\(error)") }
case "--index":
    let roots = queryParts.isEmpty ? IndexService.defaultRoots() : queryParts.map(IndexService.canonical)
    let service = IndexService(roots: roots) { print($0) }
    service.fullScan()
    service.stop()
case "--bench-searchfs":
    runSearchFSBench(IndexService.canonical(queryParts.first ?? "/System/Volumes/Data"))
case "--bench":
    runBench(IndexService.canonical(queryParts.first ?? NSHomeDirectory()))
default:
    let text = queryParts.joined(separator: " ")
    if direct {
        searchDirect(text)
    } else {
        do {
            let r = try IPC.send(IPCRequest(command: "search", query: text, limit: limit == 0 ? Int.max : limit,
                                            offset: offset, sort: sort, descending: descending))
            guard let result = r.result else { fail(r.error ?? "search failed") }
            printResult(result)
        } catch IPCError.notRunning(_) {
            searchDirect(text)
        } catch {
            fail("\(error)")
        }
    }
}
