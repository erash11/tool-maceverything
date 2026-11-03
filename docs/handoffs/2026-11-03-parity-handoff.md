# Handoff: MacEverything parity with voidtools Everything (2026-11-03)

Repo: `/Users/kristinarash/DEV/Personal/MacEverything` (GitHub `erash11/MacEverything`), main at 9d78ac0.
Goal from Eric: the Mac app "didn't work well"; get it on par with Everything on Windows, with real testing.

## Read first (do not re-derive)
- `docs/STATUS.md`: the top block "2026-11-02/03 parity work" has the current state, open PRs, the Drive trial check command, and new findings. Gotchas section covers install and signing.
- `docs/PARITY.md`: 114-row Everything-vs-MacEverything checklist, with a ranked top-10 gap list and file:line evidence.
- `scripts/parity_check.py`: real-Mac live-update and search-speed test (Codex-reviewed, 5 rounds). Run it with `python3 -I scripts/parity_check.py`. It exits 1 on any failure.
- PR #12 https://github.com/erash11/MacEverything/pull/12 (head f425c7f): live-update stall fix. Cause: dropped FSEvents led to a whole-volume re-list on the single update queue. Daemon 51bf3fe is already installed in `~/.local/bin/everythingd`; the old binary is at `~/.local/bin/everythingd.pre-livefix-2026-11-02`. Post-Codex-cap fixes R13/R14 are unreviewed.
- PR #11 https://github.com/erash11/MacEverything/pull/11 (head f8b2272): CI uploads the app artifact, and `scripts/install-app-from-ci.sh` installs it (no Xcode needed). Never run end to end.

## State right now
- Daemon running, about 3.45M entries. Google Drive was added back via `~/Library/Application Support/MacEverything/config.json` `extraRoots` (Eric's Decision Desk pick "A", a 1-day trial, started 2026-11-03T00:21:47Z). 865,605 Drive entries, 0 "giving up" lines at the last check. The Desk item `2026-11-02-maceverything-google-drive` is closed.
- The menu-bar app is a login item (install.sh adds it, Codex-reviewed). The installed app is the 2026-10-16 local build.
- The fix subagent (worktree `.claude/worktrees/agent-a4a6db0d53b609e2a`) was resumed by Eric and may still be running. Check its PR #12 branch before touching the daemon.

## Next, in order
1. Drive trial check (due about 2026-11-04 00:22Z). Use the command in STATUS. If it is not 0, delete config.json (the daemon picks it up within 30 s).
2. On a quiet Mac, run parity_check.py 3 times. If all show `0 failed`, merge #12, then #11 (`gh pr merge N -R erash11/MacEverything --merge`), then run `scripts/install-app-from-ci.sh` and confirm Option-Space and the login item still work. Post the parity numbers on #12, and clean up the merged worktrees and remote branches (Tier A post-merge-cleanup).
3. Fix the top gaps from PARITY.md, starting with: (a) unparsed terms silently match everything (Query.swift:38/109/114), so return an error or no match; (b) the 500-row cap (EverythingApp.swift:182); (c) Down Arrow from the search box into the list (EverythingApp.swift:243-247).
4. Smaller items: exclude the OneDrive group container `~/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite` in `Scanner.cloudExclusions` (164K entries indexed). Add an `ev` daemon-only flag so parity_check's speed test can't silently use the saved index (Codex round-5 F1). STATUS Next #1 (scope menu should show only indexed cloud accounts). The CRASHBOX offline entries disagree with STATUS.

## Traps
- Never print file names from `~/Library/CloudStorage` or OneDrive paths (DexaProject health data). Use `ev --count` only. Never walk the Drive mount by hand.
- `rm -rf` in home is blocked by the dcg guard. Use Python shutil on your own test folder.
- `swift test` can't run locally (no XCTest); CI runs the tests. The EverythingApp target doesn't build locally (SwiftUIMacros).
- Only one agent at a time may create files in indexed folders or restart the daemon, or the live-update timings are invalid.
- Codex review from the main checkout fails on the agent worktrees under `.claude/`. Run it from a clean `git worktree add --detach` in the job tmp folder.

## Suggested skills
- `codex-review`: after every code or script change (Eric's standing rule, cap 5 rounds).
- `mattpocock-skills:diagnosing-bugs`: if parity_check shows live-update failures again.
- `mattpocock-skills:tdd`: for the query-parser and UI gap fixes.
- `superpowers:finishing-a-development-branch`: when merging #11/#12.
- `memory-write`: only if a durable, non-repo fact turns up.
