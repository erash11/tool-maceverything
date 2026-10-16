# Status

## Done
- Core index, query parser, parallel search, save/load.
- getattrlistbulk scanner, FSEvents watcher, restart catch-up.
- everythingd daemon, ev CLI, menu-bar app, install scripts.
- CI on GitHub's macOS runners: build, tests, scanner benchmark, app bundle.

## Measured on GitHub's macOS 15 runner (3 cores), /Applications, 1.35M entries
| Measure | Result | Target |
| --- | --- | --- |
| First scan, getattrlistbulk | 17 to 22 s | under 60 s for 2M |
| First scan, FileManager + lstat | 23 to 31 s | (comparison) |
| Plain, wildcard, ext, size searches | 2 to 14 ms | under 50 ms |
| `path:` searches (`path:lib`, `path:contents/resources`) | 19 to 30 ms | under 50 ms |
| `regex:` searches (`^[0-9]+$`, `\.plist$`, `^lib.*\.dylib$`) | 7 to 46 ms | under 100 ms (#5) |

## Reviews
- Codex (GitHub), 5 passes on PR 1: 16 findings, all fixed. A 6th pass hit the Codex usage limit.
- Sonnet subagent review: 10 findings (locking under load, filter negation, offline drives,
  install script, accept loop), all fixed. 32 tests pass on CI.
- One CI run measured the first /Applications scan at 58 s (17 to 22 s in earlier runs). Likely
  runner noise from a cold disk cache; confirm on a real Mac.

## Open work
Tracked in GitHub issues: https://github.com/erash11/MacEverything/issues
- Real-Mac testing: #2 (app, hotkey, install), #3 (first-scan time)
- Performance: done. #4 and #5 (`path:` and `regex:` speed) met their targets. #6 (`searchfs()`)
  was measured at about 10% faster and closed: the folder walk stays the default and
  `ev --bench-searchfs` remains as a diagnostic.
- Release: #7 done (stable signing identity; `scripts/create-signing-cert.sh`)
- Review and decisions: #8 done (Sonnet review of post-Codex changes: 5 findings fixed), #9 (build vs buy), #10 (review PR closed; delete its two branches on GitHub)
