# Status

## Done
- Core index, query parser, parallel search, save/load.
- getattrlistbulk scanner, FSEvents watcher, restart catch-up.
- everythingd daemon, ev CLI, menu-bar app, install scripts.
- CI on GitHub's macOS runners: build, tests, scanner benchmark, app bundle.

## Next
- Run `./scripts/install.sh` on the Mac; record `ev --bench ~` and `ev --status` numbers
  against the targets in the design doc.

## Open questions
- Is a custom tool worth it over Find Any File or HoudahSpot? Decide after a week of use.
