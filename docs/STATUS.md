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
| `path:` search | 109 ms | under 50 ms (known gap) |
| `regex:` search | about 370 ms | (NSRegularExpression per name; known gap) |

## Next
- Run `./scripts/install.sh` on the Mac; record `ev --bench ~` and `ev --status` numbers
  against the targets in the design doc.

## Open questions
- Is a custom tool worth it over Find Any File or HoudahSpot? Decide after a week of use.
