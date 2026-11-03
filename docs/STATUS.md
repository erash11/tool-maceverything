# Status

## Current state
**2026-11-03 (read first):**
- Parity PRs #15 to #26 merged and installed today (daemon, `ev`, app from CI; `main` dc0a91a+).
  Query: dates, sizes, modifiers, `< >` groups, `parent:`/`depth:`/`childcount:`/`empty:`,
  `type:`. Window: fast sorts (all six keys), Ctrl+1..6, Down Arrow, file actions, drag-out; the
  Trash hidden like temp files. Eric confirmed Down Arrow, Type sort, Ctrl+1..6, Move to Trash.
- Drag-out (#26) waits on Eric's live check. Per-PR detail, numbers, backups and decisions:
  `docs/handoffs/2026-11-03-parity-prs-18-26.md`.
- Drive trial is off (config renamed to `config.json.drive-trial-2026-11-03`); 0 entries under
  ~/Library/CloudStorage.

**2026-11-02/03 parity work:**
- `scripts/parity_check.py` (Codex-reviewed, 5 rounds) times live updates and searches on the
  real Mac. `docs/PARITY.md` scores parity with Everything: 36 have, 23 partial, 55 missing;
  top 10 gaps listed there. Worst: unreadable terms (`dm:lastweek`, `size:10mb..50mb`) silently
  return everything; results stop at 500 rows; Down Arrow does not enter the list.
- PR #12 (open): live-update stall fix. Cause: dropped FSEvents made the daemon re-list all of /
  (~2 min) on its one update queue. Fixed daemon 51bf3fe is INSTALLED; old binary at
  `~/.local/bin/everythingd.pre-livefix-2026-11-02`. Merge after 3 clean parity runs on a quiet Mac.
- PR #11 (open): CI uploads the app; `scripts/install-app-from-ci.sh` installs it (no Xcode).
- Google Drive trial (Eric's Desk pick): config.json `extraRoots` = Drive account folder since
  2026-11-03T00:21:47Z. Check after a day:
  `awk '$1 >= "2026-11-03T00:21:47"' ~/Library/Logs/everythingd.log | grep -c "giving up"` (want 0);
  if not 0, delete config.json to turn Drive off.
- Found, not fixed: OneDrive container `~/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite`
  is indexed (164K entries; not in `Scanner.cloudExclusions`). `ev` search silently falls back to
  the saved index when the daemon is down (wants a `--daemon-only` flag for parity_check).

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

2026-11-02 check: daemon running, 0 "giving up" lines since the 10-24 restart, cloud scope
still 0 entries, CI green. The menu-bar app was not running (it was never a login item). Fixed
the same day: it is now a login item (System Settings > General > Login Items), and
`scripts/install.sh` adds it if missing. The app
still fails to build (same SwiftUIMacros error; Command Line Tools now Swift 6.4.2, no Xcode).
The old Next #5 (delete codex branches, close #10) was already done.

## Next
1. Gap 6 rename (F2): `git checkout -b rename-f2`, then in
   `Sources/EverythingApp/EverythingApp.swift` add F2 to `watchKeys` (list has the keys, one
   current row via `act(on:_:)`): a small sheet with the name selected up to the extension, then
   `FileManager.moveItem` in the same folder and `model.refreshAfterChange()`. Brief Codex with the
   existing bounds; case-sensitive-volume edge cases past them are out of scope.
2. Gap 7 (search history, run counts). Then an incremental path-order merge only if the ~0.2 s
   rebuild under churn shows up in use; the smaller items in `docs/handoffs/2026-11-03-parity-handoff.md`
   (OneDrive group container, `ev --daemon-only`).
3. Scope menu: offer a cloud account (and Cloud) only when it is indexed, that is, added as a
   location; `SearchScope.choices` lists every ~/Library/CloudStorage folder today. Small change
   plus a test tweak.
4. The menu-bar app no longer builds on this Mac (Gotchas): install full Xcode, or wait for
   Command Line Tools that ship SwiftUIMacros. Until then install the app from CI with
   `scripts/install-app-from-ci.sh` (Gotchas).
5. On the Mac: Locations window (menu bar > Locations…), unplug and replug CRASHBOX. Rest of the
   #2 checklist. Post the real-Mac numbers on #3 and close it.
6. Optional: folders that each take exactly 6.0 s to list (once OneDrive; in the 2026-10-24 scan,
   sandbox folders under ~/Library/Containers).

## Open questions
- None. #9 decided 2026-10-16: keep building (see `docs/DECISIONS.md`).

## Gotchas
- Never send System Events key presses unless MacEverything is frontmost and its panel is
  window 1: once the panel was hidden and test keys landed in Ghostty (2026-11-03). Eric uses the
  Mac at the same time. Accessibility presses can't open the panel either (the menu-bar Search
  item ignores AXPress), so app UI checks go to Eric; read state with Accessibility only.
- dcg blocks a Bash heredoc that mixes backticks with `$()`: write a script file, then run it.
- `ev --direct` reads the saved index file, which can be minutes older than the live daemon
  (a just-trashed file still showed in Downloads there). Check live state with plain `ev`.
- On the Mac, `swift test` fails with "no such module 'XCTest'" (no full Xcode). Build locally,
  let CI run the tests.
- Since macOS 27 / Swift 6.4 Command Line Tools (2026-10-24), plain `swift build` fails in
  EverythingApp: "plugin for module 'SwiftUIMacros' not found" (it ships only with Xcode).
  `swift build -c release --product everythingd` (and `--product ev`) still work. For the app,
  run `scripts/install-app-from-ci.sh`: it installs the ad-hoc signed bundle CI uploads (artifact
  `MacEverything-app`) into ~/Applications and leaves ev and the daemon alone.
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
- FSEvents drops events after big bulk changes (2000 to 5000 files created or deleted at once):
  the log says `re-listing all of /: events were dropped`, and the daemon re-lists the whole
  volume (88 to 118 s at 2.58M entries, 2026-11-02). Since PR #12 that walk runs in 0.25 s
  slices: other changes still show in under a second, folders changed in the last minute are
  listed first, and the saved cursor waits for the walk. `applied queued changes in N s` marks
  its end. Before #12 every change waited for it (parity_check: 44 to 81 s).
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
