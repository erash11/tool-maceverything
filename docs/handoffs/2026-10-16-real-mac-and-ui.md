# 2026-10-16: first day on the real Mac, then search-window features

## What happened and why
Eric installed v0.1 on his MacBook (macOS 26.6.2) and pasted logs while it ran. Real data
exposed problems CI could not: slow first scan, retry noise, a 68-minute stall, needless
restarts. After those were fixed, Eric asked for Everything-style features in the search window.

## Fixes from real-Mac logs
- First scan 1,449 s: the daemon ran at .utility / launchd Background and was disk-throttled.
  Now starts at .userInitiated with ProcessType Standard. Now 228 to 279 s for ~3.9M entries.
- "giving up on X" noise: folders denying permission are final, not retried. Detected by the
  errno from open()/getattrlistbulk (EACCES, EPERM), with access() as backup.
- 68 minutes from scan end to save: a whole-volume refresh after dropped FSEvents restarted from
  the top on one unreadable folder (3 times), and the scan's swap waited behind it. Refresh now
  returns failed folders (with errno) and only those are retried; flushes are dropped and
  in-flight refreshes cancelled while a full scan builds the replacement index.
- Status showed the last root's name during the final sort; now says "sorting", and the log
  records sort time (3.7 s for 4.29M).
- `ev --rescan` right after install raced start(): start() now skips loading when a rescan
  already built the index.
- CRASHBOX rescanned on every start: the volume keeps no FSEvents history (device event id 0),
  so offline changes cannot be replayed. Now always rescanned on start, with a clear log line
  (the old check passed only by chance and could have missed offline edits).
- Browser and Electron caches skipped by folder name (Cache_Data, Code Cache, GPUCache, Dawn*,
  cache2); Chrome's cache alone cost 17 to 48 s per scan. config.json `excludedNames` overrides.

## Features added (all CI green; confirmed on the Mac unless noted)
- Scope menu left of the search box (All, This Mac, Cloud, each drive) and `drive:NAME`.
  Scope travels as its own IPC field, ANDed after parsing so "|" in the box cannot escape it.
- Search window reruns on open and retries every 2 s while the daemon is not running.
- File-type menu right of the box (Everything, Audio, Compressed, Document, Executable, Folder,
  Picture, Video) and keywords `audio:` `zip:` `doc:` `exe:` `pic:` `video:`.
- Temp files: `temp:` matches node_modules, .git, build and cache folders, system temp folders,
  *.tmp, *.swp, *.pyc, ~$*, .DS_Store. Hidden in the window unless "Show temp files" is ticked.
  Nothing leaves the index. Mask cached per index and extended for new records.
- Locations window (menu bar > Locations…): lists roots, adds folders, drives, network shares as
  config.json `extraRoots`, refuses folders already covered. Saving sends "reload"; the daemon
  saves, exits and launchd restarts it. A 30 s timer also reloads when a new drive appears.
  NOT yet confirmed on the Mac.
- Results table: click headers to sort (daemon sorts all matches), right-click header to choose
  columns, drag to reorder, layout saved (macOS 14+). Default Name | Type | Path; Size, Date
  Modified, Extension, Full Path available.

## Decisions
- Eric does not want anything excluded from the index (cloud folders and DexaProject stay in).
  Temp files are hidden in the UI, not excluded. Browser caches are the one exclusion he asked for.
- Cloud storage: Google Drive, Box, Dropbox, OneDrive and iCloud are indexed through their local
  sync folders; no cloud APIs.

## Files changed this session
Sources/EverythingCore/: Scanner.swift, Service.swift, IPC.swift, Query.swift, Search.swift,
FileIndex.swift, Scope.swift (new), Temp.swift (new). Sources/everythingd/main.swift,
Sources/ev/main.swift, Sources/EverythingApp/EverythingApp.swift. Tests/EverythingCoreTests/
IndexTests.swift, MacTests.swift. scripts/install.sh. README.md, docs/STATUS.md, this file.

## Next
See `docs/STATUS.md` > Next.
