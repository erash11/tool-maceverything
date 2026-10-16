# Status

## Current state
v0.1 is complete on `main`: daemon (`everythingd`), CLI (`ev`), menu-bar app, install scripts.
CI on GitHub's macOS 15 runners is green with 42 tests. Two independent reviews were run:
Codex (5 passes, 16 findings) and Sonnet (two passes, 15 findings), all fixed. Nothing has run on
a real Mac yet. Detail: `docs/handoffs/2026-10-16-v0.1-build.md`.

| Measured on CI, 1.35M entries | Result | Target |
| --- | --- | --- |
| First scan (getattrlistbulk) | 15 to 22 s (one 58 s outlier) | under 60 s for 2M |
| Plain, wildcard, ext, size searches | 2 to 15 ms | under 50 ms |
| `path:` searches | 16 to 30 ms | under 50 ms |
| `regex:` searches | 6 to 46 ms | under 100 ms |

## Next
1. On the Mac: `git clone https://github.com/erash11/MacEverything.git`, then
   `./scripts/create-signing-cert.sh`, then `./scripts/install.sh`, grant Full Disk Access to
   `~/.local/bin/everythingd`, run `ev --rescan`. Work through the #2 checklist.
2. Record `ev --bench ~` and first-scan time (#3).
3. Delete the `codex-review` and `codex-review-base` branches on GitHub, close #10.
4. After a week of use, decide #9 (keep building vs Find Any File / HoudahSpot).

## Open questions
- #9: is a custom tool worth it over Find Any File or HoudahSpot?

## Gotchas
- No Swift toolchain in Claude cloud sessions: CI (`.github/workflows/ci.yml`) is the compiler
  and test runner. Read job logs with the GitHub MCP `get_job_logs`; `gh run view --log` is blocked.
- Cloud sessions cannot delete GitHub branches (API and `git push --delete` both refused).
- Codex code review is at its account usage limit; for another review use a subagent instead.
- Index writes must stay on `IndexService.work`; `PathTable` relies on parent id < child id.
  Both were checked by review; keep them true when changing `Service.swift` or `FileIndex.swift`.
- CI benchmark times are noisy (FileManager scan varied 22 to 56 s on the same data).
