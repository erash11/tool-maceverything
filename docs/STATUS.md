# Status

## Current state
**2026-11-03 (read first):**
- MERGED #17 (gap 2, part B): `< >` grouping (`<a b> | c`, `!<a b>`, nesting). Groups flatten to
  the AND-of-ORs the matcher runs. Limits (past one, no results, no message): 32 deep, 4,096
  expanded terms, 256 tests per record (an `ext:` counts each extension; measured: a 256-way OR
  takes 2.5 s under load), 16 distinct `regex:`, 16 distinct `path:`; also checked in the scan,
  so scope + filter count. Installed from `main` a5758c1 (backups `*.pre-groups-2026-11-03`).
  Live: `<report 2026>|invoice` 457 = 290 + 167. Codex: 9 rounds (Eric raised the cap); last
  REVISE (R18, wording only). Follow-ups: regex time limit (`^(a+)+$` has none; older than #17);
  a refused query shows 0 results with no message (PARITY "Feedback on bad syntax").
- MERGED #16 (gap 2, part A): `case:`, `ww:`/`wholeword:`, `wfn:`/`wholefilename:`, `startwith:`,
  `endwith:`, `len:`, `image:` (= `pic:`). Also every wildcard `?` is now one character, not one
  byte. `case:` checks the stored name only (Codex found 3 ways a lowercase first test drops real
  matches). Daemon and `ev` installed from `main` 5c0a4bd (backups `*.pre-modifiers-2026-11-03`).
  Codex: 4 rounds, approved. Live: `case:Report` 2,378, `ww:report` 5,615, `image:` = `pic:` 100,623.
- MERGED #15: `dm:` periods (this/last week, month, year), rolling windows (`last7days`,
  `past3weeks`, `last12hours`; open-ended, so future dates count; `>`/`<` compare with the
  cutoff), `2026`, `2026-10`, `a..b` ranges; `size:` names (empty, tiny = 1 B to 10 KB, small,
  medium, large, huge, gigantic) and ranges. `dm:thisweek` is now the calendar week (was the last
  7 days). Daemon and `ev` installed from `main` eb344e6 (backups `*.pre-dates-2026-11-03`).
  Codex: 5 rounds; the last fix (a rolling window can't be a range end) is after the cap, not
  Codex-reviewed. Scrolling past row 500 confirmed by Eric.
- The GitHub repo is now `erash11/tool-maceverything` (planned rename, ~/DEV/REPO_CHANGES.md);
  `scripts/install-app-from-ci.sh` still names the old repo and works through GitHub's redirect.
- MERGED #14: the results list loads more rows as you scroll (first 500, then 2000 per page by
  offset; `ResultPages` in EverythingCore). App installed from CI run 41660743834. Codex: 5
  rounds, approved. Scrolling past row 500 NOT yet seen in the window. Page cost: name sort 39 to
  89 ms; path sort 3.3 to 3.8 s per page (daemon re-sorts all matches; next fix candidate).
- Option-Space confirmed working by Eric (2026-11-03).
- MERGED: #13 (unreadable filter values match nothing), #12 (live-update stall fix + index save
  off the update queue), #11 (CI builds the app). Installed from `main` 31721f0-equivalent code:
  `~/.local/bin/everythingd` and `ev` (backups `*.pre-savefix-2026-11-03`), and the app from CI
  run 41654434583 via `scripts/install-app-from-ci.sh` (old app zipped at
  `~/Library/Application Support/MacEverything/MacEverything-app-2026-10-16.zip`). Login item kept.
  Option-Space not checked (macOS blocks scripted key presses).
- parity_check, 3 runs after the fix: every live-update check passed (incl. 5000 files at once).
  Speed failed under load 30 to 40 on 6 cores (3 to 9 searches over 100 ms per run); idle medians
  27 to 93 ms, same as 11-02. Detail on PR #12's last comment.
- Save probe (`ev --save` while creating a file): file seen in 1.3 s during a save (was 18.1 s).
- Drive trial FAILED: 5,119 "giving up" lines (4,808 in the 12:00 UTC hour, while another job
  trashed Drive files via `gws`). Drive turned off: config.json renamed to
  `~/Library/Application Support/MacEverything/config.json.drive-trial-2026-11-03` (rename back
  to undo). 0 entries under `~/Library/CloudStorage` now.
- Correction: the daemon's 30 s check only ADDS locations from config.json. Removing one needs a
  restart: `launchctl kickstart -k gui/$(id -u)/com.erash11.maceverything.daemon`.
- Open from Codex (rejected for now, reasons on PR #12): shutdown during a slow save waits for two
  writes; a shutdown save can hold a partial walk (cursor stays behind, restart replays). Cheap
  follow-up: `ExitTimeOut` in the launchd plist.
- Seen: a whole-`/` re-list after many dropped events took 389 s in slices (was ~118 s in one go);
  live changes still applied in 1 to 3 s meanwhile.

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
0. Next PARITY gaps: (2C) `parent:`, `depth:`, `empty:`, `childcount:` (notes: `lookup()` is
   case-sensitive, Everything isn't, so `parent:` needs a lowercase walk; `empty:`/`childcount:` want a
   per-query mask built once like `tempMask()`; tell Codex the existing bounds and that only a new
   function bypassing them counts, or the review runs 9 rounds again);
   later `type:` (per-extension type-name cache);
   (b2) cache sorted ids per query in the daemon so
   path/size/date pages are fast; (c) Down Arrow from the search box into the list. Then the smaller items in the
   2026-11-03 handoff (OneDrive group container, `ev --daemon-only`).
1. Scope menu: offer a cloud account (and Cloud) only when it is indexed, that is, added as a
   location; `SearchScope.choices` lists every ~/Library/CloudStorage folder today. Small change
   plus a test tweak.
2. The menu-bar app no longer builds on this Mac (Gotchas): install full Xcode, or wait for
   Command Line Tools that ship SwiftUIMacros. Until then `scripts/install.sh` stops at
   `make-app.sh`; install the app from CI with `scripts/install-app-from-ci.sh` (Gotchas).
3. On the Mac: Locations window (menu bar > Locations…), live updates (create, rename, delete a
   file and check `ev`), unplug and replug CRASHBOX. Rest of the #2 checklist.
4. Post the real-Mac numbers on #3 and close it (GitHub MCP was down at the end of 2026-10-16).
5. Optional: folders that each take exactly 6.0 s to list (once OneDrive; in the 2026-10-24
   scan, sandbox folders under ~/Library/Containers); Type column sorting.

## Open questions
- None. #9 decided 2026-10-16: keep building (see `docs/DECISIONS.md`).

## Gotchas
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
