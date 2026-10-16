# Status

## Current state
v0.1 is complete on `main`: daemon (`everythingd`), CLI (`ev`), menu-bar app, install scripts.
CI on GitHub's macOS 15 runners is green with 42 tests. Two independent reviews were run:
Codex (5 passes, 16 findings) and Sonnet (two passes, 15 findings), all fixed. Nothing has run on
a real Mac yet. Detail: `docs/handoffs/2026-10-16-v0.1-build.md`.

Running on Eric's MacBook since 2026-10-16 (signed with the local certificate, Full Disk Access on).
First real numbers, 4.29M entries (`/` plus the CRASHBOX drive):

| Measured on the Mac | First try | After fixes |
| --- | --- | --- |
| Full scan of `/` | 1,449 s (4.06M entries) | 228 to 279 s (3.87M without browser caches) |
| Unreadable folders | 535 | 320 (root-only system folders) |
| Scan end to index saved | 68 min | 23 s (sort 3.7 s) |
| Startup from the saved index | n/a | a few seconds, no rescan |
| Daemon memory | n/a | 16 to 30 MB |

Fixes that got there: normal scan priority, permission-denied folders not retried (errno),
refresh retries only the failed folders, updates paused during a full scan, startup load
skipped when a rescan already ran, browser caches skipped by folder name.

Search window has a scope menu (All, This Mac, Cloud, each drive) and `drive:NAME`; confirmed on
the Mac 2026-10-16. The window reruns its search on open and retries while the daemon restarts.
Also built 2026-10-16, CI green, not yet confirmed on the Mac: file-type menu and keywords
(`audio:` `zip:` `doc:` `exe:` `pic:` `video:`), Locations window (add folders, drives, network
shares as config.json `extraRoots`; daemon reloads for new drives within 30 s), and temp-file
hiding (`!temp:`, "Show temp files" toggle, mask extended incrementally). Type menu and temp
toggle confirmed on the Mac. Results table: header sorting, right-click column chooser, drag to
reorder, default Name | Type | Path (confirmed on macOS 26.6.2).

| Measured on CI, 1.35M entries | Result | Target |
| --- | --- | --- |
| First scan (getattrlistbulk) | 15 to 22 s (one 58 s outlier) | under 60 s for 2M |
| Plain, wildcard, ext, size searches | 2 to 15 ms | under 50 ms |
| `path:` searches | 16 to 30 ms | under 50 ms |
| `regex:` searches | 6 to 46 ms | under 100 ms |

## Next
1. Work through the rest of the #2 checklist on the Mac (searches, menu-bar app, Option-Space,
   live updates, unplugging CRASHBOX).
2. Record the numbers above on #3 and close it (GitHub MCP was down at the end of the
   2026-10-16 session). Optional: look at OneDrive folders that each take exactly 6.0 s.
3. Delete the `codex-review` and `codex-review-base` branches on GitHub, close #10.

## Open questions
- None. #9 decided 2026-10-16: keep building (see `docs/DECISIONS.md`).

## Gotchas
- No Swift toolchain in Claude cloud sessions: CI (`.github/workflows/ci.yml`) is the compiler
  and test runner. Read job logs with the GitHub MCP `get_job_logs`; `gh run view --log` is blocked.
- Cloud sessions cannot delete GitHub branches (API and `git push --delete` both refused).
- Codex code review is at its account usage limit; for another review use a subagent instead.
- Index writes must stay on `IndexService.work`; `PathTable` relies on parent id < child id.
  Both were checked by review; keep them true when changing `Service.swift` or `FileIndex.swift`.
- External drives with no FSEvents history (CRASHBOX reports event id 0, likely exFAT) are
  rescanned at every daemon start by design (about 15 s for 220K entries).
- CI benchmark times are noisy (FileManager scan varied 22 to 56 s on the same data).
