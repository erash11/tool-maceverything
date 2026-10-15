# Design

Full design doc: https://claude.ai/code/artifact/2dfce39a-ac50-4398-ac64-0f0b77dcef9c

## How it works

1. **First scan.** `Scanner.scanTree` walks each root level by level. Each level's folders are
   listed in parallel with `getattrlistbulk()`, which returns name, type, size and date for a
   whole folder per call. Firmlink duplicates (`/System/Volumes/Data`) and system mounts are
   excluded; other volumes under `/Volumes` get their own roots.
2. **Index.** `FileIndex` stores one fixed-size `Record` per entry (parent id, name offsets,
   size, date, flags) with names in two shared byte pools (original and lowercase). A sorted
   id list gives name order without sorting at query time.
3. **Search.** `FileIndex.search` splits the sorted ids across all cores and tests each
   lowercase name against the parsed query. Ids added since the last sort are matched
   separately and merged in.
4. **Live updates.** `Watcher` wraps FSEvents. Each event names a folder; the service
   re-lists that folder and diffs it (`replaceChildren`). New folders are walked in full.
   `MustScanSubDirs` events re-list the whole subtree.
5. **Restart.** The index file stores each root's volume UUID and last FSEvents event id.
   On start, if both are still valid, the daemon loads the file and resumes FSEvents from
   that id, which replays changes made while it was stopped. Otherwise it rescans.
6. **Clients.** `ev` and the app send one JSON line over a Unix socket
   (`~/Library/Application Support/MacEverything/ev.sock`, mode 600). This replaced XPC
   from the design doc: it needs no launchd Mach service registration and is easy to test.

## Not done yet

- `searchfs()` as a faster first-scan path (milestone 1 compares scanners with `ev --bench`).
- Code signing with a Developer ID, so Full Disk Access survives rebuilds.
