# Status

## Current state
Running daily on Eric's MacBook since 2026-10-16 (macOS 27.0.1 as of 2026-10-24): daemon,
`ev` CLI and menu-bar app, signed with the local certificate, Full Disk Access on. CI (macOS 15
runners) is the compiler and is green on `main` (51 tests at d2b8ccc). Detail of the first
real-Mac day:
`docs/handoffs/2026-10-16-real-mac-and-ui.md`.

2026-10-24: cloud folders are no longer indexed (`~/Library/CloudStorage`, `~/Library/Mobile
Documents`, `~/Library/Application Support/FileProvider`; see `docs/DECISIONS.md`). The daemon
had written about 27,000 "giving up ... Resource deadlock avoided" lines (5.5 MB) to
`~/Library/Logs/everythingd.log` re-listing them. New daemon and `ev` installed (not the app,
see Gotchas) and `ev --rescan` run: 3.21M entries for `/` (was 4.10M; 887K were cloud, so Full
Disk Access still holds), full scan 122 s, 0 entries left under the three folders. Before the
restart the log held 27,706 lines (27,195 "giving up"); the daily backup now trims it to its last
2000 lines once it passes 2 MB. No "giving up" lines from the restart (06:12 UTC) to 08:30 UTC, and
live updates kept applying. The old failures came in bursts, so recheck after a day with a count
that survives the trim: `awk '$1 >= "2026-10-24T06:12:22"' ~/Library/Logs/everythingd.log | grep -c "giving up"` (want 0).

Search window, all confirmed on the Mac: scope menu (All, This Mac, Cloud, each drive), file-type
menu (Everything's filters), "Show temp files" toggle (temp hidden by default), header sorting,
right-click column chooser, drag to reorder, default columns Name | Type | Path.
Scope menu also lists each cloud account (Google Drive, OneDrive, Dropbox, Box per
~/Library/CloudStorage folder, plus iCloud Drive) under Cloud, added 2026-10-16: built and
query-checked on the Mac with `ev`, window not yet seen. Detail:
`docs/handoffs/2026-10-16-cloud-account-scopes.md`. Since 2026-10-24 those scopes return
nothing unless the account is added as a location (Next #1). Until the app is rebuilt, add it in
config.json `extraRoots`, not the Locations window: the installed 2026-10-16 app still uses the
old exclusions and answers "Already indexed: ... is inside /". The daemon's 30 s location check
picks up a config.json change on its own.

| Measured on CI, 1.35M entries | Result |
| --- | --- |
| Plain, wildcard, ext, size searches | 2 to 15 ms |
| `path:` / `regex:` searches | 16 to 30 ms / 6 to 46 ms |
| `video:`, `doc: report` | 16 to 22 ms |
| `report !temp:` (first search, builds the mask) | 43 ms; later searches only extend it |

## Next
1. Scope menu: offer a cloud account (and Cloud) only when it is indexed, that is, added as a
   location; `SearchScope.choices` lists every ~/Library/CloudStorage folder today. Small change
   plus a test tweak.
2. The menu-bar app no longer builds on this Mac (Gotchas): install full Xcode, or wait for
   Command Line Tools that ship SwiftUIMacros. Until then `scripts/install.sh` stops at
   `make-app.sh`; the installed 2026-10-16 app keeps running.
3. On the Mac: Locations window (menu bar > Locations…), live updates (create, rename, delete a
   file and check `ev`), unplug and replug CRASHBOX. Rest of the #2 checklist.
4. Post the real-Mac numbers on #3 and close it (GitHub MCP was down at the end of 2026-10-16).
5. Delete the `codex-review` and `codex-review-base` branches on GitHub, close #10.
6. Optional: folders that each take exactly 6.0 s to list (once OneDrive; in the 2026-10-24
   scan, sandbox folders under ~/Library/Containers); Type column sorting.

## Open questions
- None. #9 decided 2026-10-16: keep building (see `docs/DECISIONS.md`).

## Gotchas
- On the Mac, `swift test` fails with "no such module 'XCTest'" (no full Xcode). Build locally,
  let CI run the tests.
- Since macOS 27 / Swift 6.4 Command Line Tools (2026-10-24), plain `swift build` fails in
  EverythingApp: "plugin for module 'SwiftUIMacros' not found" (it ships only with Xcode).
  `swift build -c release --product everythingd` (and `--product ev`) still work.
- Daemon-only install while the app cannot build: copy `.build/release/everythingd` to
  `build/`, sign it with `codesign --force --options runtime --sign "MacEverything Local
  Signing" --identifier com.erash11.maceverything.daemon`, check `codesign -d -r-` matches the
  installed binary (same requirement keeps Full Disk Access), move the old
  `~/.local/bin/everythingd` aside, copy the new one in, then
  `launchctl kickstart -k gui/$(id -u)/com.erash11.maceverything.daemon`. Same for `ev`
  (identifier com.erash11.maceverything.ev, no restart). On 2026-10-24 the kickstart killed the
  old daemon mid-save (exit -9), launchd then reported last exit reason OS_REASON_CODESIGNING,
  and the new daemon logged "starting" 18 s after the kickstart and ran fine.
- No Swift toolchain in Claude cloud sessions: CI is the compiler. When the GitHub MCP is down,
  `curl https://api.github.com/repos/erash11/MacEverything/actions/runs` and
  `.../actions/jobs/<id>/logs` work without auth (public repo).
- Cloud sessions cannot delete GitHub branches (API and `git push --delete` both refused).
- Index writes must stay on `IndexService.work`; `PathTable` and the temp mask rely on parent id
  < child id and on records being append-only.
- External drives with no FSEvents history (CRASHBOX reports event id 0, likely exFAT) are
  rescanned at every daemon start by design (about 15 s for 220K entries).
- The daemon restarts itself (launchd KeepAlive) when locations change: `ev`/app "reload", or the
  30 s check finding a new drive. A restart during a full scan waits for the scan to finish.
- `ev --rescan` right after an install is not needed; the daemon loads its saved index. Except
  when the exclusions change: loading never prunes newly excluded folders, so their entries stay
  until a full scan (887K cloud entries on 2026-10-24).
- To check the cloud exclusion without reading the Drive mount: `ev --count
  '"path:/library/cloudstorage/"'` (and the same for `/application support/fileprovider/`,
  `/library/mobile documents/`) should print 0. Never list or walk ~/Library/CloudStorage by
  hand; the Drive FUSE mount can hang.
- DexaProject (Google Drive) is no longer indexed since 2026-10-24. If a Google Drive account is
  added back as a location, its names return: never paste search results from it into chat or
  an external service.
- The unauthenticated GitHub API now returns 404 for this repo (2026-10-24); use `gh run list
  -R erash11/MacEverything` for CI.
