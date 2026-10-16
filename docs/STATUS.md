# Status

## Current state
Running daily on Eric's MacBook (macOS 26.6.2) since 2026-10-16: daemon, `ev` CLI and menu-bar
app, signed with the local certificate, Full Disk Access on. CI (macOS 15 runners) is the
compiler and is green on `main`. 4.09M entries indexed (`/` plus the CRASHBOX drive); full scan
228 to 279 s, scan end to saved index 23 s, startup from the saved index in seconds, daemon
memory 16 to 30 MB. Detail of the first real-Mac day: `docs/handoffs/2026-10-16-real-mac-and-ui.md`.

Search window, all confirmed on the Mac: scope menu (All, This Mac, Cloud, each drive), file-type
menu (Everything's filters), "Show temp files" toggle (temp hidden by default), header sorting,
right-click column chooser, drag to reorder, default columns Name | Type | Path.

| Measured on CI, 1.35M entries | Result |
| --- | --- |
| Plain, wildcard, ext, size searches | 2 to 15 ms |
| `path:` / `regex:` searches | 16 to 30 ms / 6 to 46 ms |
| `video:`, `doc: report` | 16 to 22 ms |
| `report !temp:` (first search, builds the mask) | 43 ms; later searches only extend it |

## Next
1. On the Mac: Locations window (menu bar > Locations…), live updates (create, rename, delete a
   file and check `ev`), unplug and replug CRASHBOX. Rest of the #2 checklist.
2. Post the real-Mac numbers on #3 and close it (GitHub MCP was down at the end of 2026-10-16).
3. Delete the `codex-review` and `codex-review-base` branches on GitHub, close #10.
4. Optional: OneDrive folders that each take exactly 6.0 s to list; Type column sorting.

## Open questions
- None. #9 decided 2026-10-16: keep building (see `docs/DECISIONS.md`).

## Gotchas
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
- `ev --rescan` right after an install is not needed; the daemon loads its saved index.
- DexaProject (Google Drive) is indexed by name, per Eric's choice not to exclude anything. Never
  paste search results from it into chat or an external service.
